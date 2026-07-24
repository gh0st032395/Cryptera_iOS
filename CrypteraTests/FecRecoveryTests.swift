import XCTest
@testable import Cryptera

/// SPEC §13.1 punto 4, lato applicazione.
///
/// Il confine esatto del recupero — `r` shard recuperabili, `r + 1` no — è
/// verificato nel crate FFI, dove si può calcolare la posizione degli shard. Qui
/// si copre l'altra metà della frase del piano: *«mai un output silenziosamente
/// sbagliato»*, dal punto di vista di chi usa l'app.
///
/// È la garanzia che conta di più in un'app di cifratura. Un errore si vede e si
/// gestisce; un file corrotto restituito come buono viene creduto, archiviato, e
/// scoperto quando l'originale non c'è più.
@MainActor
final class FecRecoveryTests: XCTestCase {

    private let password = "Abcdefgh1!"

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    /// Cifra un file di contenuto noto e ne restituisce l'URL, insieme ai byte
    /// originali.
    private func fileCifrato() async throws -> (url: URL, plaintext: Data) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let plaintext = Data((0..<200_000).map { UInt8(($0 * 7 + 13) % 251) })
        let source = dir.appendingPathComponent("dati.bin")
        try plaintext.write(to: source)

        let model = EncryptModel()
        await model.select(source)
        model.password = password
        model.passwordConfirmation = password
        // Profilo Bassa: r = 4, il margine di recupero più stretto.
        model.integrityProfile = .low
        model.payloadCompression = .none
        await model.run()

        let output = try XCTUnwrap(model.output, "cifratura fallita: \(model.errorMessage ?? "")")
        // Si sposta fuori dalla cartella di lavoro, che il modello scarterebbe.
        let kept = dir.appendingPathComponent("dati.ecf")
        try FileManager.default.moveItem(at: output.url, to: kept)
        model.discardWork()
        return (kept, plaintext)
    }

    /// Un file danneggiato oltre ogni possibilità di recupero deve produrre un
    /// messaggio, non un file.
    func testUnFileDistruttoNonProduceUnOutputSbagliato() async throws {
        let (url, _) = try await fileCifrato()

        // Si martella una regione ampia e contigua della zona shard: molto oltre
        // i 4 shard che il profilo Bassa sa recuperare. Si parte dopo l'header e
        // si lascia intatto il trailer, altrimenti l'errore sarebbe un altro —
        // header illeggibile invece di dati irrecuperabili, che non è il caso in
        // esame.
        var bytes = try Data(contentsOf: url)
        let inizio = 32 * 1024
        let fine = min(inizio + 300 * 1024, bytes.count - 1024)
        XCTAssertGreaterThan(fine, inizio, "il file cifrato è più piccolo del previsto")
        for i in inizio..<fine {
            bytes[i] ^= 0xFF
        }
        try bytes.write(to: url)

        let model = DecryptModel()
        await model.select(url)
        model.password = password
        await model.run()

        XCTAssertNil(model.output, "nessun file deve essere consegnato")
        XCTAssertEqual(
            model.errorMessage,
            ErrorPresenter.message(for: .CorruptBeyondFec),
            "atteso il messaggio del danneggiamento oltre recupero, ottenuto: \(model.errorMessage ?? "nil")"
        )
    }

    /// Il messaggio deve essere leggibile: né codici del core né percorsi
    /// (SPEC §10.3). È l'errore che un utente incontra nel momento peggiore.
    func testIlMessaggioDiDanneggiamentoEPresentabile() {
        let message = ErrorPresenter.message(for: .CorruptBeyondFec)
        XCTAssertFalse(message.contains("CORRUPT_BEYOND_FEC"), "codice grezzo in UI: \(message)")
        XCTAssertFalse(message.contains("/"), "percorso in UI: \(message)")
        XCTAssertFalse(message.isEmpty)
    }

    /// Un danno **contenuto** invece si recupera, e il contenuto torna identico.
    ///
    /// Senza questo, il test precedente sarebbe soddisfatto anche da un core che
    /// rifiuta qualunque file toccato: dimostrerebbe che l'app non sbaglia, non
    /// che il recupero funziona.
    func testUnDannoContenutoVieneRecuperato() async throws {
        let (url, plaintext) = try await fileCifrato()

        // Un solo shard: 32 byte dentro il ciphertext del primo, ben oltre
        // l'header e i suoi CRC.
        var bytes = try Data(contentsOf: url)
        let hdrLen = Int(bytes[4]) << 8 | Int(bytes[5])
        let primoShard = 4 + 2 + hdrLen + 4 + 16
        for i in (primoShard + 8 + 100)..<(primoShard + 8 + 132) {
            bytes[i] ^= 0xFF
        }
        try bytes.write(to: url)

        let model = DecryptModel()
        await model.select(url)
        model.password = password
        await model.run()

        XCTAssertNil(model.errorMessage)
        let output = try XCTUnwrap(model.output)
        XCTAssertEqual(
            try Data(contentsOf: output.url),
            plaintext,
            "il recupero deve restituire i byte originali, non un'approssimazione"
        )
        model.discardWork()
    }
}
