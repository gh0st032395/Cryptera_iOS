import XCTest
@testable import Cryptera

/// **M7 punto 3 — round-trip incrociato, direzione desktop → iOS.**
///
/// È il test che il piano indica come *l'unico che dimostra davvero la
/// compatibilità*: tutti gli altri possono passare con un formato divergente,
/// perché confrontano il nostro codice con sé stesso.
///
/// I file in `CrossFixtures/` sono stati prodotti dall'**applicazione desktop
/// 2.0.4** e congelati. Non sono rigenerabili da uno script: l'app è Tauri e non
/// espone una riga di comando, e `crypto_core_rs` è una libreria senza
/// `[[bin]]`. Le istruzioni per rifarli sono in `COME-GENERARLE.md`.
///
/// Congelarli non è un ripiego: sono byte usciti dal binario reale, e restano
/// una prova valida anche fra dieci versioni. È lo stesso motivo per cui
/// l'upstream committa `tests/fixtures/`.
///
/// La direzione opposta — iOS → desktop — **non è automatizzabile in modo
/// significativo**: il percorso di lettura del desktop è la stessa libreria allo
/// stesso tag che usiamo noi, quindi un test la confronterebbe con sé stessa.
/// Resta un passo manuale della checklist di rilascio.
final class CrossCompatTests: XCTestCase {

    private static let password = "CrossTestP@ssw0rd42"

    // MARK: - Parametri: la verifica che vale per tutte

    /// I profili del desktop e i nostri devono produrre **gli stessi numeri
    /// nell'header**.
    ///
    /// È il controllo più importante del file: se una tabella di SPEC §5.2
    /// divergesse, i file resterebbero leggibili ma non sarebbero più gli
    /// stessi file — e nessun altro test se ne accorgerebbe, perché ognuno
    /// verifica il proprio lato.
    func testIProfiliDelDesktopCoincidonoConINostri() throws {
        let attesi: [(String, SecurityProfile, IntegrityProfile)] = [
            ("desktop-standard", .standard, .standard),
            ("desktop-alta-zlib", .strong, .low),
            ("desktop-massima-lzma", .paranoid, .max),
            ("desktop-cartella-gz", .standard, .standard),
        ]

        for (nome, sicurezza, integrita) in attesi {
            let meta = try readMetadata(path: try crossFixture(nome).path)
            let params = securityProfileParams(profile: sicurezza)

            XCTAssertEqual(meta.argon2Time, params.timeCost, "\(nome): passaggi Argon2")
            XCTAssertEqual(meta.argon2MemKib, params.memoryKib, "\(nome): memoria Argon2")
            XCTAssertEqual(meta.argon2Par, params.parallelism, "\(nome): parallelismo Argon2")

            let (k, r) = Self.espansione(integrita)
            XCTAssertEqual(meta.k, k, "\(nome): k")
            XCTAssertEqual(meta.r, r, "\(nome): r")

            XCTAssertEqual(meta.version, 5, "\(nome): il writer 2.0.4 produce header v5")
        }
    }

    /// I valori di SPEC §5.2 attesi per ogni profilo di integrità. Scritti a
    /// mano di proposito: se li si leggesse da Rust, un errore in Rust
    /// renderebbe il test d'accordo con l'errore.
    private static func espansione(_ profile: IntegrityProfile) -> (UInt16, UInt16) {
        switch profile {
        case .low: return (28, 4)
        case .standard: return (24, 8)
        case .high: return (12, 12)
        case .max: return (8, 24)
        }
    }

    // MARK: - File singoli

    func testFileStandardProdottoDalDesktop() async throws {
        try await verificaFileSingolo("desktop-standard", sorgente: "nota.txt", nomeAtteso: "nota.txt")
    }

    /// Profilo Alta con compressione Zlib: il payload è compresso, quindi il
    /// percorso di decompressione fa parte di ciò che si sta verificando.
    func testFileAltaConZlib() async throws {
        try await verificaFileSingolo("desktop-alta-zlib", sorgente: "nota.txt", nomeAtteso: "nota.txt")
    }

    /// LZMA2 è la variante che dipende da `liblzma`, il rischio più alto del
    /// progetto rientrato in M1: questo file lo verifica su dati veri prodotti
    /// dall'altra piattaforma.
    func testFileMassimaConLzma() async throws {
        try await verificaFileSingolo("desktop-massima-lzma", sorgente: "dati.bin", nomeAtteso: "dati.bin")
    }

    /// Con il nome nascosto il desktop non memorizza alcun nome, quindi
    /// `FLAG_ENC_FILENAME` resta **spento**: non è un nome cifrato da svelare
    /// con la password, è un nome che non c'è.
    ///
    /// È la stessa distinzione trovata in M5 sul nostro writer, qui confermata
    /// in modo indipendente dai byte del desktop.
    func testFileConNomeNascosto() async throws {
        let meta = try readMetadata(path: try crossFixture("desktop-nome-nascosto").path)
        XCTAssertFalse(
            describeHeader(meta: meta).filenameEncrypted,
            "nascondere il nome significa non memorizzarne alcuno"
        )

        let decifrato = try await verificaFileSingolo(
            "desktop-nome-nascosto",
            sorgente: "nota.txt",
            nomeAtteso: ""
        )
        XCTAssertTrue(decifrato.filename.isEmpty)
    }

    func testFileConKeyfile() async throws {
        let fixture = try crossFixture("desktop-keyfile")
        let keyfile = try source("chiave.key")
        let out = try temporaryPath("con-keyfile.bin")

        _ = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: fixture.path,
                outputPath: out,
                password: Self.password,
                keyfilePath: keyfile.path,
                extractArchive: false,
                keepArchive: false
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: out)),
            try Data(contentsOf: try source("nota.txt"))
        )
    }

    /// Lo stesso file **senza** keyfile non deve aprirsi: se si aprisse, il
    /// keyfile non starebbe entrando nella derivazione della chiave.
    func testIlFileConKeyfileNonSiApreSenzaKeyfile() async throws {
        let fixture = try crossFixture("desktop-keyfile")
        let out = try temporaryPath("senza-keyfile.bin")

        do {
            _ = try await CrypteraEngine.shared.decrypt(
                DecryptRequest(
                    inputPath: fixture.path,
                    outputPath: out,
                    password: Self.password,
                    keyfilePath: nil,
                    extractArchive: false,
                    keepArchive: false
                )
            )
            XCTFail("senza keyfile non deve decifrare")
        } catch let error as CrypteraError {
            switch error {
            case .PasswordInvalid, .HeaderAuthFailed:
                break  // entrambi legittimi: dipende da quale controllo scatta prima
            default:
                XCTFail("errore inatteso: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out), "nessun output parziale")
    }

    // MARK: - Cartelle

    /// Le tre compressioni d'archivio, cioè i tre decoder TAR.
    ///
    /// Sono il punto in cui la nostra orchestrazione differisce di più da quella
    /// del desktop: noi passiamo la compressione come parametro esplicito, il
    /// desktop la deduce dal suffisso del percorso. Questi tre file dimostrano
    /// che le due strade portano allo stesso contenuto.
    func testCartellaConGzip() async throws {
        try await verificaCartella("desktop-cartella-gz")
    }

    func testCartellaConXz() async throws {
        try await verificaCartella("desktop-cartella-xz")
    }

    func testCartellaConBzip2() async throws {
        try await verificaCartella("desktop-cartella-bz2")
    }

    /// Le tre compressioni devono aver prodotto archivi **davvero diversi**:
    /// se il desktop avesse ignorato la scelta, i tre file avrebbero lo stesso
    /// payload e i test qui sopra passerebbero comunque.
    func testLeTreCompressioniHannoProdottoArchiviDiversi() throws {
        let dimensioni = try ["desktop-cartella-gz", "desktop-cartella-xz", "desktop-cartella-bz2"]
            .map { try readMetadata(path: try crossFixture($0).path).plainSize }

        XCTAssertEqual(
            Set(dimensioni).count, 3,
            "tre compressioni diverse devono dare tre archivi di dimensione diversa: \(dimensioni)"
        )
    }

    // MARK: - Helper

    @discardableResult
    private func verificaFileSingolo(
        _ fixture: String,
        sorgente: String,
        nomeAtteso: String
    ) async throws -> MetaInfo {
        let input = try crossFixture(fixture)
        let out = try temporaryPath("\(fixture).out")

        // La verifica non scrive nulla: se fallisce, il file è già compromesso
        // e la decifratura direbbe la stessa cosa in modo meno chiaro.
        _ = try await CrypteraEngine.shared.verify(
            VerifyRequest(inputPath: input.path, password: Self.password, keyfilePath: nil)
        )

        let meta = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: input.path,
                outputPath: out,
                password: Self.password,
                keyfilePath: nil,
                extractArchive: false,
                keepArchive: false
            )
        )

        XCTAssertEqual(meta.filename, nomeAtteso, "\(fixture): nome originale")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: out)),
            try Data(contentsOf: try source(sorgente)),
            "\(fixture): il contenuto decifrato deve essere identico all'originale"
        )
        return meta
    }

    private func verificaCartella(_ fixture: String) async throws {
        let input = try crossFixture(fixture)
        let out = try temporaryPath(fixture)

        let meta = try await CrypteraEngine.shared.decrypt(
            DecryptRequest(
                inputPath: input.path,
                outputPath: out,
                password: Self.password,
                keyfilePath: nil,
                extractArchive: true,
                keepArchive: false
            )
        )
        XCTAssertTrue(describeHeader(meta: meta).isTarContainer, "\(fixture): atteso un container TAR")

        // L'archivio contiene una cartella di primo livello col nome originale.
        let estratta = URL(fileURLWithPath: out).appendingPathComponent("documenti")
        let attesa = try source("documenti")

        let ottenuti = try Self.albero(di: estratta)
        let previsti = try Self.albero(di: attesa)
        XCTAssertEqual(
            ottenuti.keys.sorted(), previsti.keys.sorted(),
            "\(fixture): struttura della cartella diversa"
        )
        for (percorso, contenuto) in previsti {
            XCTAssertEqual(ottenuti[percorso], contenuto, "\(fixture): contenuto diverso in \(percorso)")
        }
    }

    /// Mappa percorso relativo → contenuto, per confrontare due alberi.
    private static func albero(di root: URL) throws -> [String: Data] {
        var risultato: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for case let url as URL in enumerator ?? .init() {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                continue
            }
            let relativo = url.path.replacingOccurrences(of: root.path + "/", with: "")
            risultato[relativo] = try Data(contentsOf: url)
        }
        return risultato
    }

    /// I file del desktop entrano nel bundle come folder reference: senza
    /// `subdirectory` la lookup fallisce. Una fixture mancante **fa fallire** il
    /// test — non lo skippa — perché uno skip trasformerebbe il gate di rilascio
    /// in un verde che non dimostra nulla.
    private func crossFixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "ecf", subdirectory: "CrossFixtures")
        return try XCTUnwrap(url, "fixture del desktop assente: \(name).ecf")
    }

    private func source(_ name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let root = try XCTUnwrap(
            bundle.url(forResource: "CrossFixtures", withExtension: nil),
            "cartella CrossFixtures assente dal bundle di test"
        )
        let url = root.appendingPathComponent("sorgenti").appendingPathComponent(name)
        // Fallisce, non salta: uno skip trasformerebbe il gate di rilascio in un
        // verde che non dimostra nulla — la stessa regola già applicata alle
        // fixture dell'upstream in M2.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "sorgente di confronto assente dal bundle: \(name)"
        )
        return url
    }

    private func temporaryPath(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name).path
    }
}
