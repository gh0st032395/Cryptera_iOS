import XCTest
@testable import Cryptera

/// Il registro operazioni (M8), port di `src-tauri/src/audit.rs`.
final class AuditLogTests: XCTestCase {

    private var directory: URL!
    private var log: AuditLog!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = AuditLog(directory: directory)
        UserDefaults.standard.set(true, forKey: PreferenceKey.auditEnabled)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.auditEnabled)
        super.tearDown()
    }

    private func scrivi(_ op: String, file: String = "prova.ecf", errore: String? = nil) {
        log.record(op: op, file: file, bytes: 1_500_000, duration: 0.3, errorCode: errore)
    }

    /// Come nell'upstream: la più recente per prima.
    func testScritturaELetturaInOrdineInverso() {
        scrivi("encrypt")
        scrivi("decrypt", errore: "PASSWORD_INVALID")

        let voci = log.recent()
        XCTAssertEqual(voci.count, 2)
        XCTAssertEqual(voci[0].op, "decrypt")
        XCTAssertEqual(voci[0].status, "ERR")
        XCTAssertEqual(voci[0].error, "PASSWORD_INVALID")
        XCTAssertEqual(voci[1].op, "encrypt")
        XCTAssertTrue(voci[1].succeeded)
    }

    func testIlLimiteVieneRispettato() {
        for _ in 0..<10 { scrivi("verify") }
        XCTAssertEqual(log.recent(limit: 3).count, 3)
    }

    func testRegistroVuoto() {
        XCTAssertTrue(log.recent().isEmpty)
        XCTAssertFalse(log.hasEntries)
    }

    func testSvuotare() {
        scrivi("encrypt")
        XCTAssertEqual(log.recent().count, 1)
        log.clear()
        XCTAssertTrue(log.recent().isEmpty)
    }

    /// **Solo il nome, mai il percorso.**
    ///
    /// Su iOS un percorso contiene identificatori del container e punti di
    /// mount dei file provider: non dice nulla a chi legge il registro e lascia
    /// un'impronta di dove l'utente tiene le sue cose. È la differenza voluta
    /// rispetto all'upstream, che memorizza il percorso completo.
    func testIlPercorsoNonFinisceNelRegistro() throws {
        log.record(
            op: "decrypt",
            file: "/private/var/mobile/Containers/Data/Application/ABC-123/Documents/segreto.ecf",
            bytes: nil,
            duration: 0.1,
            errorCode: nil
        )

        let voce = try XCTUnwrap(log.recent().first)
        XCTAssertEqual(voce.file, "segreto.ecf")

        let grezzo = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        XCTAssertFalse(grezzo.contains("/private/var"), "percorso finito nel registro: \(grezzo)")
        XCTAssertFalse(grezzo.contains("Containers"))
    }

    /// Ogni riga dev'essere JSON valido da sola: è la proprietà per cui si è
    /// scelto JSONL. Un file troncato resta leggibile fino all'ultima riga
    /// intera.
    func testOgniRigaEJsonValidoAncheConCaratteriDifficili() throws {
        log.record(
            op: "decrypt",
            file: "Ünïcodé \"virgolette\" \\barra\\ file.ecf",
            bytes: nil,
            duration: 1.2,
            errorCode: "CORRUPT_BEYOND_FEC"
        )
        scrivi("encrypt")

        let grezzo = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        let righe = grezzo.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(righe.count, 2)
        for riga in righe {
            XCTAssertNoThrow(
                try JSONDecoder().decode(AuditEntry.self, from: Data(riga.utf8)),
                "riga non decodificabile: \(riga)"
            )
        }
    }

    /// Una riga corrotta non deve far perdere tutto il registro.
    func testUnaRigaIlleggibileNonInvalidaLeAltre() throws {
        scrivi("encrypt")
        let file = directory.appendingPathComponent("audit.jsonl")
        try (String(contentsOf: file, encoding: .utf8) + "{non è json\n" + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        log.record(op: "verify", file: "dopo.ecf", bytes: nil, duration: 0.1, errorCode: nil)

        let voci = log.recent()
        XCTAssertEqual(voci.count, 2, "le righe valide devono restare leggibili")
        XCTAssertEqual(voci[0].file, "dopo.ecf")
    }

    /// Con l'interruttore spento non si registra nulla: è il punto
    /// dell'interruttore.
    func testConLaRegistrazioneSpentaNonSiScriveNulla() {
        UserDefaults.standard.set(false, forKey: PreferenceKey.auditEnabled)
        scrivi("encrypt")
        XCTAssertTrue(log.recent().isEmpty)
        XCTAssertFalse(log.hasEntries)
    }

    /// Il file nasce **già** protetto: impostare la protezione dopo la
    /// creazione lascerebbe una finestra in cui esiste senza (SPEC §11.3).
    func testIlFileNasceConDataProtectionCompleta() throws {
        scrivi("encrypt")
        let file = directory.appendingPathComponent("audit.jsonl")
        let protezione = try file.resourceValues(forKeys: [.fileProtectionKey]).fileProtection

        #if targetEnvironment(simulator)
        // Il simulatore non applica la Data Protection: si verifica almeno che
        // il file esista e che la scrittura non sia fallita per via dell'opzione.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        #else
        XCTAssertEqual(protezione, .complete)
        #endif
        _ = protezione
    }

    // MARK: - Codici

    /// I codici del registro sono quelli di SPEC §10.1 e **non vanno
    /// rinominati**: un registro di sei mesi fa deve restare confrontabile con
    /// quello del desktop.
    ///
    /// L'elenco atteso è trascritto dalla specifica, non letto dal codice: due
    /// trascrizioni indipendenti che devono coincidere.
    func testICodiciCoincidonoConLaSpecifica() {
        let attesi: Set<String> = [
            // §10.1 — dal core
            "PASSWORD_INVALID", "HEADER_AUTH_FAILED", "HEADER_INVALID",
            "PARAMS_OUT_OF_LIMITS", "TRUNCATED", "CORRUPT_BEYOND_FEC",
            "IO_ERROR", "CANCELLED", "UNKNOWN_ERROR",
            // §10.2 — livello applicativo
            "PASSWORD_REQUIRED", "INPUT_REQUIRED", "OUTPUT_REQUIRED",
            "OUTPUT_EXISTS", "TAR_ERROR", "EXTRACT_ERROR",
            // §10.2 — specifici iOS
            "ACCESS_DENIED", "INSUFFICIENT_STORAGE", "DEVICE_LOCKED",
            "INSUFFICIENT_MEMORY",
            // panic barrier
            "INTERNAL",
        ]

        let tutti: [CrypteraError] = [
            .PasswordInvalid, .HeaderAuthFailed, .HeaderInvalid, .ParamsOutOfLimits,
            .Truncated, .CorruptBeyondFec, .IoError, .Cancelled, .UnknownError,
            .PasswordRequired, .InputRequired, .OutputRequired, .OutputExists,
            .TarError, .ExtractError, .AccessDenied, .InsufficientStorage,
            .DeviceLocked, .InsufficientMemory, .Internal(message: "x"),
        ]

        let ottenuti = Set(tutti.map(\.auditCode))
        XCTAssertEqual(ottenuti, attesi)
        XCTAssertEqual(ottenuti.count, tutti.count, "due errori non possono avere lo stesso codice")
    }

    /// Il codice grezzo sta nel registro, il messaggio localizzato nella UI:
    /// sono due pubblici diversi (SPEC §10.3).
    func testIlCodiceNonEIlMessaggioMostrato() {
        useEnglish()
        XCTAssertNotEqual(
            CrypteraError.CorruptBeyondFec.auditCode,
            ErrorPresenter.message(for: .CorruptBeyondFec)
        )
    }
}
