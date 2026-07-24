import Foundation

/// Stato della schermata Encrypt (SPEC §8.2).
///
/// Copre file singoli (M5) e cartelle (M6). La differenza non è solo l'input:
/// una cartella passa da un **archivio TAR intermedio**, quindi ha una
/// compressione propria e un fabbisogno di spazio molto maggiore, che va
/// verificato prima di iniziare.
@MainActor
@Observable
final class EncryptModel {

    struct Selection: Equatable {
        enum Kind {
            case file
            case folder
        }

        let url: URL
        let kind: Kind
        /// Somma dei file contenuti, per una cartella. `nil` se non misurabile.
        let size: UInt64?
        /// Quanti file contiene, solo per le cartelle.
        let fileCount: Int?

        var name: String { url.lastPathComponent }
        var isFolder: Bool { kind == .folder }
    }

    struct Output: Equatable {
        let url: URL
        let meta: MetaInfo
        var name: String { url.lastPathComponent }
    }

    // ─── Input ─────────────────────────────────────────────────────
    private(set) var input: Selection?
    /// La misura di una cartella grande non è istantanea.
    private(set) var isMeasuring = false
    var password = ""
    var passwordConfirmation = ""
    private(set) var keyfile: Selection?

    // ─── Opzioni ───────────────────────────────────────────────────
    //
    // I valori iniziali arrivano dalle impostazioni: chi cifra sempre allo
    // stesso modo non deve riaprire il pannello a ogni file.
    var payloadCompression: PayloadCompression
    var archiveCompression: ArchiveCompression
    var securityProfile: SecurityProfile
    var integrityProfile: IntegrityProfile
    var hideFilename = false
    var enablePasswordCheck = true
    /// Attivo come nell'upstream: symlink e file speciali fanno fallire
    /// l'archiviazione più spesso di quanto servano.
    var skipSpecialFiles = true

    // ─── Esecuzione ────────────────────────────────────────────────
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var progress: OperationProgress?
    private(set) var errorMessage: String?
    private(set) var output: Output?

    private var token: CancelToken?
    private var workspace: TemporaryWorkspace?

    init(defaults: EncryptionDefaults = .current) {
        payloadCompression = defaults.payloadCompression
        archiveCompression = defaults.archiveCompression
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
        archiveCompression = defaults.archiveCompression
        securityProfile = defaults.securityProfile
        integrityProfile = defaults.integrityProfile
    }

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
        if input == nil { return L.t("Choose a file or folder to encrypt.") }
        if isMeasuring { return L.t("Measuring the folder…") }
        // Prima della password: lo spazio non dipende da cosa si digita, e
        // scoprirlo dopo aver scelto una password sarebbe una perdita di tempo.
        if !hasEnoughStorage {
            return L.t("There is not enough free space: about %@ are needed.", requiredStorage)
        }
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

    /// L'input è una cartella: cambiano le opzioni mostrate e il fabbisogno di
    /// spazio.
    var isFolderInput: Bool { input?.isFolder == true }

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

    /// Spazio necessario, comprensivo dell'archivio intermedio per le cartelle.
    var requiredStorage: String {
        SizeFormatter.string(
            StorageCheck.requiredBytes(
                source: input?.size ?? 0,
                parityOverheadPercent: integrityOverheadPercent,
                needsArchive: isFolderInput
            )
        )
    }

    /// Verifica di SPEC §11.4, fatta **prima** di iniziare.
    ///
    /// Con una cartella serve circa il doppio della sorgente più la parità:
    /// fallire a metà avrebbe già speso minuti di CPU e riempito il disco.
    var hasEnoughStorage: Bool {
        guard let size = input?.size else { return true }
        return StorageCheck.hasRoom(
            forSource: size,
            parityOverheadPercent: integrityOverheadPercent,
            needsArchive: isFolderInput,
            on: FileManager.default.temporaryDirectory
        )
    }

    /// C'è qualcosa da azzerare?
    var hasWorkInProgress: Bool {
        input != nil || keyfile != nil || !password.isEmpty
            || !passwordConfirmation.isEmpty || output != nil || errorMessage != nil
    }

    // MARK: - Selezione

    /// Accetta sia un file sia una cartella; il tipo si legge dall'URL, non da
    /// cosa l'utente ha chiesto di scegliere — il selettore di sistema può
    /// sempre restituire altro.
    func select(_ url: URL) async {
        discardWork()
        errorMessage = nil

        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isFolder else {
            input = Selection(url: url, kind: .file, size: Self.fileSize(of: url), fileCount: nil)
            return
        }

        // Una cartella va attraversata per sapere quanto pesa, e su una cartella
        // grande non è istantaneo: si mostra lo stato e si misura fuori dal main
        // actor.
        input = Selection(url: url, kind: .folder, size: nil, fileCount: nil)
        isMeasuring = true
        defer { isMeasuring = false }

        let measurement = await Task.detached {
            try? await FileAccess.withSecurityScope(url) { _ in
                StorageCheck.measureFolder(at: url)
            }
        }.value

        // L'utente può aver cambiato scelta mentre si misurava.
        guard input?.url == url else { return }
        input = Selection(
            url: url,
            kind: .folder,
            size: measurement?.bytes,
            fileCount: measurement?.files
        )
    }

    func selectKeyfile(_ url: URL) {
        keyfile = Selection(url: url, kind: .file, size: Self.fileSize(of: url), fileCount: nil)
    }

    func clearKeyfile() {
        keyfile = nil
    }

    /// Riporta la schermata allo stato iniziale.
    ///
    /// Le opzioni tornano ai predefiniti delle impostazioni, non a quelli di
    /// serie: "da capo" significa il punto da cui si parte di solito, non un
    /// punto che l'utente non ha mai scelto.
    func reset() {
        discardWork()
        input = nil
        keyfile = nil
        password = ""
        passwordConfirmation = ""
        errorMessage = nil
        hideFilename = false
        enablePasswordCheck = true
        skipSpecialFiles = true

        let defaults = EncryptionDefaults.current
        payloadCompression = defaults.payloadCompression
        archiveCompression = defaults.archiveCompression
        securityProfile = defaults.securityProfile
        integrityProfile = defaults.integrityProfile
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

        // Il `.ecf` prende il nome dell'input. Non è un dato che proviene da un
        // file cifrato, quindi non c'è nulla da sanificare: è il nome che
        // l'utente ha scelto nel picker.
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

        // Valori copiati fuori dal main actor prima di attraversare il confine:
        // la closure non deve catturare il modello per leggerli.
        let password = password
        let inputURL = input.url
        let isFolder = input.isFolder
        let keyfileURL = keyfile?.url
        let options = (
            payload: payloadCompression,
            archive: archiveCompression,
            security: securityProfile,
            integrity: integrityProfile,
            hide: hideFilename,
            check: enablePasswordCheck,
            skipSpecial: skipSpecialFiles
        )

        do {
            let meta = try await FileAccess.withSecurityScope(
                input: inputURL,
                keyfile: keyfileURL
            ) { inputPath, keyfilePath in
                try await CrypteraEngine.shared.encrypt(
                    EncryptRequest(
                        source: isFolder ? .folder(path: inputPath) : .file(path: inputPath),
                        outputPath: destination.path,
                        password: password,
                        keyfilePath: keyfilePath,
                        // Per una cartella il payload è il TAR, che è già
                        // compresso secondo `archiveCompression`: comprimerlo
                        // due volte lo farebbe solo crescere.
                        payloadCompression: isFolder ? .none : options.payload,
                        archiveCompression: options.archive,
                        skipSpecialFiles: options.skipSpecial,
                        enablePasswordCheck: options.check,
                        hideFilename: options.hide,
                        securityProfile: options.security,
                        integrityProfile: options.integrity
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
