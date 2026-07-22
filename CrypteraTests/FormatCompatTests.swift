import XCTest
@testable import Cryptera

/// Compatibilità di formato contro le fixture dell'upstream — SPEC §13.1.
///
/// È il test che conta: tutti gli altri possono passare con un formato
/// divergente. Le fixture sono copiate da `tests/fixtures/` del repo Cryptera e
/// le aspettative sono trascritte da `tests/format_compat.rs`, così che una
/// divergenza fra desktop e iOS emerga qui e non su un file reale di qualcuno.
///
/// Coperto finora: **punto 1 (lettura)** e **punto 2 (round-trip locale)**.
/// I punti 3-5 (round-trip incrociato in CI, recupero FEC, manomissione) sono
/// M7; la manomissione è già coperta dai test Rust del crate FFI.
final class FormatCompatTests: XCTestCase {

    /// Password con cui sono state generate le fixture dell'upstream.
    /// Non è un segreto: è dato di test, committato anche a monte.
    private static let fixturePassword = "FixtureP@ssw0rd42"

    /// Plaintext atteso, identico a `expected_plaintext()` dell'upstream.
    private static func expectedPlaintext() -> Data {
        Data((0..<3000).map { UInt8(($0 * 7 + 13) % 251) })
    }

    // MARK: - Lettura (SPEC §13.1 punto 1)

    func testFixtureV4BasicSiVerificaESiDecifra() async throws {
        let path = try fixturePath("v4-basic")

        let meta = try readMetadata(path: path)
        XCTAssertEqual(meta.version, 4)
        XCTAssertEqual(meta.filename, "secret-note.txt", "v4 conserva il nome in chiaro")
        XCTAssertEqual(meta.k, 4)
        XCTAssertEqual(meta.r, 2)

        // Verifica: non scrive nulla.
        _ = try await CrypteraEngine.shared.verify(
            VerifyRequest(inputPath: path, password: Self.fixturePassword, keyfilePath: nil)
        )

        // Decifratura: il contenuto deve corrispondere byte per byte.
        let out = try temporaryPath("restored.bin")
        let decMeta = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: path,
                outputPath: out,
                password: Self.fixturePassword,
                keyfilePath: nil,
                extractArchive: false,
                keepArchive: false
            )
        )
        XCTAssertEqual(decMeta.filename, "secret-note.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), Self.expectedPlaintext())
    }

    func testFixtureV4ZlibNomeNascostoSiDecifra() async throws {
        let path = try fixturePath("v4-zlib-hidden")

        let meta = try readMetadata(path: path)
        XCTAssertEqual(meta.version, 4)
        XCTAssertEqual(meta.filename, "", "il nome nascosto resta vuoto")
        XCTAssertEqual(meta.flags & 0x02, 0x02, "atteso FLAG_COMPRESS_ZLIB")

        let out = try temporaryPath("restored-zlib.bin")
        _ = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: path,
                outputPath: out,
                password: Self.fixturePassword,
                keyfilePath: nil,
                extractArchive: false,
                keepArchive: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), Self.expectedPlaintext())
    }

    func testPasswordSbagliataSuFixtureV4DaPasswordInvalid() async throws {
        // Su v4 il record PWCHK risponde prima dell'autenticazione header, quindi
        // qui si ottiene PASSWORD_INVALID. Su v5 lo stesso errore si presenta
        // invece come HEADER_AUTH_FAILED — vedi il commento in
        // `password_sbagliata_su_v5_da_header_auth_failed` nel crate FFI.
        let path = try fixturePath("v4-basic")
        do {
            _ = try await CrypteraEngine.shared.verify(
                VerifyRequest(inputPath: path, password: "sbagliata", keyfilePath: nil)
            )
            XCTFail("una password errata non deve verificare")
        } catch let error as CrypteraError {
            switch error {
            case .PasswordInvalid, .HeaderAuthFailed:
                break
            default:
                XCTFail("errore inatteso: \(error)")
            }
        }
    }

    // MARK: - Round-trip locale (SPEC §13.1 punto 2)

    func testRoundTripLocaleConservaIlContenuto() async throws {
        let plaintext = Self.expectedPlaintext()
        let source = try temporaryPath("origine.bin")
        try plaintext.write(to: URL(fileURLWithPath: source))

        let encrypted = try temporaryPath("cifrato.ecf")
        let meta = try await CrypteraEngine.shared.encrypt(
            EncryptRequest(
                source: .file(path: source),
                outputPath: encrypted,
                password: "password-di-prova",
                keyfilePath: nil,
                payloadCompression: .zlib,
                archiveCompression: .none,
                skipSpecialFiles: false,
                enablePasswordCheck: true,
                hideFilename: false,
                securityProfile: .standard,
                integrityProfile: .standard
            )
        )

        // I parametri richiesti devono finire nell'header senza aggiustamenti.
        XCTAssertEqual(meta.version, 5, "il writer corrente produce header v5")
        XCTAssertEqual(meta.argon2Time, 3)
        XCTAssertEqual(meta.argon2MemKib, 65536)
        XCTAssertEqual(meta.argon2Par, 2)
        XCTAssertEqual(meta.k, 24)
        XCTAssertEqual(meta.r, 8)

        let restored = try temporaryPath("ripristinato.bin")
        _ = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: encrypted,
                outputPath: restored,
                password: "password-di-prova",
                keyfilePath: nil,
                extractArchive: false,
                keepArchive: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored)), plaintext)
    }

    // MARK: - Progress e cancellazione

    func testIlProgressRiportaStageTipizzati() async throws {
        let source = try temporaryPath("progress.bin")
        try Data(repeating: 9, count: 512 * 1024).write(to: URL(fileURLWithPath: source))
        let encrypted = try temporaryPath("progress.ecf")

        let box = StageBox()
        _ = try await CrypteraEngine.shared.encrypt(
            EncryptRequest(
                source: .file(path: source),
                outputPath: encrypted,
                password: "p",
                keyfilePath: nil,
                payloadCompression: .none,
                archiveCompression: .none,
                skipSpecialFiles: false,
                enablePasswordCheck: false,
                hideFilename: false,
                securityProfile: .standard,
                integrityProfile: .low
            ),
            onProgress: { box.record($0) }
        )

        let stages = box.stages
        XCTAssertFalse(stages.isEmpty, "il progress deve essere riportato")
        XCTAssertTrue(
            stages.contains(.encrypting),
            "atteso lo stage 'encrypt' mappato su .encrypting, ottenuti \(stages)"
        )
        assertNessunoStageSconosciuto(stages)

        // Anche decrypt e verify vanno coperti: il core emette stringhe diverse
        // per ciascuna operazione, e una sola coperta lascerebbe passare un
        // mismatch sulle altre due.
        let decBox = StageBox()
        let restored = try temporaryPath("progress-restored.bin")
        _ = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: encrypted,
                outputPath: restored,
                password: "p",
                keyfilePath: nil,
                extractArchive: false,
                keepArchive: false
            ),
            onProgress: { decBox.record($0) }
        )
        XCTAssertTrue(
            decBox.stages.contains(.decrypting),
            "atteso .decrypting, ottenuti \(decBox.stages)"
        )
        assertNessunoStageSconosciuto(decBox.stages)

        let verBox = StageBox()
        _ = try await CrypteraEngine.shared.verify(
            VerifyRequest(inputPath: encrypted, password: "p", keyfilePath: nil),
            onProgress: { verBox.record($0) }
        )
        XCTAssertTrue(
            verBox.stages.contains(.verifying),
            "atteso .verifying, ottenuti \(verBox.stages)"
        )
        assertNessunoStageSconosciuto(verBox.stages)
    }

    /// Uno stage non mappato non è un errore fatale, ma significa che il core ne
    /// emette uno nuovo e la UI mostrerebbe una fase senza nome.
    private func assertNessunoStageSconosciuto(
        _ stages: [OperationStage],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sconosciuti = stages.filter { if case .unknown = $0 { return true } else { return false } }
        XCTAssertTrue(sconosciuti.isEmpty, "stage non mappati: \(sconosciuti)", file: file, line: line)
    }

    func testCancellazionePrimaDellAvvioProduceCancelled() async throws {
        let source = try temporaryPath("annulla.bin")
        try Data(repeating: 3, count: 256 * 1024).write(to: URL(fileURLWithPath: source))

        let token = CancelToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled())

        do {
            _ = try await CrypteraEngine.shared.encrypt(
                EncryptRequest(
                    source: .file(path: source),
                    outputPath: try temporaryPath("annulla.ecf"),
                    password: "p",
                    keyfilePath: nil,
                    payloadCompression: .none,
                    archiveCompression: .none,
                    skipSpecialFiles: false,
                    enablePasswordCheck: false,
                    hideFilename: false,
                    securityProfile: .standard,
                    integrityProfile: .low
                ),
                token: token
            )
            XCTFail("un'operazione annullata non deve completare")
        } catch let error as CrypteraError {
            guard case .Cancelled = error else {
                return XCTFail("atteso Cancelled, ottenuto \(error)")
            }
        }
    }

    // MARK: - Profili (SPEC §5.2)

    func testValoriDeiProfiliNonDivergonoDalDesktop() {
        // I valori vivono solo in Rust: qui si verifica che l'FFI li esponga
        // invariati, non si duplicano.
        XCTAssertEqual(securityProfileMemoryBytes(profile: .standard), 64 * 1024 * 1024)
        XCTAssertEqual(securityProfileMemoryBytes(profile: .strong), 256 * 1024 * 1024)
        XCTAssertEqual(securityProfileMemoryBytes(profile: .paranoid), 512 * 1024 * 1024)

        XCTAssertEqual(integrityProfileOverheadPercent(profile: .low), 14)
        XCTAssertEqual(integrityProfileOverheadPercent(profile: .standard), 33)
        XCTAssertEqual(integrityProfileOverheadPercent(profile: .high), 100)
        XCTAssertEqual(integrityProfileOverheadPercent(profile: .max), 300)
    }

    // MARK: - Helper

    private func fixturePath(_ name: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "ecf", subdirectory: "Fixtures")
        return try XCTUnwrap(url, "fixture \(name).ecf assente dal bundle di test").path
    }

    /// Percorso in una cartella temporanea unica per il test, ripulita al termine.
    private func temporaryPath(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrypteraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name).path
    }
}

/// Raccoglitore thread-safe: il progress arriva da un thread Rust.
private final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [OperationStage] = []

    func record(_ progress: OperationProgress) {
        lock.lock()
        defer { lock.unlock() }
        if !seen.contains(progress.stage) { seen.append(progress.stage) }
    }

    var stages: [OperationStage] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}
