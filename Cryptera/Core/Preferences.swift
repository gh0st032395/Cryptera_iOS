import SwiftUI

/// Aspetto dell'interfaccia (SPEC §8.4).
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L.t("System")
        case .light: return L.t("Light")
        case .dark: return L.t("Dark")
        }
    }

    /// `nil` lascia decidere il sistema.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Chiavi di `UserDefaults` usate dall'app.
///
/// Raccolte qui perché sono lette in due modi — con `@AppStorage` nelle viste e
/// direttamente altrove — e due letterali scritti a mano che divergono
/// producono un'impostazione che sembra non salvarsi.
enum PreferenceKey {
    static let language = L.languageKey
    static let theme = "appTheme"
    static let securityProfile = "defaultSecurityProfile"
    static let integrityProfile = "defaultIntegrityProfile"
    static let payloadCompression = "defaultPayloadCompression"
    static let irreversibilityAcknowledged = "irreversibilityAcknowledged"
}

/// Valori iniziali della schermata Cifra.
///
/// I profili determinano il *contenuto* del file, quindi i valori veri restano
/// quelli di Rust: qui si memorizza solo **quale** profilo è preselezionato.
struct EncryptionDefaults {
    var securityProfile: SecurityProfile
    var integrityProfile: IntegrityProfile
    var payloadCompression: PayloadCompression

    /// Gli stessi predefiniti del desktop, finché non si cambiano.
    static let builtIn = EncryptionDefaults(
        securityProfile: .standard,
        integrityProfile: .standard,
        payloadCompression: .zlib
    )

    static var current: EncryptionDefaults {
        let defaults = UserDefaults.standard
        return EncryptionDefaults(
            securityProfile: SecurityProfile(
                storageValue: defaults.string(forKey: PreferenceKey.securityProfile)
            ) ?? builtIn.securityProfile,
            integrityProfile: IntegrityProfile(
                storageValue: defaults.string(forKey: PreferenceKey.integrityProfile)
            ) ?? builtIn.integrityProfile,
            payloadCompression: PayloadCompression(
                storageValue: defaults.string(forKey: PreferenceKey.payloadCompression)
            ) ?? builtIn.payloadCompression
        )
    }
}

// MARK: - Profili: etichette e persistenza
//
// Gli enum arrivano da UniFFI e non sono né `RawRepresentable` né
// `CaseIterable`: entrambe le cose servono per elencarli in un `Picker` e per
// salvarne la scelta. Si aggiungono qui invece di modificare il crate, perché
// sono esigenze della UI e non del formato.
//
// Niente `@retroactive`: i binding generati sono compilati **dentro** il modulo
// dell'app, quindi questi tipi sono nostri e l'attributo non si applica.

extension SecurityProfile: CaseIterable {
    public static var allCases: [SecurityProfile] { [.standard, .strong, .paranoid] }

    var storageValue: String {
        switch self {
        case .standard: return "standard"
        case .strong: return "strong"
        case .paranoid: return "paranoid"
        }
    }

    init?(storageValue: String?) {
        switch storageValue {
        case "standard": self = .standard
        case "strong": self = .strong
        case "paranoid": self = .paranoid
        default: return nil
        }
    }

    /// Le etichette dell'upstream: `opt_standard`, `opt_strong`, `opt_paranoid`.
    var label: String {
        switch self {
        case .standard: return L.t("Standard")
        case .strong: return L.t("High")
        case .paranoid: return L.t("Maximum")
        }
    }
}

extension IntegrityProfile: CaseIterable {
    public static var allCases: [IntegrityProfile] { [.low, .standard, .high, .max] }

    var storageValue: String {
        switch self {
        case .low: return "low"
        case .standard: return "standard"
        case .high: return "high"
        case .max: return "max"
        }
    }

    init?(storageValue: String?) {
        switch storageValue {
        case "low": self = .low
        case "standard": self = .standard
        case "high": self = .high
        case "max": self = .max
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .low: return L.t("Low")
        case .standard: return L.t("Balanced")
        case .high: return L.t("High")
        case .max: return L.t("Maximum")
        }
    }
}

extension PayloadCompression: CaseIterable {
    public static var allCases: [PayloadCompression] { [.none, .zlib, .lzma] }

    var storageValue: String {
        switch self {
        case .none: return "none"
        case .zlib: return "zlib"
        case .lzma: return "lzma"
        }
    }

    init?(storageValue: String?) {
        switch storageValue {
        case "none": self = .none
        case "zlib": self = .zlib
        case "lzma": self = .lzma
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .none: return L.t("None")
        case .zlib: return "Zlib"
        case .lzma: return "LZMA"
        }
    }
}
