import XCTest
@testable import Cryptera

/// Percorso completo di M4 al livello del modello: selezione → header senza
/// password → decifratura → output pronto per l'export.
///
/// Attraversa davvero `FileAccess`, `CrypteraEngine`, UniFFI, Rust e il core: è
/// il tratto che i UI test non possono esercitare, perché il picker di sistema
/// non è pilotabile.
@MainActor
final class DecryptFlowTests: XCTestCase {

    /// Password con cui l'upstream ha generato le fixture.
    private let fixturePassword = "FixtureP@ssw0rd42"

    func testDecifraLaFixtureUpstreamERestituisceIlNomeOriginale() async throws {
        let model = DecryptModel()
        await model.select(try fixtureURL("v4-basic"))

        XCTAssertNil(model.headerProblem)
        let header = try XCTUnwrap(model.header)
        XCTAssertEqual(header.meta.version, 4)
        XCTAssertEqual(header.originalName, "secret-note.txt")
        XCTAssertFalse(header.summary.isTarContainer)
        XCTAssertFalse(model.offersExtraction, "un file singolo non offre l'estrazione")
        XCTAssertEqual(header.summary.payloadCompression, .none)

        model.password = fixturePassword
        XCTAssertTrue(model.canRun)
        await model.run()

        XCTAssertNil(model.errorMessage)
        let output = try XCTUnwrap(model.output)
        XCTAssertEqual(
            output.name,
            "secret-note.txt",
            "il nome dell'output viene dall'header, non dal .ecf scelto"
        )
        XCTAssertFalse(output.isDirectory)

        let data = try Data(contentsOf: output.url)
        XCTAssertEqual(
            UInt64(data.count),
            header.meta.plainSize,
            "il file decifrato deve avere la dimensione dichiarata nell'header"
        )

        model.discardWork()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.url.path),
            "l'output in chiaro non deve sopravvivere alla schermata"
        )
    }

    func testPasswordSbagliataNonLasciaOutput() async throws {
        let model = DecryptModel()
        await model.select(try fixtureURL("v4-basic"))
        model.password = "password-sbagliata"
        await model.run()

        XCTAssertNil(model.output, "un fallimento non deve lasciare un file utilizzabile")
        let message = try XCTUnwrap(model.errorMessage)
        // SPEC §10.3: né codici grezzi né percorsi raggiungono l'utente.
        XCTAssertFalse(message.contains("PASSWORD_INVALID"), "codice grezzo in UI: \(message)")
        XCTAssertFalse(message.contains("/"), "percorso in UI: \(message)")
    }

    func testFileNonEcfSegnalatoSenzaBloccareLaSchermata() async throws {
        let intruso = FileManager.default.temporaryDirectory
            .appendingPathComponent("non-cifrato-\(UUID().uuidString).ecf")
        try Data("questo non è un archivio Cryptera".utf8).write(to: intruso)
        defer { try? FileManager.default.removeItem(at: intruso) }

        let model = DecryptModel()
        await model.select(intruso)

        XCTAssertNil(model.header)
        let problem = try XCTUnwrap(model.headerProblem)
        XCTAssertFalse(problem.contains("HEADER_INVALID"), "codice grezzo in UI: \(problem)")
        XCTAssertFalse(model.canRun, "senza header valido non si deve poter avviare nulla")
    }

    /// Cambiare file non deve lasciare pronta la password scritta per il
    /// precedente: sarebbe inviabile a un file diverso da quello per cui è stata
    /// digitata, con un semplice tocco.
    func testCambiareFileAzzeraLaPassword() async throws {
        let model = DecryptModel()
        await model.select(try fixtureURL("v4-basic"))
        model.password = fixturePassword

        await model.select(try fixtureURL("v4-zlib-hidden"))

        XCTAssertTrue(model.password.isEmpty)
        XCTAssertFalse(model.canRun)
    }

    /// Il ramo di estrazione, che nessuna fixture dell'upstream esercita:
    /// vanno cifrate prima una cartella.
    ///
    /// Verifica anche la scelta di consegnare direttamente la cartella
    /// originale: l'archivio contiene già un livello col suo nome, e senza
    /// questo l'utente si troverebbe una cartella dentro una cartella.
    func testArchivioEstrattoConsegnaLaCartellaOriginale() async throws {
        let radice = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorgente-\(UUID().uuidString)", isDirectory: true)
        let cartella = radice.appendingPathComponent("documenti", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cartella.appendingPathComponent("sotto", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("primo".utf8).write(to: cartella.appendingPathComponent("uno.txt"))
        try Data("secondo".utf8).write(to: cartella.appendingPathComponent("sotto/due.txt"))
        let cifrato = radice.appendingPathComponent("documenti.ecf")
        defer { try? FileManager.default.removeItem(at: radice) }

        _ = try await CrypteraEngine.shared.encrypt(
            EncryptRequest(
                source: .folder(path: cartella.path),
                outputPath: cifrato.path,
                password: "prova",
                keyfilePath: nil,
                payloadCompression: .none,
                archiveCompression: .gzip,
                skipSpecialFiles: true,
                enablePasswordCheck: true,
                hideFilename: false,
                securityProfile: .standard,
                integrityProfile: .low
            )
        )

        let model = DecryptModel()
        await model.select(cifrato)

        let header = try XCTUnwrap(model.header)
        XCTAssertTrue(header.summary.isTarContainer)
        XCTAssertTrue(model.offersExtraction)
        XCTAssertTrue(model.extractArchive, "per un archivio l'estrazione è il default sensato")

        model.password = "prova"
        await model.run()

        XCTAssertNil(model.errorMessage)
        let output = try XCTUnwrap(model.output)
        XCTAssertTrue(output.isDirectory)
        XCTAssertEqual(output.name, "documenti", "atteso il nome della cartella originale")
        XCTAssertEqual(
            try String(contentsOf: output.url.appendingPathComponent("uno.txt"), encoding: .utf8),
            "primo"
        )
        XCTAssertEqual(
            try String(
                contentsOf: output.url.appendingPathComponent("sotto/due.txt"),
                encoding: .utf8
            ),
            "secondo"
        )
        model.discardWork()
    }

    /// Un output non salvato non deve restare su disco quando ne arriva un altro.
    func testUnaSecondaEsecuzioneNonLasciaOrfanaLaPrecedente() async throws {
        let model = DecryptModel()
        await model.select(try fixtureURL("v4-basic"))
        model.password = fixturePassword
        await model.run()
        let primo = try XCTUnwrap(model.output).url

        await model.run()
        let secondo = try XCTUnwrap(model.output).url

        XCTAssertNotEqual(primo, secondo)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: primo.path),
            "il file in chiaro della prima esecuzione è rimasto su disco"
        )
        model.discardWork()
    }

    /// La fixture con nome nascosto è il caso in cui il nome originale non
    /// esiste: l'output prende il nome del `.ecf` di partenza.
    func testFixtureSenzaNomeUsaIlNomeDelFileCifrato() async throws {
        let model = DecryptModel()
        await model.select(try fixtureURL("v4-zlib-hidden"))

        let header = try XCTUnwrap(model.header)
        XCTAssertNil(header.originalName)
        XCTAssertEqual(header.summary.payloadCompression, .zlib)

        model.password = fixturePassword
        await model.run()

        XCTAssertNil(model.errorMessage)
        let output = try XCTUnwrap(model.output)
        XCTAssertEqual(output.name, "v4-zlib-hidden")
        model.discardWork()
    }
}

/// La cartella di lavoro è l'unico punto in cui un nome scelto da chi ha creato
/// il file diventa un percorso su iOS.
final class TemporaryWorkspaceTests: XCTestCase {

    func testNomeOstileNellHeaderNonEsceDallaCartellaDiLavoro() throws {
        // `URL.appendingPathComponent` non neutralizza le risalite: senza
        // sanificazione questi nomi scriverebbero fuori dalla cartella.
        for ostile in ["../../../evaso.txt", "/tmp/evaso.txt", "a/b/evaso.txt"] {
            let workspace = try TemporaryWorkspace()
            defer { workspace.discard() }

            try Data("x".utf8).write(to: workspace.payload)
            let renamed = workspace.rename(workspace.payload, to: ostile, fallback: "decifrato")

            XCTAssertEqual(renamed.lastPathComponent, "evaso.txt", "nome ostile: \(ostile)")
            XCTAssertEqual(
                renamed.deletingLastPathComponent().standardizedFileURL.path,
                workspace.directory.standardizedFileURL.path,
                "l'output è finito fuori dalla cartella di lavoro: \(renamed.path)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        }
    }

    func testNomeAssenteRicadeSulFallback() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.discard() }
        try Data("x".utf8).write(to: workspace.payload)

        let renamed = workspace.rename(workspace.payload, to: "", fallback: "decifrato")
        XCTAssertEqual(renamed.lastPathComponent, "decifrato")
    }

    /// Se l'app viene terminata durante un'operazione, il file decifrato
    /// resterebbe su disco fino alla prossima pulizia del sistema.
    func testPurgeStaleRimuoveIResiduiDiSessioniPrecedenti() throws {
        let workspace = try TemporaryWorkspace()
        try Data("in chiaro".utf8).write(to: workspace.payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.payload.path))

        TemporaryWorkspace.purgeStale()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
    }
}
