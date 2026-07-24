import Foundation

/// Decifratura in blocco (SPEC §8.3, riferimento `ui/modules/batch.js`).
///
/// Password unica, esecuzione **sequenziale**, stato per ogni file. Sequenziale
/// e non parallela per una ragione precisa: ogni file deriva la propria chiave
/// con Argon2, che alloca fino a 512 MiB. Due derivazioni insieme
/// raddoppierebbero il picco e su iOS il superamento del limite jetsam non è
/// un'eccezione, è la morte del processo (SPEC §11.2).
///
/// **Il difetto della 2.0.3 non va riportato.** Il piano segnala che quella
/// versione trattava ogni file come un container TAR, fallendo con
/// `EXTRACT_ERROR` oppure `OUTPUT_EXISTS` sui `.ecf` singoli, e che la 2.0.4 lo
/// corregge ispezionando l'header di ciascun file. Da noi quella distinzione è
/// **già dentro `decrypt`** dal M4: il crate controlla `FLAG_TAR_CONTAINER` e
/// sceglie da sé se estrarre o spostare. Riscriverla qui sarebbe una seconda
/// copia della stessa decisione, libera di divergere.
@MainActor
@Observable
final class BatchModel {

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case pending
            case running
            case done
            case failed(String)
        }

        let url: URL
        var state: State = .pending
        /// Risultato prodotto, quando l'operazione è riuscita.
        var output: URL?

        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    struct Summary: Equatable {
        let succeeded: Int
        let failed: Int
        let duration: TimeInterval
    }

    private(set) var items: [Item] = []
    var password = ""
    private(set) var keyfile: URL?

    private(set) var isRunning = false
    private(set) var currentIndex: Int?
    private(set) var summary: Summary?
    private(set) var outputFolder: URL?

    private var token: CancelToken?
    private var workspace: TemporaryWorkspace?

    var canRun: Bool { !items.isEmpty && !password.isEmpty && !isRunning }

    var hasWorkInProgress: Bool { !items.isEmpty || !password.isEmpty || summary != nil }

    /// Avanzamento complessivo: quanti file sono stati affrontati.
    var progressFraction: Double? {
        guard isRunning, !items.isEmpty, let currentIndex else { return nil }
        return Double(currentIndex) / Double(items.count)
    }

    // MARK: - Coda

    /// Aggiunge file alla coda, saltando i doppioni.
    ///
    /// Non si filtra per estensione come fa l'upstream: il selettore accetta già
    /// solo il tipo `com.cryptera.ecf`, e un file che non lo è produrrebbe
    /// comunque un errore leggibile sulla sua riga invece di sparire in
    /// silenzio prima di arrivare in coda.
    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        items.append(contentsOf: urls.filter { !known.contains($0) }.map { Item(url: $0) })
        summary = nil
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        summary = nil
    }

    func selectKeyfile(_ url: URL) {
        keyfile = url
    }

    func clearKeyfile() {
        keyfile = nil
    }

    func cancel() {
        token?.cancel()
    }

    /// Riporta la schermata allo stato iniziale, scartando i file decifrati.
    func reset() {
        discardWork()
        items.removeAll()
        password = ""
        keyfile = nil
        summary = nil
    }

    func discardWork() {
        workspace?.discard()
        workspace = nil
        outputFolder = nil
        for index in items.indices {
            items[index].state = .pending
            items[index].output = nil
        }
    }

    // MARK: - Esecuzione

    func run() async {
        guard canRun else { return }

        discardWork()
        let workspace: TemporaryWorkspace
        do {
            workspace = try TemporaryWorkspace()
        } catch {
            summary = Summary(succeeded: 0, failed: items.count, duration: 0)
            return
        }
        self.workspace = workspace

        // Tutti i risultati in **una** cartella, esportata una volta sola alla
        // fine. Su iOS ogni salvataggio passa da un selettore di sistema:
        // presentarne uno per file trasformerebbe un batch di venti file in
        // venti interruzioni.
        let destination = workspace.directory.appendingPathComponent("Cryptera", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let token = CancelToken()
        self.token = token
        isRunning = true
        summary = nil
        let start = Date()
        var succeeded = 0
        var failed = 0
        defer {
            isRunning = false
            currentIndex = nil
            self.token = nil
        }

        let password = password
        let keyfileURL = keyfile

        for index in items.indices {
            if token.isCancelled() { break }

            currentIndex = index
            items[index].state = .running
            let item = items[index]

            do {
                let output = try await decryptOne(
                    item.url,
                    into: destination,
                    password: password,
                    keyfile: keyfileURL,
                    token: token
                )
                items[index].state = .done
                items[index].output = output
                succeeded += 1
            } catch let error as CrypteraError {
                items[index].state = .failed(ErrorPresenter.message(for: error))
                failed += 1
                if case .Cancelled = error { break }
            } catch {
                items[index].state = .failed(ErrorPresenter.unexpected)
                failed += 1
            }
        }

        outputFolder = succeeded > 0 ? destination : nil
        summary = Summary(succeeded: succeeded, failed: failed, duration: -start.timeIntervalSinceNow)

        // La password non serve più (SPEC §12.1). Come sul desktop, non si
        // azzera se l'operazione è stata interrotta: si vorrà riprovare.
        if !token.isCancelled() { self.password = "" }
    }

    private func decryptOne(
        _ url: URL,
        into destination: URL,
        password: String,
        keyfile: URL?,
        token: CancelToken
    ) async throws -> URL {
        // Nome di lavoro: quello del `.ecf` senza estensione. Il nome vero
        // arriva dall'header e si applica dopo, quando è noto.
        let fallback = url.deletingPathExtension().lastPathComponent
        // `let` e non `var`: la closure che attraversa il confine FFI lo cattura,
        // e una variabile mutabile non può essere catturata da codice
        // concorrente. Due `.ecf` con lo stesso nome nella stessa coda non
        // devono comunque sovrascriversi (SPEC §6.3).
        let target = Self.uniqueURL(destination.appendingPathComponent(fallback))

        let meta = try await AuditLog.shared.measure(
            op: "batch",
            file: url.lastPathComponent,
            bytes: Self.fileSize(of: url)
        ) {
            try await FileAccess.withSecurityScope(input: url, keyfile: keyfile) { inputPath, keyfilePath in
                try await CrypteraEngine.shared.decrypt(
                    DecryptRequest(
                        inputPath: inputPath,
                        outputPath: target.path,
                        password: password,
                        keyfilePath: keyfilePath,
                        // `decrypt` distingue da sé container e file singolo:
                        // con un container estrae, altrimenti sposta il payload.
                        extractArchive: true,
                        keepArchive: false
                    ),
                    token: token
                )
            }
        }

        // Il nome originale si conosce solo ora: su v5 è cifrato nell'header.
        // Passa dalla sanificazione di Rust, come in Decrypt — è un dato scelto
        // da chi ha creato il file.
        guard !meta.filename.isEmpty else { return target }
        let safeName = safeOutputName(storedName: meta.filename, fallback: fallback)
        let desired = destination.appendingPathComponent(safeName)
        // Se il nome definitivo è già quello di lavoro non c'è niente da fare:
        // passarlo comunque da `uniqueURL` troverebbe occupato **il file
        // stesso** e lo rinominerebbe in "nome 2".
        guard desired != target else { return target }
        let renamed = Self.uniqueURL(desired)
        guard (try? FileManager.default.moveItem(at: target, to: renamed)) != nil else {
            return target
        }
        return renamed
    }

    /// Aggiunge un suffisso finché il nome è libero.
    private static func uniqueURL(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for suffix in 2...999 {
            let candidate = directory
                .appendingPathComponent(ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private static func fileSize(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }
}
