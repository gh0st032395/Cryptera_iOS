import XCTest
@testable import Cryptera

/// Misure di memoria e tempo sui tre profili Argon2 (M10).
///
/// **Vanno eseguite su un device, non in simulatore.** Il simulatore non ha i
/// limiti jetsam: là `Paranoid` gira sempre, e la domanda che conta — la soglia
/// del preflight è quella giusta su hardware vero? — non si può nemmeno porre.
///
/// Questi test **misurano**, non asseriscono soglie: la memoria disponibile
/// dipende da cosa sta facendo il telefono in quel momento, e un test che
/// fallisce perché era aperta un'altra app non direbbe niente sul codice.
/// Le assunzioni verificabili — che il preflight sia coerente con sé stesso e
/// che un profilo ammesso non uccida il processo — sono asserite; i numeri
/// vengono stampati per essere letti.
final class MemoriaSuDeviceTests: XCTestCase {

    // MARK: - Strumenti

    /// Impronta di memoria fisica del processo: è ciò che jetsam osserva.
    /// `os_proc_available_memory()` dice quanto ne resta, questo quanto se ne usa.
    ///
    /// È una funzione libera, non un metodo: il campionatore gira in un task
    /// staccato, e catturare il caso di test — che non è `Sendable` — non passa
    /// il controllo di concorrenza di Swift 6.
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func mib(_ bytes: UInt64) -> String {
        String(format: "%.0f MiB", Double(bytes) / 1024 / 1024)
    }

    /// Massimo dell'impronta osservata, aggiornato da un campionatore.
    ///
    /// Misurare prima e dopo **non basta**: Argon2 alloca il suo blocco e lo
    /// libera prima che l'operazione ritorni, quindi la lettura finale può
    /// risultare più bassa di quella iniziale — è successo con `Paranoid`, dove
    /// l'impronta scendeva da 347 a 280 MiB e il picco non compariva da nessuna
    /// parte. Il numero che conta per jetsam è il massimo durante.
    private final class Picco: @unchecked Sendable {
        private let lock = NSLock()
        private var massimo: UInt64 = 0

        func offri(_ valore: UInt64) {
            lock.lock(); defer { lock.unlock() }
            massimo = max(massimo, valore)
        }

        var valore: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return massimo
        }
    }

    /// Campiona l'impronta finché il task non viene annullato.
    private static func campionatore(_ picco: Picco) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                picco.offri(footprintBytes())
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func riga(_ testo: String) {
        // Prefisso cercabile nel log di xcodebuild.
        print("MEM \(testo)")
    }

    // MARK: - Quadro della memoria

    func testQuadroMemoriaEPreflight() throws {
        let disponibile = UInt64(os_proc_available_memory())
        riga("─── device ───")
        riga("memoria disponibile al processo: \(mib(disponibile))")
        riga("impronta attuale:                \(mib(Self.footprintBytes()))")

        // In **simulatore `os_proc_available_memory()` risponde 0**: non è
        // implementata. Non è un difetto da correggere ma il motivo per cui
        // questo test esiste — la domanda "il preflight è tarato bene?" non è
        // nemmeno ponibile dove la memoria disponibile non è osservabile.
        //
        // `fitsInAvailableMemory` tratta già lo zero come "stima non
        // disponibile" e non blocca: è la scelta giusta, perché rifiutare tutto
        // per mancanza di una stima renderebbe l'app inutilizzabile dove quella
        // chiamata non risponde. Qui si salta, invece di asserire su un numero
        // che non esiste.
        try XCTSkipUnless(
            disponibile > 0,
            "os_proc_available_memory() risponde 0 (simulatore): misura non disponibile"
        )

        riga("─── profili ───")
        for profilo in [SecurityProfile.standard, .strong, .paranoid] {
            let richiesta = securityProfileMemoryBytes(profile: profilo)
            let passa = profilo.fitsInAvailableMemory
            let quota = Double(richiesta) / Double(disponibile) * 100
            riga(
                String(
                    format: "%-9@ richiede %-9@ (%.1f%% del disponibile) → preflight: %@",
                    "\(profilo)" as NSString,
                    mib(richiesta) as NSString,
                    quota,
                    (passa ? "ammesso" : "RIFIUTATO") as NSString
                )
            )
        }

        // Coerenza interna: la soglia è al 50%, quindi un profilo ammesso deve
        // stare entro metà del disponibile. Non dipende dallo stato del telefono.
        for profilo in [SecurityProfile.standard, .strong, .paranoid]
        where profilo.fitsInAvailableMemory {
            XCTAssertLessThanOrEqual(
                securityProfileMemoryBytes(profile: profilo), disponibile / 2,
                "\(profilo) è ammesso dal preflight ma supera metà della memoria disponibile"
            )
        }
    }

    // MARK: - Tempo e sopravvivenza

    /// Cifra lo stesso file coi tre profili, in ordine crescente di costo.
    ///
    /// L'ordine non è estetico: se `Paranoid` fa terminare il processo, i tempi
    /// dei due profili più leggeri sono già stati stampati e non si perdono.
    /// Un test che partisse dal caso peggiore non lascerebbe alcun dato.
    func testTempiESopravvivenzaDeiTreProfili() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // File piccolo di proposito: così il tempo misurato è dominato da
        // Argon2, che è ciò che distingue i profili. Con un file grande si
        // misurerebbe soprattutto l'I/O.
        let sorgente = dir.appendingPathComponent("piccolo.txt")
        try Data(repeating: 0x41, count: 4096).write(to: sorgente)

        riga("─── tempi (file da 4 KiB, il costo è tutto Argon2) ───")

        for profilo in [SecurityProfile.standard, .strong, .paranoid] {
            guard profilo.fitsInAvailableMemory else {
                riga("\(profilo): rifiutato dal preflight, non eseguito")
                continue
            }

            let destinazione = dir.appendingPathComponent("\(profilo).ecf")
            let primaFootprint = Self.footprintBytes()
            let picco = Picco()
            picco.offri(primaFootprint)
            let sonda = Self.campionatore(picco)
            let inizio = Date()

            _ = try await CrypteraEngine.shared.encrypt(
                EncryptRequest(
                    source: .file(path: sorgente.path),
                    outputPath: destinazione.path,
                    password: "password-di-prova-lunga",
                    keyfilePath: nil,
                    payloadCompression: .none,
                    archiveCompression: .none,
                    skipSpecialFiles: false,
                    enablePasswordCheck: true,
                    hideFilename: false,
                    securityProfile: profilo,
                    integrityProfile: .low
                )
            )

            let secondi = Date().timeIntervalSince(inizio)
            sonda.cancel()

            let richiesta = securityProfileMemoryBytes(profile: profilo)
            let crescita = picco.valore > primaFootprint ? picco.valore - primaFootprint : 0
            riga(
                String(
                    format: "%-9@ %6.2f s   base %@  picco %@  (+%@ per %@ richiesti)",
                    "\(profilo)" as NSString,
                    secondi,
                    mib(primaFootprint) as NSString,
                    mib(picco.valore) as NSString,
                    mib(crescita) as NSString,
                    mib(richiesta) as NSString
                )
            )

            // Se siamo arrivati qui il processo è vivo: il profilo ammesso dal
            // preflight non ha fatto scattare jetsam. È l'asserzione implicita
            // che questo test esiste per fare.
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: destinazione.path),
                "\(profilo): cifratura completata senza produrre il file"
            )
        }
    }

    /// Lo stesso profilo, ripetuto: l'impronta si stabilizza o cresce?
    ///
    /// È la domanda che riguarda il **batch**, che esegue le operazioni in
    /// sequenza nello stesso processo. Misurando i tre profili di fila si vede
    /// che l'impronta di base non torna al valore iniziale fra un'operazione e
    /// l'altra — l'allocatore non restituisce subito le pagine al sistema. Se
    /// quel residuo si sommasse a ogni file, una coda lunga col profilo più
    /// pesante finirebbe per superare il limite: e jetsam non è un errore che
    /// si possa mostrare, è la scomparsa dell'app a metà lavoro.
    ///
    /// Non asserisce una soglia assoluta — dipende dal device — ma che il picco
    /// **non cresca di iterazione in iterazione**, che è la proprietà da cui
    /// dipende la sicurezza del batch.
    func testImprontaNonCresceRipetendoLoStessoProfilo() async throws {
        let profilo = SecurityProfile.paranoid
        try XCTSkipUnless(
            profilo.fitsInAvailableMemory,
            "il profilo più pesante non è ammesso su questo device: niente da misurare"
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-rip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sorgente = dir.appendingPathComponent("piccolo.txt")
        try Data(repeating: 0x41, count: 4096).write(to: sorgente)

        riga("─── \(profilo) ripetuto (comportamento del batch) ───")
        var picchi: [UInt64] = []

        for iterazione in 1...5 {
            let destinazione = dir.appendingPathComponent("rip-\(iterazione).ecf")
            let picco = Picco()
            picco.offri(Self.footprintBytes())
            let sonda = Self.campionatore(picco)

            _ = try await CrypteraEngine.shared.encrypt(
                EncryptRequest(
                    source: .file(path: sorgente.path),
                    outputPath: destinazione.path,
                    password: "password-di-prova-lunga",
                    keyfilePath: nil,
                    payloadCompression: .none,
                    archiveCompression: .none,
                    skipSpecialFiles: false,
                    enablePasswordCheck: true,
                    hideFilename: false,
                    securityProfile: profilo,
                    integrityProfile: .low
                )
            )
            sonda.cancel()
            picchi.append(picco.valore)
            riga(String(format: "  iterazione %d: picco %@", iterazione, mib(picco.valore) as NSString))
        }

        // Il confronto è fra la **seconda** e l'ultima: la prima paga
        // l'inizializzazione del pool di thread e dell'allocatore, e includerla
        // farebbe sembrare una crescita quella che è solo la partenza a freddo.
        let riferimento = picchi[1]
        let ultimo = picchi[picchi.count - 1]
        let crescita = ultimo > riferimento ? ultimo - riferimento : 0
        riga("crescita dalla 2ª alla 5ª iterazione: \(mib(crescita))")

        // Tolleranza di 64 MiB: sotto quella soglia è rumore dell'allocatore,
        // non accumulo. Un accumulo vero, su cinque iterazioni, si vedrebbe
        // nell'ordine delle centinaia di MiB.
        XCTAssertLessThan(
            crescita, 64 * 1024 * 1024,
            "l'impronta cresce a ogni operazione: una coda lunga finirebbe per far terminare l'app"
        )
    }
}
