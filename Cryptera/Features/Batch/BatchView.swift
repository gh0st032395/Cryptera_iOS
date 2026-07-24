import SwiftUI

/// Schermata Batch (SPEC §8.3).
///
/// Una coda di `.ecf`, una password sola, esecuzione sequenziale con lo stato
/// accanto a ogni file. Alla fine i risultati sono in **una** cartella, che si
/// salva con un solo passaggio dal selettore di sistema.
struct BatchView: View {
    @State private var model = BatchModel()
    @State private var choosingFiles = false
    @State private var choosingKeyfile = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            ScreenScroll {
                queueCard
                if !model.items.isEmpty {
                    passwordCard
                    actionCard
                }
                if let summary = model.summary { summaryCard(summary) }
            }
            .navigationTitle(L.t("Batch"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ResetButton(
                        enabled: model.hasWorkInProgress && !model.isRunning,
                        confirmationMessage: model.outputFolder == nil ? nil
                            : L.t("The decrypted files have not been saved yet. They will be deleted."),
                        identifier: "batch.reset"
                    ) {
                        model.reset()
                    }
                }
            }
        }
        .fileMover(isPresented: $exporting, file: model.outputFolder) { result in
            if case .success = result { model.discardWork() }
        }
    }

    // MARK: - Coda

    private var queueCard: some View {
        Card(
            title: L.t("Queue"),
            footnote: model.items.isEmpty ? nil
                : L.t("The files are processed one at a time, in order.")
        ) {
            FilePlaceholder(
                title: L.t("Add .ecf files"),
                subtitle: L.t("You can select several at once"),
                systemImage: "plus.rectangle.on.folder",
                action: { choosingFiles = true }
            )
            .accessibilityIdentifier("batch.add")

            ForEach(model.items) { item in
                Divider()
                row(item)
            }
        }
        .fileImporter(
            isPresented: $choosingFiles,
            allowedContentTypes: [.crypteraECF],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    private func row(_ item: BatchModel.Item) -> some View {
        HStack(spacing: Design.Space.m) {
            statusIcon(item.state)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let message) = item.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Design.danger)
                }
            }

            Spacer(minLength: 0)

            if !model.isRunning {
                Button {
                    model.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L.t("Remove from queue"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusIcon(_ state: BatchModel.Item.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Design.danger)
        }
    }

    // MARK: - Password

    private var passwordCard: some View {
        Card(
            title: L.t("Password"),
            footnote: L.t("The same password is used for every file in the queue.")
        ) {
            SecretField(title: L.t("Password"), text: $model.password, identifier: "batch.password")

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
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction).tint(Design.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Design.accent)
                    }
                    if let index = model.currentIndex {
                        Text(L.t("%d of %d", index + 1, model.items.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button(L.t("Cancel"), role: .destructive) { model.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("batch.cancel")
                }
            } else {
                PrimaryButton(
                    title: L.t("Decrypt all"),
                    systemImage: "lock.open",
                    enabled: model.canRun,
                    identifier: "batch.run"
                ) {
                    Task { await model.run() }
                }
                if model.password.isEmpty && !model.items.isEmpty {
                    Text(L.t("Enter a password."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Riepilogo

    private func summaryCard(_ summary: BatchModel.Summary) -> some View {
        Card(title: L.t("Result")) {
            Notice(
                kind: summary.failed == 0 ? .success : .warning,
                text: L.t(
                    "%d succeeded, %d failed — %@",
                    summary.succeeded,
                    summary.failed,
                    Self.durationText(summary.duration)
                ),
                identifier: "batch.summary"
            )

            if model.outputFolder != nil {
                PrimaryButton(
                    title: L.t("Save to Files"),
                    systemImage: "square.and.arrow.down",
                    identifier: "batch.save"
                ) {
                    exporting = true
                }
                Button(L.t("Delete the decrypted copies"), role: .destructive) {
                    model.discardWork()
                }
                .font(.subheadline)
                .accessibilityIdentifier("batch.discard")
            }
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 1
            ? L.t("less than a second")
            : String(format: "%.1f s", seconds)
    }
}
