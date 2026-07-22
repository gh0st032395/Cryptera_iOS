import SwiftUI

@main
struct CrypteraApp: App {
    var body: some Scene {
        WindowGroup {
            // M3: unica schermata, senza navigazione. Il TabView di SPEC §8.1
            // arriva con le altre feature.
            VerifyView()
        }
    }
}
