import XCTest
@testable import Cryptera

/// M6: cifratura di cartelle, dalla selezione al round-trip con Decrypt.
@MainActor
final class FolderEncryptionTests: XCTestCase {

    private let strongPassword = "Abcdefgh1!"

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    /// Cartella con sottocartella, due file di contenuto noto.
    private func cartellaDiProva() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("origine-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("documenti", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sotto", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("primo".utf8).write(to: folder.appendingPathComponent("uno.txt"))
        try Data("secondo".utf8).write(to: folder.appendingPathComponent("sotto/due.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return folder
    }

    /// Il giro completo: cartella cifrata da Cifra, riestratta da Decifra, con
    /// la struttura e i contenuti intatti.
    func testRoundTripDiUnaCartella() async throws {
        let folder = try cartellaDiProva()

        let encrypt = EncryptModel()
        await encrypt.select(folder)

        let input = try XCTUnwrap(encrypt.input)
        XCTAssertTrue(input.isFolder)
        XCTAssertEqual(input.fileCount, 2, "due file, la sottocartella non è un file")
        XCTAssertEqual(input.size, 12, "«primo» + «secondo»")
        XCTAssertTrue(encrypt.isFolderInput)

        encrypt.password = strongPassword
        encrypt.passwordConfirmation = strongPassword
        encrypt.archiveCompression = .gzip
        XCTAssertNil(encrypt.blockingReason)

        await encrypt.run()
        XCTAssertNil(encrypt.errorMessage)
        let cifrato = try XCTUnwrap(encrypt.output)
        XCTAssertEqual(cifrato.name, "documenti.ecf")

        let decrypt = DecryptModel()
        await decrypt.select(cifrato.url)
        let header = try XCTUnwrap(decrypt.header)
        XCTAssertTrue(header.summary.isTarContainer, "una cartella produce un container TAR")
        XCTAssertTrue(decrypt.offersExtraction)
        XCTAssertTrue(decrypt.extractArchive, "per un archivio l'estrazione è il default")

        decrypt.password = strongPassword
        await decrypt.run()
        XCTAssertNil(decrypt.errorMessage)

        let uscita = try XCTUnwrap(decrypt.output)
        XCTAssertTrue(uscita.isDirectory)
        XCTAssertEqual(uscita.name, "documenti", "si consegna la cartella originale, non un livello in più")
        XCTAssertEqual(
            try String(contentsOf: uscita.url.appendingPathComponent("uno.txt"), encoding: .utf8),
            "primo"
        )
        XCTAssertEqual(
            try String(
                contentsOf: uscita.url.appendingPathComponent("sotto/due.txt"),
                encoding: .utf8
            ),
            "secondo"
        )

        decrypt.discardWork()
        encrypt.discardWork()
    }

    /// Per una cartella il payload **non** va compresso: il TAR lo è già
    /// secondo `archiveCompression`, e comprimerlo due volte lo farebbe solo
    /// crescere. Il flag di compressione del payload deve quindi restare spento
    /// nell'header anche se l'impostazione dice altro.
    func testLaCompressionePayloadNonSiApplicaAlleCartelle() async throws {
        let folder = try cartellaDiProva()

        let model = EncryptModel()
        await model.select(folder)
        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        model.payloadCompression = .lzma   // scelta per i file, non per le cartelle
        model.archiveCompression = .xz

        await model.run()

        let output = try XCTUnwrap(model.output)
        let summary = describeHeader(meta: output.meta)
        XCTAssertEqual(
            summary.payloadCompression, .none,
            "il TAR è già compresso: il payload non va compresso una seconda volta"
        )
        XCTAssertTrue(summary.isTarContainer)
        model.discardWork()
    }

    func testUnaCartellaVuotaSiCifraComunque() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vuota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let model = EncryptModel()
        await model.select(root)
        XCTAssertEqual(model.input?.fileCount, 0)
        XCTAssertEqual(model.input?.size, 0)

        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        await model.run()

        XCTAssertNil(model.errorMessage, "una cartella vuota è legittima, non un errore")
        XCTAssertNotNil(model.output)
        model.discardWork()
    }

    /// Una cartella scomparsa fra la selezione e l'avvio non deve produrre un
    /// archivio **vuoto** cifrato con successo — è la perdita di dati
    /// silenziosa già corretta nel crate FFI, verificata qui dal lato Swift.
    func testUnaCartellaSparitaFallisceInveceDiProdurreUnArchivioVuoto() async throws {
        let folder = try cartellaDiProva()

        let model = EncryptModel()
        await model.select(folder)
        model.password = strongPassword
        model.passwordConfirmation = strongPassword

        try FileManager.default.removeItem(at: folder)
        await model.run()

        XCTAssertNil(model.output, "nessun archivio deve essere prodotto")
        XCTAssertNotNil(model.errorMessage)
    }
}

/// Il preflight sullo spazio (SPEC §11.4).
final class StorageCheckTests: XCTestCase {

    /// Una cartella passa da un TAR intermedio: serve circa il doppio della
    /// sorgente, più la parità. È la differenza che rende M6 diversa da M5.
    func testUnaCartellaRichiedeIlDoppioDiUnFile() {
        let source: UInt64 = 100_000_000

        let file = StorageCheck.requiredBytes(
            source: source, parityOverheadPercent: 0, needsArchive: false
        )
        let folder = StorageCheck.requiredBytes(
            source: source, parityOverheadPercent: 0, needsArchive: true
        )

        XCTAssertGreaterThan(folder, file)
        XCTAssertEqual(folder - file, source, "l'archivio intermedio pesa quanto la sorgente")
    }

    /// Con il profilo massimo la parità aggiunge il 300%: una cartella arriva a
    /// oltre quattro volte la sorgente, ed è il caso che rende il controllo
    /// necessario invece che prudenziale.
    func testIlProfiloMassimoQuadruplicaIlFabbisogno() {
        let source: UInt64 = 100_000_000
        let required = StorageCheck.requiredBytes(
            source: source, parityOverheadPercent: 300, needsArchive: true
        )
        // output (4×) + archivio (1×) = 5×, più il margine fisso.
        XCTAssertGreaterThan(required, 5 * source)
        XCTAssertLessThan(required, 5 * source + 8 * 1024 * 1024)
    }

    /// La stima è per eccesso: un preflight che sbaglia per difetto lascia
    /// l'utente a metà strada con il disco pieno.
    func testLaStimaIncludeUnMargine() {
        XCTAssertGreaterThan(
            StorageCheck.requiredBytes(source: 0, parityOverheadPercent: 0, needsArchive: false),
            0,
            "anche un file vuoto produce header e trailer"
        )
    }

    func testLoSpazioDisponibileSiLegge() throws {
        let available = StorageCheck.availableBytes(for: FileManager.default.temporaryDirectory)
        let bytes = try XCTUnwrap(available, "il volume del container deve esporre la capacità")
        XCTAssertGreaterThan(bytes, 0)
    }

    /// Un fabbisogno assurdo deve essere rifiutato, uno normale accettato.
    func testIlControlloDistingueIDueCasi() {
        let volume = FileManager.default.temporaryDirectory
        XCTAssertTrue(
            StorageCheck.hasRoom(
                forSource: 1024, parityOverheadPercent: 8, needsArchive: true, on: volume
            )
        )
        XCTAssertFalse(
            StorageCheck.hasRoom(
                forSource: .max / 4, parityOverheadPercent: 300, needsArchive: true, on: volume
            ),
            "un fabbisogno oltre la capacità del disco deve essere rifiutato"
        )
    }

    func testLaMisuraDiUnaCartellaContaSoloIFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misura-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a/b", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 1000).write(to: root.appendingPathComponent("uno.bin"))
        try Data(repeating: 7, count: 500).write(to: root.appendingPathComponent("a/b/due.bin"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let measurement = StorageCheck.measureFolder(at: root)
        XCTAssertEqual(measurement.files, 2, "le cartelle non contano come file")
        XCTAssertEqual(measurement.bytes, 1500)
    }
}
