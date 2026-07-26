import XCTest
@testable import Cryptera

/// Copre il punto di SPEC §6.1 che è facile sbagliare senza accorgersene.
///
/// `startAccessingSecurityScopedResource()` torna `false` in due casi opposti:
/// permesso negato, e URL che non ha bisogno di alcun permesso. Lo snippet
/// della spec li tratta allo stesso modo — e così com'è scritto farebbe fallire
/// ogni operazione sui percorsi interni all'app, cioè proprio la cartella di
/// lavoro dove M4 scrive l'output.
final class FileAccessTests: XCTestCase {

    func testPercorsoNelContainerNonRichiedeAlcunoScope() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prova-\(UUID().uuidString).txt")
        try Data("contenuto".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let path = try await FileAccess.withSecurityScope(url) { $0 }
        XCTAssertEqual(path, url.path)
    }

    /// Il bundle sta fuori dalla home del container: è l'altro albero che
    /// l'helper deve riconoscere come accessibile senza scope.
    func testFileNelBundleRaggiungibileSenzaScope() async throws {
        let url = try fixtureURL("v4-basic")
        let meta = try await FileAccess.withSecurityScope(url) { try readMetadata(path: $0) }
        XCTAssertEqual(meta.version, 4)
    }

    /// Il discriminante fra i due `false` di
    /// `startAccessingSecurityScopedResource()`, verificato direttamente.
    ///
    /// Non lo si esercita attraverso `withSecurityScope`: sul simulatore quella
    /// chiamata **riesce** anche su un percorso arbitrario fuori dal container,
    /// quindi il ramo di rifiuto non verrebbe mai raggiunto e il test darebbe
    /// verde senza aver provato nulla.
    func testPercorsoFuoriPortataNonPassaPerAccessibileSenzaScope() {
        XCTAssertFalse(
            FileAccess.isAccessibleWithoutScope(
                URL(fileURLWithPath: "/percorso-inesistente-cryptera/file.ecf")
            ),
            "senza scope un percorso fuori dal container non è raggiungibile: va rifiutato"
        )
    }

    func testPercorsiInterniSonoAccessibiliSenzaScope() throws {
        let temporaneo = FileManager.default.temporaryDirectory
            .appendingPathComponent("interno-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: temporaneo)
        defer { try? FileManager.default.removeItem(at: temporaneo) }

        XCTAssertTrue(FileAccess.isAccessibleWithoutScope(temporaneo))
        XCTAssertTrue(FileAccess.isAccessibleWithoutScope(try fixtureURL("v4-basic")))
        // Anche un percorso non ancora esistente dentro il container: è il caso
        // dell'output, che viene creato dall'operazione.
        XCTAssertTrue(
            FileAccess.isAccessibleWithoutScope(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("non-ancora-\(UUID().uuidString).bin")
            ),
            "l'output non esiste ancora quando lo si apre: la posizione basta a autorizzarlo"
        )
    }

    func testScopeAnnidatoSuInputEKeyfile() async throws {
        let input = try fixtureURL("v4-basic")
        let keyfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyfile-\(UUID().uuidString).bin")
        try Data("chiave".utf8).write(to: keyfile)
        defer { try? FileManager.default.removeItem(at: keyfile) }

        let paths = try await FileAccess.withSecurityScope(input: input, keyfile: keyfile) {
            inputPath, keyfilePath in
            [inputPath, keyfilePath ?? ""]
        }
        XCTAssertEqual(paths[0], input.path)
        XCTAssertEqual(paths[1], keyfile.path)

        let senzaKeyfile = try await FileAccess.withSecurityScope(input: input, keyfile: nil) {
            _, keyfilePath in keyfilePath
        }
        XCTAssertNil(senzaKeyfile, "senza keyfile non si deve inventare un percorso")
    }

    // MARK: - Inbox

    func testCopiaNellInboxVieneRimossa() throws {
        let inbox = try inboxDirectory()
        let file = inbox.appendingPathComponent("arrivato-\(UUID().uuidString).ecf")
        try Data("x".utf8).write(to: file)

        FileAccess.discardIfInbox(file)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "la copia lasciata dal sistema resta a carico dell'app: va rimossa"
        )
    }

    /// Il controllo che conta davvero: nessuna cancellazione a sorpresa fuori
    /// dall'Inbox, dove i file sono dell'utente e non nostri.
    func testFileFuoriDallInboxNonVieneToccato() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("utente-\(UUID().uuidString).ecf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        FileAccess.discardIfInbox(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Un nome che *inizia* come l'Inbox ma sta altrove non deve bastare.
    func testCartellaConPrefissoSimileAllInboxNonVieneToccata() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let esca = documents.appendingPathComponent("InboxAltro", isDirectory: true)
        try FileManager.default.createDirectory(at: esca, withIntermediateDirectories: true)
        let file = esca.appendingPathComponent("f.ecf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: esca) }

        FileAccess.discardIfInbox(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Helper

    /// `Documents/Inbox` su un device è **del sistema**: l'app ci legge e ci
    /// cancella — che è tutto ciò che fa il codice di produzione — ma non può
    /// crearla, e `createDirectory` fallisce con `NSFileWriteNoPermissionError`.
    ///
    /// Il test la crea solo per allestire lo scenario, quindi dove non si può
    /// si salta con una ragione esplicita invece di fallire: la logica resta
    /// coperta in simulatore, dove la cartella è creabile.
    private func inboxDirectory() throws -> URL {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            throw XCTSkip(
                "Documents/Inbox non è creabile qui (\(error.localizedDescription)): "
                    + "su device la gestisce il sistema. Lo scenario è coperto in simulatore."
            )
        }
        return inbox
    }
}
