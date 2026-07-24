import XCTest
@testable import Cryptera

/// Decifratura in blocco (M8).
@MainActor
final class BatchFlowTests: XCTestCase {

    private let password = "Abcdefgh1!"

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    private func cartellaDiLavoro() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Cifra un file di contenuto noto e restituisce il `.ecf`.
    private func ecf(in dir: URL, nome: String, contenuto: String) async throws -> URL {
        let source = dir.appendingPathComponent(nome)
        try Data(contenuto.utf8).write(to: source)

        let model = EncryptModel()
        await model.select(source)
        model.password = password
        model.passwordConfirmation = password
        await model.run()

        let output = try XCTUnwrap(model.output, "cifratura fallita: \(model.errorMessage ?? "")")
        let kept = dir.appendingPathComponent("\(nome).ecf")
        try FileManager.default.moveItem(at: output.url, to: kept)
        model.discardWork()
        return kept
    }

    /// Il caso normale: tre file, una password, tutti decifrati con il contenuto
    /// originale.
    func testTreFileVengonoDecifratiInSequenza() async throws {
        let dir = try cartellaDiLavoro()
        let contenuti = ["uno": "primo", "due": "secondo", "tre": "terzo"]
        var ecfs: [URL] = []
        for (nome, contenuto) in contenuti.sorted(by: { $0.key < $1.key }) {
            ecfs.append(try await ecf(in: dir, nome: "\(nome).txt", contenuto: contenuto))
        }

        let batch = BatchModel()
        batch.add(ecfs)
        batch.password = password
        XCTAssertTrue(batch.canRun)

        await batch.run()

        let summary = try XCTUnwrap(batch.summary)
        XCTAssertEqual(summary.succeeded, 3)
        XCTAssertEqual(summary.failed, 0)

        for item in batch.items {
            XCTAssertEqual(item.state, .done, "\(item.name) non è riuscito")
            let output = try XCTUnwrap(item.output)
            // Il nome originale viene dall'header, non dal `.ecf`.
            let atteso = contenuti[output.deletingPathExtension().lastPathComponent]
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), atteso)
        }

        XCTAssertNotNil(batch.outputFolder, "i risultati devono stare in una cartella esportabile")
        batch.discardWork()
    }

    /// Un file che fallisce non deve fermare la coda: gli altri vanno avanti.
    ///
    /// È il motivo per cui il batch esiste — se bastasse un file rotto a
    /// interrompere tutto, tanto varrebbe farli uno per uno.
    func testUnFileRottoNonFermaGliAltri() async throws {
        let dir = try cartellaDiLavoro()
        let buono1 = try await ecf(in: dir, nome: "buono1.txt", contenuto: "primo")
        let buono2 = try await ecf(in: dir, nome: "buono2.txt", contenuto: "secondo")

        // Un file che non è un `.ecf` valido.
        let rotto = dir.appendingPathComponent("rotto.ecf")
        try Data("non sono un archivio".utf8).write(to: rotto)

        let batch = BatchModel()
        batch.add([buono1, rotto, buono2])
        batch.password = password
        await batch.run()

        let summary = try XCTUnwrap(batch.summary)
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failed, 1)

        guard case .failed(let messaggio) = batch.items[1].state else {
            return XCTFail("il file rotto doveva fallire")
        }
        // SPEC §10.3: il messaggio per riga è quello localizzato, non il codice.
        XCTAssertFalse(messaggio.contains("HEADER_INVALID"), "codice grezzo in UI: \(messaggio)")
        XCTAssertEqual(batch.items[0].state, .done)
        XCTAssertEqual(batch.items[2].state, .done, "la coda deve proseguire dopo un errore")
        batch.discardWork()
    }

    /// Una password sbagliata fa fallire tutti i file, ma con un messaggio
    /// leggibile per ciascuno.
    func testPasswordSbagliataFaFallireTuttoSenzaProdurreFile() async throws {
        let dir = try cartellaDiLavoro()
        let file = try await ecf(in: dir, nome: "a.txt", contenuto: "x")

        let batch = BatchModel()
        batch.add([file])
        batch.password = "PasswordSbagliata9!"
        await batch.run()

        XCTAssertEqual(batch.summary?.failed, 1)
        XCTAssertNil(batch.outputFolder, "senza successi non c'è nulla da esportare")
        XCTAssertNil(batch.items[0].output)
    }

    /// Due `.ecf` diversi che contengono file con lo stesso nome non devono
    /// sovrascriversi a vicenda (SPEC §6.3).
    func testNomiUgualiNonSiSovrascrivono() async throws {
        let dirA = try cartellaDiLavoro()
        let dirB = try cartellaDiLavoro()
        let primo = try await ecf(in: dirA, nome: "nota.txt", contenuto: "contenuto A")
        let secondo = try await ecf(in: dirB, nome: "nota.txt", contenuto: "contenuto B")

        let batch = BatchModel()
        batch.add([primo, secondo])
        batch.password = password
        await batch.run()

        XCTAssertEqual(batch.summary?.succeeded, 2)
        let usciti = batch.items.compactMap(\.output)
        XCTAssertEqual(usciti.count, 2)
        XCTAssertNotEqual(usciti[0], usciti[1], "il secondo file non deve sovrascrivere il primo")

        let contenuti = Set(try usciti.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contenuti, ["contenuto A", "contenuto B"])
        batch.discardWork()
    }

    func testIDoppioniNonEntranoInCodaDueVolte() async throws {
        let dir = try cartellaDiLavoro()
        let file = try await ecf(in: dir, nome: "a.txt", contenuto: "x")

        let batch = BatchModel()
        batch.add([file])
        batch.add([file])
        XCTAssertEqual(batch.items.count, 1)
    }

    /// La password si azzera a fine corsa (SPEC §12.1).
    func testLaPasswordVieneAzzerataAFineCorsa() async throws {
        let dir = try cartellaDiLavoro()
        let file = try await ecf(in: dir, nome: "a.txt", contenuto: "x")

        let batch = BatchModel()
        batch.add([file])
        batch.password = password
        await batch.run()

        XCTAssertTrue(batch.password.isEmpty)
        batch.discardWork()
    }

    /// Il ripristino svuota la coda e scarta le copie in chiaro.
    func testIlRipristinoScartaLeCopieInChiaro() async throws {
        let dir = try cartellaDiLavoro()
        let file = try await ecf(in: dir, nome: "a.txt", contenuto: "x")

        let batch = BatchModel()
        batch.add([file])
        batch.password = password
        await batch.run()

        let uscita = try XCTUnwrap(batch.items[0].output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uscita.path))

        batch.reset()

        XCTAssertTrue(batch.items.isEmpty)
        XCTAssertTrue(batch.password.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: uscita.path),
            "le copie in chiaro non devono sopravvivere al ripristino"
        )
    }
}
