import SwiftUI

@main
struct CrypteraApp: App {
    var body: some Scene {
        WindowGroup {
            SmokeTestView()
        }
    }
}

/// Vista di verifica per M2 (SPEC §15): dimostra che l'XCFramework è linkato e
/// che il core Rust risponde sul target.
///
/// Non è design — viene sostituita dalla navigazione reale in M4/M9.
/// La verifica che il core sappia *interpretare* un file ECF1 sta in
/// `CrypteraTests/EngineTests.swift`, che ha accesso alle fixture senza doverle
/// spedire nel bundle dell'app.
struct SmokeTestView: View {
    @State private var version = "…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cryptera")
                .font(.largeTitle.bold())

            LabeledContent("Core", value: version)
                .monospaced()

            Spacer()
        }
        .padding()
        .task { version = coreVersion() }
    }
}
