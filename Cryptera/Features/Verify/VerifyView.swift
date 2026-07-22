import SwiftUI

/// Schermata di verifica minimale — criterio di uscita di M3 (SPEC §15).
///
/// **Nessun design**: la UI reale arriva in M9. Serve a dimostrare che
/// l'intera catena SwiftUI → CrypteraEngine → UniFFI → Rust → core funziona
/// end-to-end, con progress e cancellazione.
///
/// L'input è una fixture nel bundle perché il document picker arriva in M4.
struct VerifyView: View {
    @State private var model = VerifyModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Picker("Fixture", selection: $model.fixture) {
                        ForEach(BundledFixture.allCases) { fixture in
                            Text(fixture.displayName).tag(fixture)
                        }
                    }
                    SecureField("Password", text: $model.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("verify.password")
                }

                Section {
                    if model.isRunning {
                        HStack {
                            if let fraction = model.progress?.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                            }
                            Spacer()
                            Button("Annulla", role: .destructive) { model.cancel() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button("Verifica") {
                            Task { await model.run() }
                        }
                        .disabled(model.password.isEmpty)
                        .accessibilityIdentifier("verify.run")
                    }
                }

                if let outcome = model.outcome {
                    Section("Risultato") {
                        switch outcome {
                        case .success(let meta):
                            LabeledContent("Esito", value: "integro")
                                .accessibilityIdentifier("verify.outcome.success")
                            LabeledContent("Versione", value: "\(meta.version)")
                            LabeledContent("Nome", value: meta.filename.isEmpty ? "—" : meta.filename)
                            LabeledContent("k / r", value: "\(meta.k) / \(meta.r)")
                            LabeledContent("Dimensione", value: "\(meta.plainSize) B")
                        case .failure(let message):
                            Text(message)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("verify.outcome.failure")
                        }
                    }
                }

                Section("Core") {
                    Text(model.version).font(.footnote.monospaced())
                }
            }
            .navigationTitle("Verify")
        }
        .task { await model.load() }
    }
}

// MARK: - Model

/// Fixture dell'upstream incluse nel bundle.
///
/// ⚠️ **Scaffolding di M3, da rimuovere in M4** insieme a questa schermata:
/// i dati di test non devono restare nel bundle di produzione. In M4 l'input
/// arriva da `.fileImporter` e le fixture restano solo nel target di test,
/// dove già sono.
enum BundledFixture: String, CaseIterable, Identifiable {
    case v4Basic = "v4-basic"
    case v4ZlibHidden = "v4-zlib-hidden"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var path: String? {
        Bundle.main.path(forResource: rawValue, ofType: "ecf", inDirectory: "Fixtures")
    }
}

@MainActor
@Observable
final class VerifyModel {
    enum Outcome {
        case success(MetaInfo)
        case failure(String)
    }

    var fixture: BundledFixture = .v4Basic
    var password = ""
    var progress: OperationProgress?
    var outcome: Outcome?
    var isRunning = false
    var version = "…"

    private var token: CancelToken?

    func load() async {
        version = await CrypteraEngine.shared.version()
    }

    func cancel() {
        token?.cancel()
    }

    func run() async {
        guard let path = fixture.path else {
            outcome = .failure("Fixture non presente nel bundle.")
            return
        }

        isRunning = true
        outcome = nil
        progress = nil
        let token = CancelToken()
        self.token = token
        defer {
            isRunning = false
            self.token = nil
        }

        do {
            let meta = try await CrypteraEngine.shared.verify(
                VerifyRequest(inputPath: path, password: password, keyfilePath: nil),
                token: token,
                onProgress: { [weak self] update in
                    // Il callback arriva da un thread Rust: hop sul main actor
                    // prima di toccare stato osservabile (SPEC §7).
                    Task { @MainActor in self?.progress = update }
                }
            )
            outcome = .success(meta)
        } catch let error as CrypteraError {
            outcome = .failure(ErrorPresenter.message(for: error))
        } catch {
            outcome = .failure(ErrorPresenter.unexpected)
        }
    }
}
