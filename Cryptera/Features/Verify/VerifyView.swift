import SwiftUI

/// Schermata Verify (SPEC §8.3): controlla l'integrità senza scrivere nulla.
///
/// Prima di M4 leggeva una fixture del bundle, perché il document picker non
/// esisteva ancora. Ora l'input arriva dallo stesso `.fileImporter` di Decrypt,
/// e lo scaffolding di M3 — `BundledFixture` e il picker delle fixture — è
/// stato rimosso.
struct VerifyView: View {
    @State private var model = VerifyModel()
    @State private var choosingInput = false

    var body: some View {
        NavigationStack {
            Form {
                Section("File cifrato") {
                    Button("Scegli un file .ecf") { choosingInput = true }
                        .accessibilityIdentifier("verify.chooseInput")

                    if let input = model.input {
                        LabeledContent("File", value: input.lastPathComponent)
                            .accessibilityIdentifier("verify.input")
                    }
                }

                if model.input != nil {
                    Section("Password") {
                        SecureField("Password", text: $model.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("verify.password")
                    }

                    Section {
                        if model.isRunning {
                            HStack {
                                if let fraction = model.progress?.fraction {
                                    ProgressView(value: fraction) {
                                        Text(model.progress?.stage.displayName ?? "")
                                    }
                                } else {
                                    ProgressView { Text(model.progress?.stage.displayName ?? "") }
                                }
                                Spacer()
                                Button("Annulla", role: .destructive) { model.cancel() }
                                    .buttonStyle(.borderless)
                            }
                        } else {
                            Button("Verifica") { Task { await model.run() } }
                                .disabled(!model.canRun)
                                .accessibilityIdentifier("verify.run")
                        }
                    }
                }

                if let outcome = model.outcome {
                    Section("Risultato") {
                        switch outcome {
                        case .success(let meta):
                            LabeledContent("Esito", value: "integro")
                                .accessibilityIdentifier("verify.outcome.success")
                            LabeledContent("Formato", value: "ECF1 v\(meta.version)")
                            LabeledContent("Dimensione", value: SizeFormatter.string(meta.plainSize))
                            LabeledContent("Ridondanza", value: "k \(meta.k) / r \(meta.r)")
                        case .failure(let message):
                            Text(message)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("verify.outcome.failure")
                        }
                    }
                }
            }
            .navigationTitle("Verifica")
        }
        .fileImporter(
            isPresented: $choosingInput,
            allowedContentTypes: [.crypteraECF]
        ) { result in
            if case .success(let url) = result { model.select(url) }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class VerifyModel {
    enum Outcome {
        case success(MetaInfo)
        case failure(String)
    }

    private(set) var input: URL?
    var password = ""
    private(set) var progress: OperationProgress?
    private(set) var outcome: Outcome?
    private(set) var isRunning = false

    private var token: CancelToken?

    var canRun: Bool { input != nil && !password.isEmpty && !isRunning }

    func select(_ url: URL) {
        input = url
        outcome = nil
        progress = nil
        password = ""
    }

    func cancel() {
        token?.cancel()
    }

    func run() async {
        guard let input else { return }

        let token = CancelToken()
        self.token = token
        isRunning = true
        outcome = nil
        progress = nil
        defer {
            isRunning = false
            self.token = nil
        }

        let password = password

        do {
            let meta = try await FileAccess.withSecurityScope(input) { path in
                try await CrypteraEngine.shared.verify(
                    VerifyRequest(inputPath: path, password: password, keyfilePath: nil),
                    token: token,
                    onProgress: { [weak self] update in
                        // Il callback arriva da un thread Rust: hop sul main
                        // actor prima di toccare stato osservabile (SPEC §7).
                        Task { @MainActor in self?.progress = update }
                    }
                )
            }
            outcome = .success(meta)
        } catch let error as CrypteraError {
            outcome = .failure(ErrorPresenter.message(for: error))
        } catch {
            outcome = .failure(ErrorPresenter.unexpected)
        }
    }
}
