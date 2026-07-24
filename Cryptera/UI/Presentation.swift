import Foundation

extension OperationStage {
    /// Etichetta mostrabile della fase corrente.
    ///
    /// Le stringhe che il core emette come stage sono diagnostiche e non
    /// localizzate: non raggiungono mai la UI (SPEC §10.3). Uno stage
    /// sconosciuto — un core più recente potrebbe introdurne — resta generico
    /// invece di mostrare l'identificatore grezzo.
    var displayName: String {
        switch self {
        case .archiving: return "Creazione archivio"
        case .encrypting: return "Cifratura"
        case .decrypting: return "Decifratura"
        case .verifying: return "Verifica"
        case .unknown: return "Operazione in corso"
        }
    }
}

enum SizeFormatter {
    /// Dimensione leggibile.
    ///
    /// I campi dell'header sono `u64` e provengono da un file non fidato:
    /// `Int64` viene saturato invece di andare in overflow su un valore assurdo.
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }
}
