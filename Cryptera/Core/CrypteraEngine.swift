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
        // I binding generati sono compilati dentro il modulo dell'app, e questi
        // metodi ne oscurano i nomi: Swift preferisce il metodo di istanza
        // anche con etichette diverse, quindi serve qualificare col modulo.
        return try await run(
            { listener in
                try Cryptera.verify(request: request, listener: listener, token: token)
            },
            onProgress: onProgress
        )
    }

    public func decrypt(
        _ request: DecryptRequest,
        token: CancelToken? = nil,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> MetaInfo {
        configureIfNeeded()
        return try await run(
            { listener in
                try Cryptera.decrypt(request: request, listener: listener, token: token)
            },
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
            onProgress: onProgress
        )
    }

    // MARK: - Esecuzione

    private func run(
        _ body: @escaping @Sendable (ProgressListener?) throws -> MetaInfo,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> MetaInfo {
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

extension SecurityProfile {
    /// Il profilo è eseguibile con la memoria attualmente disponibile?
    ///
    /// Argon2 alloca un blocco contiguo; su iOS superare il limite jetsam
    /// **termina il processo senza eccezione catturabile** — dal punto di vista
    /// dell'utente l'app sparisce (SPEC §11.2). Meglio un errore esplicito.
    ///
    /// Soglia prudenziale al 50% del disponibile, come suggerito dalla spec.
    ///
    /// I parametri **non vanno mai abbassati silenziosamente**: cambiare
    /// `argon2_mem` cambia la chiave derivata, quindi produrrebbe un file
    /// diverso da quello richiesto.
    public var fitsInAvailableMemory: Bool {
        let required = securityProfileMemoryBytes(profile: self)
        let available = UInt64(os_proc_available_memory())
        guard available > 0 else { return true }  // stima non disponibile: non bloccare
        return required <= available / 2
    }
}
