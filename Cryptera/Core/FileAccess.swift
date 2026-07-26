import Foundation

/// Accesso ai file fuori dal container dell'app (SPEC §6.1).
///
/// È la differenza concettuale principale rispetto al desktop: ogni URL che
/// arriva da un picker o dall'app File è **security-scoped**, il permesso va
/// aperto esplicitamente e va tenuto aperto per **tutta** la durata
/// dell'operazione. Chiuderlo prima produce `IO_ERROR` intermittenti sui file
/// grandi — il core Rust sta ancora leggendo — ed è l'errore che il piano
/// segnala come più costoso da diagnosticare, perché sembra casuale.
///
/// Per questo l'helper è **uno solo e non va duplicato**: ogni copia è
/// un'occasione di sbagliare la durata dello scope.
enum FileAccess {

    /// Esegue `body` con lo scope aperto su `url`, passandone il percorso.
    ///
    /// Il contratto è: `url` esiste già (è un input scelto dall'utente). Per gli
    /// output si scrive nella cartella di lavoro dell'app, che non ha bisogno di
    /// alcuno scope.
    static func withSecurityScope<T: Sendable>(
        _ url: URL,
        _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        let opened = url.startAccessingSecurityScopedResource()
        defer {
            // `stop` va chiamata **solo** se `start` è riuscita. Le due funzioni
            // mantengono un contatore per URL: uno `stop` spaiato lo porta sotto
            // zero e può revocare l'accesso a un'operazione ancora in corso
            // sullo stesso file.
            if opened { url.stopAccessingSecurityScopedResource() }
        }

        if !opened && !isAccessibleWithoutScope(url) {
            throw CrypteraError.AccessDenied
        }

        return try await body(url.path)
    }

    /// Esegue `body` con lo scope aperto su input e keyfile insieme.
    ///
    /// Il keyfile è un secondo URL del picker, con un suo scope indipendente:
    /// serve annidare. Sta qui e non nelle schermate perché Decrypt e Verify ne
    /// hanno entrambe bisogno, e la nidificazione scritta due volte è
    /// esattamente il tipo di duplicazione che §6.1 vieta.
    static func withSecurityScope<T: Sendable>(
        input: URL,
        keyfile: URL?,
        _ body: @Sendable (_ inputPath: String, _ keyfilePath: String?) async throws -> T
    ) async throws -> T {
        try await withSecurityScope(input) { inputPath in
            guard let keyfile else {
                return try await body(inputPath, nil)
            }
            return try await withSecurityScope(keyfile) { keyfilePath in
                try await body(inputPath, keyfilePath)
            }
        }
    }

    /// Rimuove la copia che il sistema lascia in `Documents/Inbox/`.
    ///
    /// Con `LSSupportsOpeningDocumentsInPlace` l'app File apre il `.ecf` dove si
    /// trova, senza copiarlo. Altre sorgenti — allegati di Mail, AirDrop — lo
    /// copiano invece nel nostro `Documents/Inbox/`, e **quella copia è nostra**:
    /// il sistema non la rimuove mai. Senza questa pulizia si accumulerebbero
    /// file cifrati invisibili all'utente ma conteggiati nello spazio dell'app.
    ///
    /// Rimuove solo dentro il nostro Inbox: un URL scelto dall'utente altrove
    /// non viene toccato.
    static func discardIfInbox(_ url: URL) {
        guard let inbox = inboxDirectory else { return }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(inbox.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Interni

    /// L'URL è raggiungibile senza aprire alcuno scope?
    ///
    /// `startAccessingSecurityScopedResource()` torna `false` in due casi
    /// **opposti**: permesso negato, e URL che non ha bisogno di alcun permesso
    /// (bundle dell'app, cartella temporanea, container). Lo snippet di SPEC
    /// §6.1 li tratta allo stesso modo e solleva `accessDenied` in entrambi —
    /// il che farebbe fallire proprio i percorsi interni all'app: la cartella di
    /// lavoro dove finisce l'output di M4 e le fixture del bundle da cui partono
    /// i UI test.
    ///
    /// I due discriminanti sono complementari: la posizione copre anche i
    /// percorsi non ancora esistenti, la leggibilità copre le cartelle concesse
    /// che stanno fuori dal container (fuori dalla sandbox e senza scope attivo
    /// l'accesso è negato, quindi `isReadableFile` è falsa).
    /// Non è `private` per essere verificabile direttamente: sul simulatore
    /// `startAccessingSecurityScopedResource()` riesce anche su URL arbitrari,
    /// quindi il ramo di rifiuto di `withSecurityScope` non è raggiungibile da
    /// lì e un test end-to-end dell'`AccessDenied` non proverebbe nulla.
    static func isAccessibleWithoutScope(_ url: URL) -> Bool {
        isInsideAppSandbox(url) || FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func isInsideAppSandbox(_ url: URL) -> Bool {
        // Il bundle non sta dentro la home del container: su simulatore e su
        // device sono due alberi distinti, quindi vanno controllati entrambi.
        let path = canonicalPath(url)
        return [URL(fileURLWithPath: NSHomeDirectory()), Bundle.main.bundleURL]
            .contains { path.hasPrefix(canonicalPath($0) + "/") }
    }

    /// Percorso confrontabile per prefisso, con `/private` sempre tolto.
    ///
    /// Serve perché **le normalizzazioni di Foundation non sono uniformi**:
    /// `resolvingSymlinksInPath()` toglie il prefisso `/private` soltanto se il
    /// percorso corrisponde a un file **esistente**. Misurato su iPhone:
    ///
    ///     tmp/                → /var/mobile/.../tmp          (esiste: tolto)
    ///     tmp/non-ancora.bin  → /private/var/mobile/.../tmp/…  (non esiste: resta)
    ///
    /// Il confronto per prefisso falliva quindi esattamente sui percorsi non
    /// ancora creati — cioè su ogni percorso di **output** — e si ricadeva su
    /// `isReadableFile`, che per un file inesistente è falso: un percorso dentro
    /// il container veniva giudicato fuori.
    ///
    /// Sul simulatore non succede, perché lì i container non stanno sotto
    /// `/private`: il difetto è emerso solo eseguendo la suite su un device.
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let privatePrefix = "/private/"
        guard path.hasPrefix(privatePrefix) else { return path }
        return String(path.dropFirst(privatePrefix.count - 1))
    }

    private static var inboxDirectory: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }
}
