import Foundation

/// Una voce del registro operazioni.
///
/// Rispecchia `AuditEntry` di `src-tauri/src/audit.rs`, con **una differenza
/// deliberata**: si registra il *nome* del file, non il percorso completo.
///
/// Su iOS un percorso contiene identificatori del container e punti di mount dei
/// file provider: non dice niente a chi legge, e lascia un'impronta di dove
/// l'utente tiene le sue cose. È anche lo spirito di SPEC §12.3, che vieta i
/// percorsi nei log.
struct AuditEntry: Codable, Equatable, Identifiable {
    /// Unix timestamp in secondi (UTC), come nell'upstream.
    let ts: UInt64
    /// `encrypt` | `decrypt` | `verify` | `batch`
    let op: String
    /// Nome del file, senza percorso.
    let file: String
    let sizeMb: Double?
    let durationS: Double?
    /// `OK` oppure `ERR`.
    let status: String
    /// Il **codice** stabile dell'errore, mai il messaggio: i codici di SPEC
    /// §10.1 non cambiano e non sono localizzati, quindi un registro vecchio
    /// resta leggibile e confrontabile con quello del desktop.
    let error: String?

    var id: String { "\(ts)-\(op)-\(file)-\(status)" }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var succeeded: Bool { status == "OK" }

    enum CodingKeys: String, CodingKey {
        case ts, op, file, status, error
        case sizeMb = "size_mb"
        case durationS = "duration_s"
    }
}

/// Registro operazioni su file, in formato JSONL.
///
/// Port di `AuditLogger` dell'upstream: una riga JSON per operazione, in
/// aggiunta. Il formato riga-per-riga è scelto apposta — un file troncato resta
/// leggibile fino all'ultima riga intera, che è la proprietà che serve a un
/// registro.
///
/// **Data Protection `.complete`** (SPEC §11.3, e il piano lo chiede
/// esplicitamente per questo file): il registro non è leggibile né scrivibile a
/// dispositivo bloccato. È il livello giusto — dice quali file l'utente ha
/// aperto e quando — e non è un limite pratico, perché a dispositivo bloccato
/// non ci sono operazioni da registrare.
final class AuditLog: @unchecked Sendable {

    static let shared = AuditLog()

    /// Quante voci mostrare. L'upstream tiene 100 voci di storico volatile: qui
    /// il registro è uno solo e persistente, e 100 è il limite di lettura.
    static let displayLimit = 100

    private let queue = DispatchQueue(label: "com.cryptera.audit")
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        fileURL = base.appendingPathComponent("audit.jsonl")
    }

    /// La registrazione è attiva?
    ///
    /// L'upstream non ha un interruttore: registra sempre. Qui ce n'è uno, acceso
    /// di serie, perché un telefono si perde e un registro persistente di cosa
    /// si è cifrato è un dato sensibile a sé. Il comportamento predefinito resta
    /// quello del desktop.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.auditEnabled) as? Bool ?? true
    }

    // MARK: - Scrittura

    /// Registra un'operazione. Non solleva: un registro che fa fallire
    /// l'operazione che sta registrando sarebbe peggio del registro mancante.
    func record(
        op: String,
        file: String,
        bytes: UInt64?,
        duration: TimeInterval,
        errorCode: String?
    ) {
        guard isEnabled else { return }

        let entry = AuditEntry(
            ts: UInt64(Date().timeIntervalSince1970),
            op: op,
            // Anche qui: solo il nome, mai il percorso.
            file: (file as NSString).lastPathComponent,
            sizeMb: bytes.map { Double($0) / 1_000_000.0 },
            durationS: duration,
            status: errorCode == nil ? "OK" : "ERR",
            error: errorCode
        )
        append(entry)
    }

    /// Cronometra un'operazione e la registra, qualunque sia l'esito.
    ///
    /// `isolation: isolated (any Actor)? = #isolation` fa eseguire il corpo nel
    /// **dominio di isolamento del chiamante**. Senza, la closure dovrebbe
    /// essere `@Sendable` per attraversare il confine verso una funzione non
    /// isolata — e i modelli che la usano sono `@MainActor` e catturano stato
    /// che `Sendable` non è.
    @discardableResult
    func measure<T>(
        op: String,
        file: String,
        bytes: UInt64? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = Date()
        do {
            let result = try await body()
            record(op: op, file: file, bytes: bytes, duration: -start.timeIntervalSinceNow, errorCode: nil)
            return result
        } catch {
            record(
                op: op,
                file: file,
                bytes: bytes,
                duration: -start.timeIntervalSinceNow,
                errorCode: (error as? CrypteraError)?.auditCode ?? "UNKNOWN_ERROR"
            )
            throw error
        }
    }

    private func append(_ entry: AuditEntry) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(0x0A)  // newline: una voce per riga

            let manager = FileManager.default
            if manager.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? manager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // La protezione si applica alla **creazione**: impostarla dopo
                // lascerebbe una finestra in cui il file esiste senza.
                try? line.write(to: fileURL, options: [.completeFileProtection])
            }
        }
    }

    // MARK: - Lettura

    /// Voci più recenti, dalla più nuova. Le righe illeggibili si saltano: un
    /// registro parziale è più utile di nessun registro.
    func recent(limit: Int = AuditLog.displayLimit) -> [AuditEntry] {
        queue.sync {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            return content
                .split(separator: "\n")
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(AuditEntry.self, from: data)
                }
                .reversed()
                .prefix(limit)
                .map { $0 }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Il file protetto esiste? Usato dai test e dalla schermata.
    var hasEntries: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

// MARK: - Codici stabili

extension CrypteraError {
    /// Codice stabile di SPEC §10.1, per il registro.
    ///
    /// Sono le stesse stringhe del desktop e **non vanno rinominate**: un
    /// registro di sei mesi fa deve restare confrontabile. Non si usa il
    /// messaggio localizzato — cambierebbe con la lingua e con la revisione dei
    /// testi.
    ///
    /// La corrispondenza con Rust è verificata da `AuditLogTests`, che elenca i
    /// codici come li elenca la specifica.
    var auditCode: String {
        switch self {
        case .PasswordInvalid: return "PASSWORD_INVALID"
        case .HeaderAuthFailed: return "HEADER_AUTH_FAILED"
        case .HeaderInvalid: return "HEADER_INVALID"
        case .ParamsOutOfLimits: return "PARAMS_OUT_OF_LIMITS"
        case .Truncated: return "TRUNCATED"
        case .CorruptBeyondFec: return "CORRUPT_BEYOND_FEC"
        case .IoError: return "IO_ERROR"
        case .Cancelled: return "CANCELLED"
        case .UnknownError: return "UNKNOWN_ERROR"
        case .PasswordRequired: return "PASSWORD_REQUIRED"
        case .InputRequired: return "INPUT_REQUIRED"
        case .OutputRequired: return "OUTPUT_REQUIRED"
        case .OutputExists: return "OUTPUT_EXISTS"
        case .TarError: return "TAR_ERROR"
        case .ExtractError: return "EXTRACT_ERROR"
        case .AccessDenied: return "ACCESS_DENIED"
        case .InsufficientStorage: return "INSUFFICIENT_STORAGE"
        case .DeviceLocked: return "DEVICE_LOCKED"
        case .InsufficientMemory: return "INSUFFICIENT_MEMORY"
        case .Internal: return "INTERNAL"
        }
    }
}
