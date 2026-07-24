import Foundation

/// Stato della schermata Encrypt (SPEC §8.2).
///
/// M5 copre il **file singolo**. La cartella è M6: aggiunge il TAR intermedio e
/// la verifica dello spazio, che nel caso peggiore serve al doppio della
/// sorgente più l'overhead di parità.
@MainActor
@Observable
final class EncryptModel {

    struct Selection: Equatable {
        let url: URL
        let size: UInt64?
        var name: String { url.lastPathComponent }
    }

    struct Output: Equatable {
        let url: URL
        let meta: MetaInfo
        var name: String { url.lastPathComponent }
    }

    // ─── Input ─────────────────────────────────────────────────────
    private(set) var input: Selection?
    var password = ""
    var passwordConfirmation = ""
    private(set) var keyfile: Selection?

    // ─── Opzioni ───────────────────────────────────────────────────
    //
    // I valori iniziali arrivano dalle impostazioni: chi cifra sempre allo
    // stesso modo non deve riaprire il pannello a ogni file.
    var payloadCompression: PayloadCompression
    var securityProfile: SecurityProfile
    var integrityProfile: IntegrityProfile
    var hideFilename = false
    var enablePasswordCheck = true

    init(defaults: EncryptionDefaults = .current) {
        payloadCompression = defaults.payloadCompression
        securityProfile = defaults.securityProfile
        integrityProfile = defaults.integrityProfile
    }

    /// Rilegge i predefiniti, ma **solo a schermata ferma**.
    ///
    /// Il modello si costruisce una volta sola, quando la `TabView` crea la
    /// schermata: senza questo, un predefinito cambiato nelle impostazioni non
    /// arriverebbe mai a una schermata Cifra già esistente — l'impostazione
    /// risulterebbe salvata e inerte.
    ///
    /// La condizione conta: rileggerli mentre c'è un file scelto o
    /// un'operazione in corso sovrascriverebbe scelte fatte apposta per **quel**
    /// file.
    func refreshDefaultsIfIdle() {
        guard input == nil, output == nil, !isRunning, password.isEmpty else { return }
        let defaults = EncryptionDefaults.current
        payloadCompression = defaults.payloadCompression
        securityProfile = defaults.securityProfile
        integrityProfile = defaults.integrityProfile
    }

    // ─── Esecuzione ────────────────────────────────────────────────
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var progress: OperationProgress?
    private(set) var errorMessage: String?
    private(set) var output: Output?

    private var token: CancelToken?
    private var workspace: TemporaryWorkspace?

    // MARK: - Derivati

    var strength: PasswordStrength { PasswordStrength(password) }

    var passwordsMatch: Bool {
        !passwordConfirmation.isEmpty && password == passwordConfirmation
    }

    /// Perché non si può ancora cifrare, o `nil` se si può.
    ///
    /// Un unico punto: la vista mostra questo motivo accanto al pulsante
    /// disattivato, invece di lasciare l'utente a indovinare cosa manca.
    var blockingReason: String? {
        if input == nil { return L.t("Choose a file to encrypt.") }
        if password.isEmpty { return L.t("Enter a password.") }
        // La stessa regola del desktop, che **impedisce** la cifratura e non si
        // limita ad avvisare (`operations.js`, `handleEncrypt`). Il messaggio
        // distingue però quale delle due condizioni manca: "troppo debole" a chi
        // ha scelto bene i caratteri e si è fermato a nove manderebbe a cercare
        // il problema dove non è.
        if let violation = strength.policyViolation { return violation }
        if !passwordsMatch { return L.t("The two passwords do not match.") }
        if !securityProfileFitsMemory {
            return L.t("This device does not have enough memory for the chosen profile.")
        }
        return nil
    }

    var canRun: Bool { blockingReason == nil && !isRunning }

    /// Il profilo di sicurezza è eseguibile con la memoria disponibile ora?
    ///
    /// Argon2 alloca un blocco contiguo: su iOS superare il limite jetsam
    /// **termina il processo senza eccezione catturabile** (SPEC §11.2). Meglio
    /// dirlo prima. I parametri non si abbassano di nascosto — cambierebbero la
    /// chiave derivata, quindi il file.
    var securityProfileFitsMemory: Bool { securityProfile.fitsInAvailableMemory }

    /// Memoria richiesta dal profilo, letta da Rust.
    var securityProfileMemory: String {
        SizeFormatter.string(securityProfileMemoryBytes(profile: securityProfile))
    }

    /// Overhead di parità in percentuale, letto da Rust.
    var integrityOverheadPercent: UInt32 {
        integrityProfileOverheadPercent(profile: integrityProfile)
    }

    /// Dimensione finale stimata.
    ///
    /// Serve perché `Max` produce un file **oltre tre volte** più grande, e
    /// scoprirlo a operazione finita è una sorpresa sgradevole (SPEC §8.2).
    ///
    /// È una stima dichiarata tale: ignora header e trailer (poche centinaia di
    /// byte) e **non può tenere conto della compressione**, il cui effetto
    /// dipende dal contenuto. Con la compressione attiva il risultato reale è
    /// quindi più piccolo di così, mai più grande.
    var estimatedOutputSize: String? {
        guard let size = input?.size else { return nil }
        let withParity = Double(size) * (1.0 + Double(integrityOverheadPercent) / 100.0)
        return SizeFormatter.string(UInt64(withParity))
    }

    // MARK: - Selezione

    func select(_ url: URL) {
        input = Selection(url: url, size: Self.fileSize(of: url))
        discardWork()
        errorMessage = nil
    }

    func selectKeyfile(_ url: URL) {
        keyfile = Selection(url: url, size: Self.fileSize(of: url))
    }

    func clearKeyfile() {
        keyfile = nil
    }

    // MARK: - Esecuzione

    func cancel() {
        token?.cancel()
    }

    /// Pausa e ripresa passano dallo stesso token della cancellazione.
    func togglePause() {
        isPaused.toggle()
        token?.setPaused(paused: isPaused)
    }

    func run() async {
        guard let input, canRun else { return }

        // Un output precedente mai salvato non deve restare su disco quando ne
        // arriva un altro.
        discardWork()

        let workspace: TemporaryWorkspace
        do {
            workspace = try TemporaryWorkspace()
        } catch {
            errorMessage = ErrorPresenter.message(for: .IoError)
            return
        }
        self.workspace = workspace

        // Il `.ecf` prende il nome del file di partenza. Non è un dato che
        // proviene da un file cifrato, quindi non c'è nulla da sanificare: è il
        // nome che l'utente ha scelto nel picker.
        let destination = workspace.directory
            .appendingPathComponent("\(input.name).ecf", isDirectory: false)

        let token = CancelToken()
        self.token = token
        isRunning = true
        isPaused = false
        progress = nil
        errorMessage = nil
        output = nil
        defer {
            isRunning = false
            isPaused = false
            self.token = nil
        }

        let password = password
        let inputURL = input.url
        let keyfileURL = keyfile?.url
        let request = (
            payload: payloadCompression,
            security: securityProfile,
            integrity: integrityProfile,
            hide: hideFilename,
            check: enablePasswordCheck
        )

        do {
            let meta = try await FileAccess.withSecurityScope(
                input: inputURL,
                keyfile: keyfileURL
            ) { inputPath, keyfilePath in
                try await CrypteraEngine.shared.encrypt(
                    EncryptRequest(
                        source: .file(path: inputPath),
                        outputPath: destination.path,
                        password: password,
                        keyfilePath: keyfilePath,
                        payloadCompression: request.payload,
                        // Riguarda solo le cartelle (M6): qui il payload è un
                        // file, non un archivio.
                        archiveCompression: .none,
                        skipSpecialFiles: false,
                        enablePasswordCheck: request.check,
                        hideFilename: request.hide,
                        securityProfile: request.security,
                        integrityProfile: request.integrity
                    ),
                    token: token,
                    onProgress: { [weak self] update in
                        // Il callback arriva da un thread Rust: hop sul main
                        // actor prima di toccare stato osservabile (SPEC §7).
                        Task { @MainActor in self?.progress = update }
                    }
                )
            }
            output = Output(url: destination, meta: meta)
        } catch let error as CrypteraError {
            discardWork()
            errorMessage = ErrorPresenter.message(for: error)
        } catch {
            discardWork()
            errorMessage = ErrorPresenter.unexpected
        }
    }

    /// L'output cifrato non contiene segreti in chiaro, ma occupa spazio e non
    /// serve più una volta salvato.
    func discardWork() {
        workspace?.discard()
        workspace = nil
        output = nil
        progress = nil
    }

    /// Azzera le password appena l'operazione è conclusa.
    ///
    /// SPEC §12.1 è onesta sul limite: una `String` Swift non è azzerabile in
    /// modo affidabile, il runtime può averne fatto copie. Quel che si può fare
    /// è **ridurne la vita**, e questo lo fa.
    func clearPasswords() {
        password = ""
        passwordConfirmation = ""
    }

    private static func fileSize(of url: URL) -> UInt64? {
        // L'attributo si legge anche senza scope attivo per gli URL del picker;
        // se non fosse leggibile la stima semplicemente non viene mostrata.
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(UInt64.init)
    }
}
