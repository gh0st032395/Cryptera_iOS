import Foundation

/// Verifica dello spazio **prima** di iniziare (SPEC §11.4).
///
/// Cifrare una cartella nel caso peggiore richiede circa il doppio della
/// sorgente — l'archivio TAR intermedio più l'output — a cui si aggiunge
/// l'overhead di parità, che con il profilo massimo arriva al 300%. Un totale
/// di **oltre quattro volte** la cartella di partenza.
///
/// Scoprirlo a metà operazione significa aver già speso minuti di CPU e aver
/// riempito il disco. Meglio rifiutare subito con un errore che dice cosa
/// serve.
enum StorageCheck {

    /// Spazio necessario, stimato per eccesso.
    ///
    /// - `needsArchive`: le cartelle passano da un TAR temporaneo, i file no.
    /// - `parityOverheadPercent`: viene da Rust, che è l'unica fonte dei
    ///   parametri dei profili.
    ///
    /// È volutamente una **sovrastima**: ignora la compressione, il cui effetto
    /// dipende dal contenuto e non è prevedibile. Un preflight che sbaglia per
    /// eccesso rifiuta qualche caso che sarebbe passato; uno che sbaglia per
    /// difetto lascia l'utente a metà strada con il disco pieno.
    static func requiredBytes(
        source: UInt64,
        parityOverheadPercent: UInt32,
        needsArchive: Bool
    ) -> UInt64 {
        let output = Double(source) * (1.0 + Double(parityOverheadPercent) / 100.0)
        let archive = needsArchive ? Double(source) : 0
        // Un margine fisso per header, trailer e blocchi parziali: su file
        // piccoli l'overhead relativo del formato non è trascurabile.
        let slack: Double = 4 * 1024 * 1024
        let total = (output + archive + slack).rounded(.up)
        // Satura invece di andare in trap: la dimensione può venire da un
        // filesystem che riporta valori assurdi, e un preflight non deve essere
        // il punto in cui l'app termina. Un valore saturato viene comunque
        // rifiutato dal confronto con lo spazio disponibile, che è l'esito
        // giusto.
        return total >= Double(UInt64.max) ? .max : UInt64(total)
    }

    /// Spazio disponibile sul volume che ospita `url`.
    ///
    /// `volumeAvailableCapacityForImportantUsage` e non la capacità grezza: è
    /// il valore che tiene conto di quanto iOS è disposto a liberare
    /// cancellando contenuti eliminabili, cioè quello che l'app può davvero
    /// usare per dati che non deve perdere.
    ///
    /// `nil` quando il sistema non lo espone: in quel caso non si blocca nulla,
    /// perché rifiutare per un dato mancante sarebbe peggio che provarci.
    static func availableBytes(for url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity > 0 ? UInt64(capacity) : 0
    }

    /// Lo spazio basta per l'operazione descritta?
    static func hasRoom(
        forSource source: UInt64,
        parityOverheadPercent: UInt32,
        needsArchive: Bool,
        on volume: URL
    ) -> Bool {
        guard let available = availableBytes(for: volume) else { return true }
        return requiredBytes(
            source: source,
            parityOverheadPercent: parityOverheadPercent,
            needsArchive: needsArchive
        ) <= available
    }

    /// Dimensione e numero di file di una cartella.
    ///
    /// Va chiamata con lo scope di sicurezza aperto, e **fuori dal main actor**:
    /// su una cartella grande l'attraversamento non è istantaneo.
    ///
    /// I file illeggibili non interrompono il conteggio — l'utente ha concesso
    /// la cartella, non necessariamente ogni cosa dentro — ma la loro dimensione
    /// manca dal totale, che resta quindi una stima.
    static func measureFolder(at url: URL) -> (bytes: UInt64, files: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [] // niente skipsHiddenFiles: il TAR li includerà comunque
        ) else {
            return (0, 0)
        }

        var bytes: UInt64 = 0
        var files = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += UInt64(values.fileSize ?? 0)
        }
        return (bytes, files)
    }
}
