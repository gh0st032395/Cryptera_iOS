import Foundation

/// Lingua dell'interfaccia.
///
/// Il desktop offre uno scambio di lingua dentro l'app (`ui/modules/i18n.js`) e
/// SPEC §8.1 lo elenca fra le impostazioni: non basta seguire la lingua del
/// dispositivo.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case italian

    var id: String { rawValue }

    /// In inglese perché è la lingua sorgente; l'italiano lo traduce.
    var label: String {
        switch self {
        case .system: return L.t("System")
        case .english: return "English"
        case .italian: return "Italiano"
        }
    }
}

/// Ricerca delle stringhe localizzate.
///
/// **L'inglese è la chiave.** Non ci sono identificatori tipo `nav_encrypt`: la
/// stringa inglese *è* l'identificatore, e `it.lproj/Localizable.strings` è
/// l'unico file da mantenere. Una chiave senza traduzione ricade sull'inglese
/// da sola, invece di mostrare un identificatore all'utente — che è il modo in
/// cui le localizzazioni a chiavi simboliche si rompono in produzione.
///
/// > Deviazione dal piano, deliberata. `IMPLEMENTATION_PLAN.md` prevedeva di
/// > conservare le chiavi dell'upstream per poter confrontare le due
/// > interfacce. Ma le stringhe di iOS non corrispondono più a quelle del
/// > desktop — le schermate sono altre — quindi il confronto sarebbe stato
/// > formale e non reale. Dove la corrispondenza esiste davvero, cioè sui
/// > messaggi d'errore, la chiave dell'upstream resta annotata accanto al caso
/// > in `ErrorPresenter`.
///
/// Non si usa `Text("literal")` di SwiftUI: risolve sempre attraverso la lingua
/// **di sistema** e ignorerebbe la scelta fatta nelle impostazioni.
enum L {

    /// Chiave in `UserDefaults`, condivisa con l'`@AppStorage` delle
    /// impostazioni. Le due devono restare allineate.
    static let languageKey = "appLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func t(_ key: String) -> String {
        switch current {
        case .english:
            // La chiave è già l'inglese: nessuna ricerca da fare.
            return key
        case .italian:
            return bundle(for: "it")?
                .localizedString(forKey: key, value: key, table: nil) ?? key
        case .system:
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
    }

    /// Interpolazione con segnaposto posizionali (`%@`, `%d`).
    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    private static func bundle(for code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
