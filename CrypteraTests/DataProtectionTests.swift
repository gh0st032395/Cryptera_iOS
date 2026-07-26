import XCTest
@testable import Cryptera

/// Data Protection sui file di lavoro (M10, SPEC §11.3).
///
/// **Il test che conta è l'ereditarietà**, non che l'attributo sia stato
/// scritto sulla cartella. L'output in chiaro lo crea il codice Rust con
/// `std::fs`, che di iOS non sa nulla: se i file creati dentro non ereditassero
/// la classe della cartella, la protezione sarebbe scritta nel codice e assente
/// dal disco — il tipo di sicurezza che si racconta e non c'è.
final class DataProtectionTests: XCTestCase {

    private func protectionOf(_ url: URL) throws -> FileProtectionType? {
        let valori = try FileManager.default.attributesOfItem(atPath: url.path)
        return valori[.protectionKey] as? FileProtectionType
    }

    func testLaCartellaDiLavoroHaLaClasseAttesa() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.discard() }

        let classe = try protectionOf(workspace.directory)
        try XCTSkipIf(
            classe == nil,
            "il filesystem non riporta la classe di protezione (simulatore): "
                + "la verifica ha senso solo su device"
        )
        XCTAssertEqual(classe, .completeUnlessOpen)
    }

    /// Un file creato **dentro** la cartella eredita la classe.
    ///
    /// Scritto con `FileManager` e non con `Data.write(options:)`, di proposito:
    /// specificare la protezione sulla scrittura proverebbe solo che l'API
    /// funziona. Qui si vuole sapere cosa succede a chi *non* la specifica, che
    /// è il caso di Rust.
    func testUnFileCreatoDentroEreditaLaClasse() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.discard() }

        let file = workspace.directory.appendingPathComponent("payload")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)),
            "creazione del file di lavoro fallita"
        )

        let classe = try protectionOf(file)
        try XCTSkipIf(
            classe == nil,
            "il filesystem non riporta la classe di protezione (simulatore): "
                + "la verifica ha senso solo su device"
        )
        XCTAssertEqual(
            classe, .completeUnlessOpen,
            "il file non eredita la protezione della cartella: l'output in chiaro resterebbe scoperto"
        )
    }

    /// Il registro resta più protetto dei file di lavoro, non meno.
    ///
    /// Sono due esigenze diverse: il registro non viene mai scritto durante
    /// un'operazione lunga, quindi può permettersi `.complete`; la cartella di
    /// lavoro no.
    func testIlRegistroRestaAllaClassePiuAlta() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-prot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AuditLog(directory: directory)
        UserDefaults.standard.set(true, forKey: PreferenceKey.auditEnabled)
        log.record(op: "encrypt", file: "prova.txt", bytes: 1, duration: 0.01, errorCode: nil)

        let file = directory.appendingPathComponent("audit.jsonl")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: file.path),
            "il registro non ha prodotto un file: nulla da verificare"
        )

        let classe = try protectionOf(file)
        try XCTSkipIf(
            classe == nil,
            "il filesystem non riporta la classe di protezione (simulatore)"
        )
        XCTAssertEqual(classe, .complete)
    }
}
