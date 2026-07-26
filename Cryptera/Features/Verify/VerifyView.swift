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
            .navigationTitle(L.t("Verify"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ResetButton(
                        enabled: model.hasWorkInProgress && !model.isRunning,
                        identifier: "verify.reset"
                    ) {
                        model.reset()
                    }
                }
            }
        }
        // ⚠️ I due `.fileImporter` stanno ciascuno sulla card che lo apre, non
        // qui: due modificatori di presentazione dello stesso tipo sulla stessa
        // view entrano in conflitto e SwiftUI ne onora uno solo, in silenzio.
    }

    private var inputCard: some View {
        Card(title: L.t("Encrypted file"), footnote: L.t("Verifying writes nothing to disk.")) {
            if let input = model.input {
                FileTile(
                    name: input.lastPathComponent,
                    systemImage: "lock.doc",
                    changeTitle: L.t("Change"),
                    onChange: { choosingInput = true }
                )
                .accessibilityIdentifier("verify.input")
            } else {
                FilePlaceholder(
                    title: L.t("Choose an .ecf file"),
                    subtitle: L.t("Checks its integrity without writing it out"),
                    systemImage: "checkmark.shield",
                    action: { choosingInput = true }
                )
                .accessibilityIdentifier("verify.chooseInput")
            }
        }
        .fileImporter(isPresented: $choosingInput, allowedContentTypes: [.crypteraECF]) { result in
            if case .success(let url) = result { model.select(url) }
        }
    }

    private var passwordCard: some View {
        Card(title: L.t("Password")) {
            SecretField(title: L.t("Password"), text: $model.password, identifier: "verify.password")

            Divider()

            if let keyfile = model.keyfile {
                FileTile(
                    name: keyfile.lastPathComponent,
                    detail: L.t("Keyfile"),
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: L.t("Remove"),
                    onChange: { model.clearKeyfile() }
                )
            } else {
                Button(L.t("Add a keyfile")) { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
            }
        }
        .fileImporter(isPresented: $choosingKeyfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.selectKeyfile(url) }
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
                    title: L.t("Verify"),
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
            Card(title: L.t("Result")) {
                Notice(
                    kind: .success,
                    text: L.t("The file is intact and the password is correct."),
                    identifier: "verify.outcome.success"
                )
                MetadataRow(label: L.t("Format"), value: "ECF1 v\(meta.version)", monospaced: true)
                MetadataRow(label: L.t("Size"), value: SizeFormatter.string(meta.plainSize))
                MetadataRow(
                    label: L.t("Recovery"),
                    value: L.t("%d blocks per %d", Int(meta.r), Int(meta.k))
                )
            }
        case .failure(let message):
            Card(title: L.t("Result")) {
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

    /// C'è qualcosa da azzerare?
    var hasWorkInProgress: Bool {
        input != nil || keyfile != nil || !password.isEmpty || outcome != nil
    }

    /// Riporta la schermata allo stato iniziale. La verifica non produce file,
    /// quindi non c'è nulla da cancellare dal disco.
    func reset() {
        input = nil
        keyfile = nil
        password = ""
        outcome = nil
        progress = nil
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
            let meta = try await AuditLog.shared.measure(
                op: "verify",
                file: input.lastPathComponent
            ) {
                try await FileAccess.withSecurityScope(
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
            }
            outcome = .success(meta)
        } catch let error as CrypteraError {
            outcome = .failure(ErrorPresenter.message(for: error))
        } catch {
            // Non `unexpected`: qui arriva anche il preflight memoria, che ha
            // un messaggio suo e sa dire quanta ne servirebbe.
            outcome = .failure(ErrorPresenter.message(for: error))
        }
    }
}
