import SwiftUI

/// Schermata Decrypt (SPEC §8.3).
///
/// Mostra cosa contiene il file **prima** di chiedere la password: versione,
/// tipo di contenuto, nome originale se leggibile, dimensione. Sono le
/// informazioni che permettono di capire di aver scelto il file giusto senza
/// ancora impegnarsi.
struct DecryptView: View {
    let router: AppRouter

    @State private var model = DecryptModel()
    @State private var choosingInput = false
    @State private var choosingKeyfile = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            ScreenScroll {
                inputCard
                if model.header != nil {
                    passwordCard
                    actionCard
                }
                if let output = model.output { resultCard(output) }
                if let message = model.errorMessage {
                    Notice(kind: .danger, text: message, identifier: "decrypt.outcome.failure")
                }
            }
            .navigationTitle(L.t("Decrypt"))
        }
        // `task(id:)` e non `onChange`: deve scattare anche quando il file è già
        // presente alla prima comparsa, cioè quando è l'apertura di un `.ecf` ad
        // aver avviato l'app.
        .task(id: router.pendingInput) {
            guard let pending = router.pendingInput else { return }
            await model.select(pending.url)
        }
        // ⚠️ I due `.fileImporter` **non** stanno qui, ma ciascuno sulla card
        // che lo apre. Due modificatori di presentazione dello stesso tipo sulla
        // stessa view entrano in conflitto: SwiftUI ne onora uno solo e l'altro
        // non apre nulla, senza errori né avvisi.
        //
        // `fileMover` e non `fileExporter`: quest'ultimo vuole un `FileDocument`
        // o un `Transferable`, cioè il contenuto **in memoria** — un file
        // decifrato di qualche gigabyte farebbe terminare il processo prima di
        // riuscire a esportarlo. `fileMover` lavora su URL e non legge nulla, e
        // in più **sposta**: dell'output in chiaro resta un esemplare solo.
        //
        // Non si usa un `UIDocumentPickerViewController` dentro uno `.sheet`:
        // il picker è un servizio fuori processo e va presentato modalmente, non
        // annidato — così com'era, non compariva affatto.
        .fileMover(isPresented: $exporting, file: model.output?.url) { result in
            // Dopo lo spostamento il file non esiste più dove stava: continuare
            // a mostrarlo offrirebbe azioni destinate a fallire.
            if case .success = result { model.discardWork() }
        }
    }

    // MARK: - Sezioni

    private var inputCard: some View {
        Card(title: L.t("Encrypted file")) {
            if let input = model.input {
                FileTile(
                    name: input.name,
                    detail: model.header.map { "ECF1 v\($0.meta.version)" },
                    systemImage: "lock.doc",
                    changeTitle: L.t("Change"),
                    onChange: { choosingInput = true }
                )
                .accessibilityIdentifier("decrypt.input")
            } else {
                FilePlaceholder(
                    title: L.t("Choose an .ecf file"),
                    subtitle: L.t("Or open one from the Files app"),
                    systemImage: "lock.doc",
                    action: { choosingInput = true }
                )
                .accessibilityIdentifier("decrypt.chooseInput")
            }

            if let problem = model.headerProblem {
                Notice(kind: .danger, text: problem, identifier: "decrypt.header.problem")
            }

            if let header = model.header {
                Divider()
                metadata(header)
            }
        }
        .fileImporter(isPresented: $choosingInput, allowedContentTypes: [.crypteraECF]) { result in
            if case .success(let url) = result {
                Task { await model.select(url) }
            }
        }
    }

    /// Ciò che si può dire del file **senza** password.
    @ViewBuilder
    private func metadata(_ header: DecryptModel.Header) -> some View {
        MetadataRow(
            label: L.t("Contents"),
            value: header.summary.isTarContainer ? L.t("Archive of several files") : L.t("Single file"),
            identifier: "decrypt.meta.content"
        )

        // Il nome è memorizzato **dentro** il file e lo sceglie chi lo ha
        // creato: si mostra la forma sanificata, che è quella con cui verrà
        // effettivamente salvato. Mostrare quella grezza descriverebbe un
        // salvataggio che non avverrà.
        if let original = header.originalName {
            MetadataRow(
                label: L.t("Original name"),
                value: safeOutputName(storedName: original, fallback: "—")
            )
        } else if header.summary.filenameEncrypted {
            MetadataRow(label: L.t("Original name"), value: L.t("encrypted — password needed"))
        }

        MetadataRow(label: L.t("Size"), value: SizeFormatter.string(header.meta.plainSize))
        MetadataRow(label: L.t("Compression"), value: header.summary.payloadCompression.label)
        // In chiaro invece che "k/r": il rapporto grezzo è il vocabolario del
        // formato, non quello di chi sta guardando se il suo file è a posto.
        MetadataRow(
            label: L.t("Recovery"),
            value: L.t("%d blocks per %d", Int(header.meta.r), Int(header.meta.k))
        )
    }

    private var passwordCard: some View {
        Card(title: L.t("Password")) {
            SecretField(title: L.t("Password"), text: $model.password, identifier: "decrypt.password")

            if let keyfile = model.keyfile {
                Divider()
                FileTile(
                    name: keyfile.name,
                    detail: L.t("Keyfile"),
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: L.t("Remove"),
                    onChange: { model.clearKeyfile() }
                )
            } else {
                Divider()
                Button(L.t("Add a keyfile")) { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
            }

            if model.offersExtraction {
                Divider()
                Toggle(L.t("Extract the archive"), isOn: $model.extractArchive)
                    .accessibilityIdentifier("decrypt.extract")
                Text(L.t("Turn it off to get the archive as it is, without extracting its contents."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    identifierPrefix: "decrypt"
                )
            } else {
                PrimaryButton(
                    title: L.t("Decrypt"),
                    systemImage: "lock.open",
                    enabled: model.canRun,
                    identifier: "decrypt.run"
                ) {
                    Task { await model.run() }
                }
            }
        }
    }

    private func resultCard(_ output: DecryptModel.Output) -> some View {
        Card(title: L.t("Result")) {
            Notice(
                kind: .success,
                text: output.isDirectory ? L.t("Archive extracted.") : L.t("File decrypted."),
                identifier: "decrypt.outcome.banner"
            )
            FileTile(
                name: output.name,
                detail: output.isDirectory ? L.t("Folder") : nil,
                systemImage: output.isDirectory ? "folder" : "doc.text"
            )
            .accessibilityIdentifier("decrypt.outcome.success")

            PrimaryButton(
                title: L.t("Save to Files"),
                systemImage: "square.and.arrow.down",
                identifier: "decrypt.save"
            ) {
                exporting = true
            }

            // `ShareLink` solo sui file: una cartella non è un contenuto che le
            // destinazioni della share sheet sappiano trattare in modo
            // prevedibile. Per l'archivio estratto resta L.t("Save to Files"), che
            // gestisce entrambi.
            if !output.isDirectory {
                ShareLink(item: output.url)
                    .accessibilityIdentifier("decrypt.share")
            }

            Button(L.t("Delete the decrypted copy"), role: .destructive) {
                model.discardWork()
            }
            .font(.subheadline)
            .accessibilityIdentifier("decrypt.discard")
        }
    }

}
