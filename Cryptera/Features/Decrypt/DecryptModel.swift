import Foundation

/// Stato della schermata Decrypt (SPEC §8.3).
///
/// Ordine del flusso, che è anche l'ordine dei campi: si sceglie il `.ecf`, si
/// leggono i metadati **senza password** — bastano a capire cosa si ha in mano —
/// e solo dopo si chiede la password.
@MainActor
@Observable
final class DecryptModel {

    /// Un file scelto dall'utente. L'URL è security-scoped e va aperto con
    /// `FileAccess` a ogni uso: non si tiene lo scope fra un'operazione e l'altra.
    struct Selection: Equatable {
        let url: URL
        var name: String { url.lastPathComponent }
    }

    /// Ciò che si sa del file prima di conoscere la password.
    struct Header: Equatable {
        let meta: MetaInfo
        let summary: HeaderSummary

        /// Nome originale mostrabile, o `nil` se non è leggibile senza password.
        ///
        /// Su v5 il nome viaggia cifrato: `filename` vuoto **con** il flag
        /// acceso significa "serve la password", senza flag significa che il
        /// file non ha un nome memorizzato.
        var originalName: String? {
            meta.filename.isEmpty ? nil : meta.filename
        }
    }

    /// Output pronto per essere consegnato al sistema.
    struct Output: Equatable {
        let url: URL
        let isDirectory: Bool
        var name: String { url.lastPathComponent }
    }

    // ─── Input ─────────────────────────────────────────────────────
    private(set) var input: Selection?
    private(set) var header: Header?
    /// Il file non è leggibile come `.ecf`: messaggio già presentabile.
    private(set) var headerProblem: String?
    var password = ""
    private(set) var keyfile: Selection?
    var extractArchive = false

    // ─── Esecuzione ────────────────────────────────────────────────
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var progress: OperationProgress?
    private(set) var errorMessage: String?
    private(set) var output: Output?

    private var token: CancelToken?
    private var workspace: TemporaryWorkspace?

    var canRun: Bool {
        header != nil && !password.isEmpty && !isRunning && memoryProblem == nil
    }

    /// Il file è leggibile, ma questo dispositivo non ha memoria per aprirlo ora.
    ///
    /// È un caso diverso da `headerProblem`, e va detto diversamente: lì il file
    /// non è un `.ecf` valido, qui lo è e il limite è del telefono.
    ///
    /// Soprattutto, **chi apre non ha scelto nulla**: i parametri di Argon2
    /// arrivano dall'header, li ha decisi chi ha cifrato, e non sono
    /// abbassabili — cambiarli cambierebbe la chiave derivata, cioè non
    /// aprirebbe il file, lo renderebbe illeggibile. Il messaggio non può
    /// quindi suggerire "scegli un profilo più leggero", che è il consiglio
    /// giusto in cifratura e inutile qui.
    var memoryProblem: String? {
        guard let header, !header.meta.fitsInAvailableMemory else { return nil }
        return L.t(
            "Opening this file needs %@ of memory, more than this device can give right now. The amount was set when the file was encrypted and cannot be lowered. Close other apps and try again.",
            SizeFormatter.string(header.meta.argon2MemoryBytes)
        )
    }

    /// L'estrazione ha senso solo se il payload è davvero un archivio.
    var offersExtraction: Bool { header?.summary.isTarContainer == true }

    // MARK: - Selezione

    /// Legge l'header del file scelto. Non deriva chiavi e non autentica:
    /// serve a mostrare cosa contiene prima di chiedere la password.
    func select(_ url: URL) async {
        discardWork()
        // Il file precedente può essere una copia lasciata dal sistema nel
        // nostro Inbox: ora che non lo si usa più, va rimossa. Non si tocca
        // quello corrente — l'utente può volerlo riprovare con un'altra password.
        if let previous = input, previous.url != url {
            FileAccess.discardIfInbox(previous.url)
        }
        input = Selection(url: url)
        header = nil
        headerProblem = nil
        // La password digitata per il file precedente non deve restare: sarebbe
        // pronta da inviare per un file diverso da quello per cui è stata scritta.
        password = ""

        do {
            let meta = try await FileAccess.withSecurityScope(url) { path in
                try await CrypteraEngine.shared.metadata(at: path)
            }
            let summary = describeHeader(meta: meta)
            header = Header(meta: meta, summary: summary)
            extractArchive = summary.isTarContainer
        } catch let error as CrypteraError {
            headerProblem = ErrorPresenter.message(for: error)
        } catch {
            headerProblem = ErrorPresenter.unexpected
        }
    }

    #if DEBUG
    /// Inietta un header senza passare da un file vero.
    ///
    /// Serve al preflight memoria: costruire un `.ecf` che chieda 64 GiB non è
    /// possibile — nessun profilo arriva lì — e con i profili reali il test
    /// direbbe soltanto ciò che il telefono su cui gira permette.
    func applyHeaderForTesting(_ meta: MetaInfo) {
        header = Header(meta: meta, summary: describeHeader(meta: meta))
    }
    #endif

    func selectKeyfile(_ url: URL) {
        keyfile = Selection(url: url)
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
        guard let input, header != nil else { return }

        // Un'esecuzione precedente può aver lasciato un output mai salvato: la
        // sua cartella va scartata **prima** di crearne un'altra, altrimenti
        // resterebbe orfana con dentro un file in chiaro fino al riavvio.
        discardWork()

        let workspace: TemporaryWorkspace
        do {
            workspace = try TemporaryWorkspace()
        } catch {
            errorMessage = ErrorPresenter.message(for: .IoError)
            return
        }
        self.workspace = workspace

        let extract = extractArchive && offersExtraction
        // Il nome definitivo si conosce solo **dopo** la decifratura, perché su
        // v5 il nome originale è cifrato nell'header. Si lavora su un segnaposto
        // e si rinomina alla fine.
        let fallbackName = input.url.deletingPathExtension().lastPathComponent
        let destination = extract
            ? workspace.path(named: fallbackName, fallback: "Decifrato")
            : workspace.payload

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
        let keyfileURL = keyfile?.url

        do {
            let meta = try await AuditLog.shared.measure(
                op: "decrypt",
                file: input.name
            ) {
                try await FileAccess.withSecurityScope(
                    input: inputURL,
                    keyfile: keyfileURL
                ) { inputPath, keyfilePath in
                try await CrypteraEngine.shared.decrypt(
                    DecryptRequest(
                        inputPath: inputPath,
                        outputPath: destination.path,
                        password: password,
                        keyfilePath: keyfilePath,
                        extractArchive: extract,
                        // L'archivio intermedio non interessa: l'utente ha
                        // chiesto il contenuto, non il TAR che lo conteneva.
                        keepArchive: false
                    ),
                    token: token,
                    onProgress: { [weak self] update in
                        // Il callback arriva da un thread Rust: hop sul main
                        // actor prima di toccare stato osservabile (SPEC §7).
                        Task { @MainActor in self?.progress = update }
                        }
                    )
                }
            }
            output = finalize(meta: meta, at: destination, extracted: extract, in: workspace)
        } catch let error as CrypteraError {
            discardWork()
            errorMessage = ErrorPresenter.message(for: error)
        } catch {
            discardWork()
            // Non `unexpected`: qui arriva anche il preflight memoria, che ha
            // un messaggio suo e sa dire quanta ne servirebbe. La schermata lo
            // mostra già alla scelta del file, ma la memoria disponibile può
            // essere calata nel frattempo.
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    /// C'è qualcosa da azzerare?
    var hasWorkInProgress: Bool {
        input != nil || keyfile != nil || !password.isEmpty
            || output != nil || errorMessage != nil || headerProblem != nil
    }

    /// Riporta la schermata allo stato iniziale.
    ///
    /// Scarta anche la copia in chiaro, che è la ragione principale per cui
    /// questo comando esiste: dopo aver finito, non si vuole lasciare in giro un
    /// file decifrato solo perché si è cambiato schermata.
    func reset() {
        discardWork()
        if let previous = input {
            FileAccess.discardIfInbox(previous.url)
        }
        input = nil
        header = nil
        headerProblem = nil
        keyfile = nil
        password = ""
        errorMessage = nil
        extractArchive = false
    }

    /// Da chiamare quando l'utente ha salvato o ha chiuso il risultato.
    ///
    /// L'output è **in chiaro**: appena non serve più va via dal disco.
    func discardWork() {
        workspace?.discard()
        workspace = nil
        output = nil
        progress = nil
    }

    // MARK: - Interni

    private func finalize(
        meta: MetaInfo,
        at destination: URL,
        extracted: Bool,
        in workspace: TemporaryWorkspace
    ) -> Output {
        guard extracted else {
            let fallback = input?.url.deletingPathExtension().lastPathComponent ?? "decifrato"
            let named = workspace.rename(destination, to: meta.filename, fallback: fallback)
            return Output(url: named, isDirectory: false)
        }

        // Un archivio creato da Cryptera contiene già una cartella di primo
        // livello col nome originale. Esportare la cartella di estrazione
        // consegnerebbe quindi una cartella dentro una cartella: se il contenuto
        // è uno solo, si consegna direttamente quello.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        )) ?? []
        let url = contents.count == 1 ? contents[0] : destination
        return Output(url: url, isDirectory: isDirectory(url))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
    }
}
