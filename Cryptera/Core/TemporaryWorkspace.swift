import Foundation

/// Cartella di lavoro per l'output di un'operazione, prima che l'utente scelga
/// dove salvarlo (SPEC §6.3, strategia A).
///
/// Su iOS non si può scrivere accanto all'input: si produce l'output nel
/// container e lo si consegna al sistema con un picker. Il contenuto è **in
/// chiaro**, quindi la cartella deve vivere il minimo indispensabile — viene
/// rimossa appena l'utente ha salvato, ha annullato, o ha cambiato file.
///
/// La strategia B di §6.3 (scrittura diretta in una cartella già autorizzata,
/// con bookmark persistente §6.4) non è di M4: è lì che diventa necessario il
/// controllo di collisione dei nomi, perché qui la destinazione la sceglie il
/// sistema e non sovrascrive mai in silenzio.
final class TemporaryWorkspace {

    /// Radice comune sotto `temporaryDirectory`.
    ///
    /// Serve a poter ripulire i residui di sessioni precedenti senza toccare il
    /// resto della cartella temporanea, che il sistema usa anche per altro.
    private static let rootName = "cryptera-work"

    let directory: URL

    /// Classe di Data Protection della cartella di lavoro (SPEC §11.3).
    ///
    /// `.completeUnlessOpen` e non `.complete`: il contenuto è in chiaro e va
    /// protetto a dispositivo bloccato, ma un'operazione lunga può essere in
    /// corso proprio mentre lo schermo si spegne — con `.complete` la scrittura
    /// già aperta fallirebbe a metà. Questa classe cifra il file a riposo e
    /// lascia proseguire chi lo aveva già aperto.
    ///
    /// Non `.none` da nessuna parte, per nessun file.
    static let protection: FileProtectionType = .completeUnlessOpen

    init() throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // La protezione si mette sulla **cartella**, non sui file.
        //
        // L'output lo crea il codice Rust attraverso `std::fs`, che di iOS non
        // sa nulla e non può chiedere una classe di protezione. Impostarla dopo
        // — a operazione conclusa — lascerebbe scoperto tutto il tempo in cui il
        // file in chiaro esiste, che è esattamente la finestra da chiudere. I
        // file creati dentro una cartella ereditano la sua classe, quindi
        // metterla qui la applica anche a ciò che scrive Rust.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection]
        )
    }

    /// Percorso di lavoro per l'output dell'operazione.
    ///
    /// Il nome è un segnaposto: quello definitivo si conosce **solo dopo** la
    /// decifratura, perché su header v5 il nome originale è cifrato dentro
    /// l'header e resta illeggibile finché non si fornisce la password.
    var payload: URL {
        directory.appendingPathComponent("payload", isDirectory: false)
    }

    /// Percorso dentro la cartella di lavoro, con il nome sanificato.
    ///
    /// `name` può venire dall'header del file cifrato, quindi è **scelto da chi
    /// ha creato il file** e il core non lo sanifica (valida solo UTF-8 e
    /// lunghezza). La sanificazione è quella di Rust (`safeOutputName`):
    /// riscriverla qui la farebbe divergere, e `URL.appendingPathComponent` non
    /// neutralizza né le risalite né i percorsi assoluti.
    func path(named name: String, fallback: String) -> URL {
        directory.appendingPathComponent(
            safeOutputName(storedName: name, fallback: fallback),
            isDirectory: false
        )
    }

    /// Rinomina l'output col nome che il file aveva prima di essere cifrato.
    func rename(_ url: URL, to storedName: String, fallback: String) -> URL {
        let destination = path(named: storedName, fallback: fallback)
        guard destination != url else { return url }
        // La cartella è appena stata creata per questa sola operazione: una
        // collisione qui non è possibile, e se lo fosse il file di lavoro resta
        // comunque esportabile col nome segnaposto.
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Rimuove i residui delle sessioni precedenti.
    ///
    /// Va chiamata **all'avvio**, prima che esista una cartella di lavoro: se
    /// l'app viene terminata durante un'operazione — o sospesa e uccisa dal
    /// sistema, che su iOS è la norma — il file decifrato resterebbe altrimenti
    /// su disco a tempo indeterminato.
    static func purgeStale() {
        try? FileManager.default.removeItem(at: root)
    }

    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(rootName, isDirectory: true)
    }
}
