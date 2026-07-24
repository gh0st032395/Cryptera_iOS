import SwiftUI

/// Schermata Verify (SPEC §8.3): controlla l'integrità senza scrivere nulla.
///
/// È l'operazione da usare quando si vuole sapere se un archivio è ancora sano
/// senza produrne una copia in chiaro — utile su un backup, dove il file
/// decifrato non serve e sarebbe solo un rischio in più.
struct VerifyView: View {
    @State private var model = VerifyModel()
    @State private var choosingInput = false
    @State private var choosingKeyfile = false

    var body: some View {
        NavigationStack {
            ScreenScroll {
                inputCard
                if model.input != nil {
                    passwordCard
                    actionCard
                }
                if let outcome = model.outcome { outcomeCard(outcome) }
            }
            .navigationTitle("Verifica")
        }
        .fileImporter(isPresented: $choosingInput, allowedContentTypes: [.crypteraECF]) { result in
            if case .success(let url) = result { model.select(url) }
        }
        .fileImporter(isPresented: $choosingKeyfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.selectKeyfile(url) }
        }
    }

    private var inputCard: some View {
        Card(title: "File cifrato", footnote: "La verifica non scrive nulla su disco.") {
            if let input = model.input {
                FileTile(
                    name: input.lastPathComponent,
                    systemImage: "lock.doc",
                    changeTitle: "Cambia",
                    onChange: { choosingInput = true }
                )
                .accessibilityIdentifier("verify.input")
            } else {
                FilePlaceholder(
                    title: "Scegli un file .ecf",
                    subtitle: "Ne controlla l'integrità senza decifrarlo su disco",
                    systemImage: "checkmark.shield",
                    action: { choosingInput = true }
                )
                .accessibilityIdentifier("verify.chooseInput")
            }
        }
    }

    private var passwordCard: some View {
        Card(title: "Password") {
            SecretField(title: "Password", text: $model.password, identifier: "verify.password")

            Divider()

            if let keyfile = model.keyfile {
                FileTile(
                    name: keyfile.lastPathComponent,
                    detail: "Keyfile",
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: "Rimuovi",
                    onChange: { model.clearKeyfile() }
                )
            } else {
                Button("Aggiungi un keyfile") { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var actionCard: some View {
        Card {
            if model.isRunning {
                RunningPanel(
                    progress: model.progress,
                    paused: model.isPaused,
                    onPause: { model.togglePause() },
                    onCancel: { model.cancel() },
                    identifierPrefix: "verify"
                )
            } else {
                PrimaryButton(
                    title: "Verifica",
                    systemImage: "checkmark.shield",
                    enabled: model.canRun,
                    identifier: "verify.run"
                ) {
                    Task { await model.run() }
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeCard(_ outcome: VerifyModel.Outcome) -> some View {
        switch outcome {
        case .success(let meta):
            Card(title: "Risultato") {
                Notice(
                    kind: .success,
                    text: "Il file è integro e la password è corretta.",
                    identifier: "verify.outcome.success"
                )
                MetadataRow(label: "Formato", value: "ECF1 v\(meta.version)", monospaced: true)
                MetadataRow(label: "Dimensione", value: SizeFormatter.string(meta.plainSize))
                MetadataRow(
                    label: "Recupero",
                    value: "\(meta.r) blocchi ogni \(meta.k)"
                )
            }
        case .failure(let message):
            Card(title: "Risultato") {
                Notice(kind: .danger, text: message, identifier: "verify.outcome.failure")
            }
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
    private(set) var keyfile: URL?
    private(set) var progress: OperationProgress?
    private(set) var outcome: Outcome?
    private(set) var isRunning = false
    private(set) var isPaused = false

    private var token: CancelToken?

    var canRun: Bool { input != nil && !password.isEmpty && !isRunning }

    func select(_ url: URL) {
        input = url
        outcome = nil
        progress = nil
        // La password digitata per il file precedente non deve restare pronta
        // da inviare per un file diverso.
        password = ""
    }

    func selectKeyfile(_ url: URL) {
        keyfile = url
    }

    func clearKeyfile() {
        keyfile = nil
    }

    func cancel() {
        token?.cancel()
    }

    func togglePause() {
        isPaused.toggle()
        token?.setPaused(paused: isPaused)
    }

    func run() async {
        guard let input else { return }

        let token = CancelToken()
        self.token = token
        isRunning = true
        isPaused = false
        outcome = nil
        progress = nil
        defer {
            isRunning = false
            isPaused = false
            self.token = nil
        }

        let password = password
        let keyfileURL = keyfile

        do {
            let meta = try await FileAccess.withSecurityScope(
                input: input,
                keyfile: keyfileURL
            ) { inputPath, keyfilePath in
                try await CrypteraEngine.shared.verify(
                    VerifyRequest(
                        inputPath: inputPath,
                        password: password,
                        keyfilePath: keyfilePath
                    ),
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
