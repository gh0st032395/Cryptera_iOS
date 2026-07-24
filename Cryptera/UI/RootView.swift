import SwiftUI

/// File `.ecf` consegnato all'app dall'esterno.
///
/// Ha un'identità propria perché la stessa apertura dello stesso file deve
/// contare come un evento nuovo: confrontando i soli URL, riaprire due volte lo
/// stesso documento non farebbe scattare nulla.
struct PendingInput: Equatable, Identifiable {
    let id = UUID()
    let url: URL
}

/// Instradamento fra le schermate.
///
/// Esiste per un motivo solo: un `.ecf` aperto dall'app File deve arrivare
/// nella schermata Decrypt già compilato (SPEC §6.5), che è il gesto
/// equivalente al doppio click sul desktop.
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case encrypt
        case decrypt
        case verify
        case settings
    }

    var tab: Tab = .decrypt
    private(set) var pendingInput: PendingInput?
    private(set) var pendingEncryptInput: PendingInput?

    func open(_ url: URL) {
        pendingInput = PendingInput(url: url)
        tab = .decrypt
    }

    /// Solo per i UI test (vedi `LaunchArguments`): niente, nell'app, consegna
    /// un file alla schermata Cifra dall'esterno.
    func openForEncryption(_ url: URL) {
        pendingEncryptInput = PendingInput(url: url)
        tab = .encrypt
    }
}

/// Contenitore delle schermate.
struct RootView: View {
    @State private var router = AppRouter()

    @AppStorage(PreferenceKey.language) private var language = AppLanguage.system.rawValue
    @AppStorage(PreferenceKey.theme) private var theme = AppTheme.system.rawValue

    var body: some View {
        TabView(selection: $router.tab) {
            EncryptView(router: router)
                .tabItem { Label(L.t("Encrypt"), systemImage: "lock") }
                .tag(AppRouter.Tab.encrypt)

            DecryptView(router: router)
                .tabItem { Label(L.t("Decrypt"), systemImage: "lock.open") }
                .tag(AppRouter.Tab.decrypt)

            VerifyView()
                .tabItem { Label(L.t("Verify"), systemImage: "checkmark.shield") }
                .tag(AppRouter.Tab.verify)

            SettingsView()
                .tabItem { Label(L.t("Settings"), systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
        }
        // Il verde di Cryptera diventa il colore delle azioni in tutta l'app,
        // barra delle tab compresa.
        .tint(Design.accent)
        // Il tema si applica alla finestra, non solo all'albero SwiftUI: la
        // barra delle schede è UIKit e con il solo `preferredColorScheme`
        // resterebbe con l'aspetto precedente fino al primo tocco.
        .onChange(of: theme, initial: true) {
            AppTheme(rawValue: theme)?.apply()
        }
        // Le stringhe si risolvono con `L.t(...)`, che legge la lingua scelta al
        // momento della chiamata: cambiarla non invaliderebbe da sola alcuna
        // vista. Ricostruire l'albero è il modo diretto per farlo — succede una
        // volta, quando l'utente cambia lingua di proposito.
        .id(language)
        .onOpenURL { router.open($0) }
        .task {
            // Prima di qualunque operazione: un output decifrato di una sessione
            // interrotta non deve sopravvivere al riavvio dell'app.
            TemporaryWorkspace.purgeStale()
            await CrypteraEngine.shared.configureIfNeeded()
            #if DEBUG
            if let url = LaunchArguments.fixtureToOpen() { router.open(url) }
            if let url = LaunchArguments.fixtureToEncrypt() { router.openForEncryption(url) }
            #endif
        }
    }
}

#if DEBUG
/// Aggancio per i UI test.
///
/// Da M4 l'input arriva da `.fileImporter`, che è interfaccia di sistema fuori
/// processo: XCUITest non la pilota in modo affidabile fra versioni di iOS.
/// Questo argomento inietta una fixture del bundle **attraverso lo stesso
/// percorso di `.onOpenURL`** — che è anche il flusso da verificare, l'apertura
/// di un `.ecf` arrivato da fuori.
///
/// È il motivo per cui le fixture restano nel bundle in Debug; in Release sono
/// escluse da `project.yml` e questo codice non viene nemmeno compilato.
///
/// ⚠️ La scorciatoia **salta** l'apertura del selettore, che è proprio il punto
/// che si era rotto una volta: quel tratto è coperto da `FilePickerUITests`.
enum LaunchArguments {
    static let openFixture = "-apri-fixture"
    /// Consegna una fixture alla schermata Cifra. Vale come file qualsiasi: a
    /// cifrare, un `.ecf` è un file come un altro.
    static let encryptFixture = "-cifra-fixture"

    static func fixtureToOpen() -> URL? { fixture(after: openFixture) }

    static func fixtureToEncrypt() -> URL? { fixture(after: encryptFixture) }

    private static func fixture(after flag: String) -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return Bundle.main.url(
            forResource: arguments[index + 1],
            withExtension: "ecf",
            subdirectory: "Fixtures"
        )
    }
}
#endif
