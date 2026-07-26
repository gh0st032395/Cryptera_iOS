import Foundation

// MARK: - Progress

/// Fase corrente di un'operazione.
///
/// Il core emette gli stage come stringhe libere; qui diventano un enum
/// tipizzato (SPEC §5.3) perché le stringhe grezze non vanno mai mostrate
/// all'utente — sono diagnostiche e non localizzate.
public enum OperationStage: Sendable, Equatable {
    case archiving
    case encrypting
    case decrypting
    case verifying
    /// Stage non riconosciuto: un core più recente potrebbe emetterne di nuovi.
    /// Non è un errore, e non va mostrato grezzo.
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "archiving": self = .archiving
        case "encrypt": self = .encrypting
        case "decrypt": self = .decrypting
        case "verify": self = .verifying
        default: self = .unknown(raw)
        }
    }
}

public struct OperationProgress: Sendable, Equatable {
    public let stage: OperationStage
    public let done: UInt64
    public let total: UInt64

    /// `nil` quando il totale non è noto: la UI deve mostrare una barra
    /// indeterminata invece di fingere una percentuale.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(done) / Double(total))
    }
}

/// Adatta il callback UniFFI, invocato da un thread Rust, a una closure Swift.
///
/// Il throttling (~10 aggiornamenti/s) è già applicato nel crate FFI, dove costa
/// meno: ogni notifica è un attraversamento del confine, e filtrarle lì evita di
/// pagarne il costo per poi scartarle.
private final class ProgressBridge: ProgressListener, @unchecked Sendable {
    private let handler: @Sendable (OperationProgress) -> Void

    init(_ handler: @escaping @Sendable (OperationProgress) -> Void) {
        self.handler = handler
    }

    func onProgress(stage: String, done: UInt64, total: UInt64) {
        handler(
            OperationProgress(stage: OperationStage(raw: stage), done: done, total: total)
        )
    }
}

// MARK: - Engine

/// Unico punto di contatto con i binding UniFFI (SPEC §7).
///
/// Le chiamate UniFFI sono **sincrone e bloccanti**: vengono eseguite su una
/// coda dedicata con QoS `.userInitiated`, mai sul main actor e mai sul pool
/// cooperativo di Swift Concurrency, che bloccare significherebbe affamare.
///
/// `.userInitiated` e non `.userInteractive` è deliberato: saturare i core di un
/// iPhone porta a throttling termico in pochi minuti (SPEC §11.5).
public actor CrypteraEngine {
    public static let shared = CrypteraEngine()

    private let queue = DispatchQueue(
        label: "com.cryptera.engine",
        qos: .userInitiated
    )

    private var threadPoolConfigured = false

    public init() {}

    /// Limita il pool di rayon. Idempotente; ha effetto solo alla prima chiamata
    /// perché il pool globale si inizializza una volta sola.
    public func configureIfNeeded() {
        guard !threadPoolConfigured else { return }
        threadPoolConfigured = true
        let cores = ProcessInfo.processInfo.activeProcessorCount
        configureThreadPool(maxThreads: UInt32(min(cores, 4)))
    }

    public func version() -> String {
        coreVersion()
    }

    /// Legge l'header senza password. Non deriva chiavi, non autentica.
    public func metadata(at path: String) throws -> MetaInfo {
        try readMetadata(path: path)
    }

    public func verify(
        _ request: VerifyRequest,
        token: CancelToken? = nil,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> MetaInfo {
        configureIfNeeded()
        try preflightMemory(forFileAt: request.inputPath)
        // I binding generati sono compilati dentro il modulo dell'app, e questi
        // metodi ne oscurano i nomi: Swift preferisce il metodo di istanza
        // anche con etichette diverse, quindi serve qualificare col modulo.
        return try await run(
            { listener in
                try Cryptera.verify(request: request, listener: listener, token: token)
            },
            token: token,
            onProgress: onProgress
        )
    }

    public func decrypt(
        _ request: DecryptRequest,
        token: CancelToken? = nil,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> MetaInfo {
        configureIfNeeded()
        try preflightMemory(forFileAt: request.inputPath)
        return try await run(
            { listener in
                try Cryptera.decrypt(request: request, listener: listener, token: token)
            },
            token: token,
            onProgress: onProgress
        )
    }

    public func encrypt(
        _ request: EncryptRequest,
        token: CancelToken? = nil,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> MetaInfo {
        configureIfNeeded()
        return try await run(
            { listener in
                try Cryptera.encrypt(request: request, listener: listener, token: token)
            },
            token: token,
            onProgress: onProgress
        )
    }

    // MARK: - Preflight

    /// Rifiuta prima di derivare la chiave, se i parametri del file non ci stanno.
    ///
    /// Sta nel motore e non nelle schermate perché **Verify e Batch non leggono
    /// l'header prima di partire**: guardando solo la schermata Decrypt, il
    /// processo resterebbe uccidibile dalle altre due strade, e il difetto si
    /// manifesterebbe come "l'app sparisce" senza alcun messaggio.
    ///
    /// Leggere l'header costa un'apertura di file e nessuna derivazione: è
    /// l'operazione che la schermata Decrypt fa già alla scelta del file.
    private func preflightMemory(forFileAt path: String) throws {
        // Se l'header non è leggibile **non si decide qui**: l'errore vero —
        // file corrotto, troncato, non un `.ecf` — lo produce l'operazione, ed
        // è più preciso di qualunque cosa si possa dire adesso.
        guard let meta = try? readMetadata(path: path) else { return }
        guard !meta.fitsInAvailableMemory else { return }
        throw InsufficientMemory(requiredBytes: meta.argon2MemoryBytes)
    }

    // MARK: - Esecuzione

    private func run(
        _ body: @escaping @Sendable (ProgressListener?) throws -> MetaInfo,
        token: CancelToken?,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> MetaInfo {
        // Schermo sveglio e background task per tutta la durata (SPEC §11.1).
        // Sta qui e non nelle schermate perché `run` è il punto in cui passano
        // *tutte* le operazioni: messo più in alto andrebbe scritto tre volte,
        // e la copia dimenticata sarebbe quella che lascia il telefono a
        // bloccarsi a metà cifratura.
        await OperationLifetime.shared.begin(token: token)
        defer {
            // Non `await`: il defer è sincrono. Il rilascio è comunque
            // garantito — questo blocco viene eseguito anche su errore e su
            // cancellazione, che è il caso in cui contava di più.
            Task { @MainActor in OperationLifetime.shared.end(token: token) }
        }

        let listener = onProgress.map(ProgressBridge.init)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body(listener))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Preflight memoria

/// Il dispositivo non ha memoria per i parametri Argon2 di questo file.
///
/// Non è un `CrypteraError`: il core non c'entra e non è mai stato chiamato.
/// Aggiungerne un caso all'enum FFI significherebbe toccare il confine con
/// Rust — e quindi il desktop — per una condizione che esiste solo su iOS.
public struct InsufficientMemory: Error {
    /// Quanta ne serviva, per poterlo dire all'utente invece di un generico
    /// "memoria insufficiente" che non aiuta a decidere cosa chiudere.
    public let requiredBytes: UInt64
}

/// Regola unica: quanta memoria di Argon2 questo dispositivo può concedere ora.
///
/// Argon2 alloca un blocco contiguo; su iOS superare il limite jetsam
/// **termina il processo senza eccezione catturabile** — dal punto di vista
/// dell'utente l'app sparisce (SPEC §11.2). Meglio un errore esplicito.
///
/// I parametri **non vanno mai abbassati silenziosamente**: cambiare
/// `argon2_mem` cambia la chiave derivata. In cifratura produrrebbe un file
/// diverso da quello richiesto; in decifratura non produrrebbe proprio nulla,
/// perché i parametri arrivano dall'header e non sono negoziabili.
///
/// Sta in un tipo suo e non su `SecurityProfile` perché la domanda si pone in
/// due forme: da un profilo scelto dall'utente (cifratura) e da un numero letto
/// nell'header (decifratura). Con la regola scritta su un solo lato, l'altro
/// finirebbe per riscriverla con una soglia diversa.
public enum MemoryPreflight {
    /// Frazione del disponibile oltre la quale non ci si spinge.
    /// Soglia prudenziale al 50%, come suggerito dalla spec.
    private static let maxShare: UInt64 = 2

    /// Memoria concedibile al processo, o `nil` se il sistema non sa dirlo —
    /// il caso del simulatore, dove `os_proc_available_memory()` risponde 0.
    public static var availableBytes: UInt64? {
        let available = UInt64(os_proc_available_memory())
        return available > 0 ? available : nil
    }

    /// Senza una stima **non si blocca**: rifiutare tutto dove il sistema non
    /// risponde renderebbe l'app inutilizzabile proprio lì.
    public static func fits(_ requiredBytes: UInt64) -> Bool {
        guard let available = availableBytes else { return true }
        return requiredBytes <= available / maxShare
    }
}

extension SecurityProfile {
    /// Il profilo è eseguibile con la memoria attualmente disponibile?
    public var fitsInAvailableMemory: Bool {
        MemoryPreflight.fits(securityProfileMemoryBytes(profile: self))
    }
}

extension MetaInfo {
    /// Memoria che Argon2 richiederà per **questo file**, dai parametri scritti
    /// nel suo header.
    public var argon2MemoryBytes: UInt64 {
        UInt64(argon2MemKib) * 1024
    }

    /// Il file è apribile con la memoria attualmente disponibile?
    ///
    /// A differenza della cifratura, qui non c'è nulla da scegliere: chi apre
    /// il file subisce i parametri di chi l'ha creato. Il rifiuto va quindi
    /// spiegato in quei termini, non come "scegli un profilo più leggero".
    public var fitsInAvailableMemory: Bool {
        MemoryPreflight.fits(argon2MemoryBytes)
    }
}
