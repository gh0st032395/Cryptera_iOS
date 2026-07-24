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
            .navigationTitle("Decifra")
        }
        // `task(id:)` e non `onChange`: deve scattare anche quando il file è già
        // presente alla prima comparsa, cioè quando è l'apertura di un `.ecf` ad
        // aver avviato l'app.
        .task(id: router.pendingInput) {
            guard let pending = router.pendingInput else { return }
            await model.select(pending.url)
        }
        .fileImporter(isPresented: $choosingInput, allowedContentTypes: [.crypteraECF]) { result in
            if case .success(let url) = result {
                Task { await model.select(url) }
            }
        }
        .fileImporter(isPresented: $choosingKeyfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.selectKeyfile(url) }
        }
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
        Card(title: "File cifrato") {
            if let input = model.input {
                FileTile(
                    name: input.name,
                    detail: model.header.map { "ECF1 v\($0.meta.version)" },
                    systemImage: "lock.doc",
                    changeTitle: "Cambia",
                    onChange: { choosingInput = true }
                )
                .accessibilityIdentifier("decrypt.input")
            } else {
                FilePlaceholder(
                    title: "Scegli un file .ecf",
                    subtitle: "Oppure aprine uno dall'app File",
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
    }

    /// Ciò che si può dire del file **senza** password.
    @ViewBuilder
    private func metadata(_ header: DecryptModel.Header) -> some View {
        MetadataRow(
            label: "Contenuto",
            value: header.summary.isTarContainer ? "Archivio di più file" : "File singolo",
            identifier: "decrypt.meta.content"
        )

        // Il nome è memorizzato **dentro** il file e lo sceglie chi lo ha
        // creato: si mostra la forma sanificata, che è quella con cui verrà
        // effettivamente salvato. Mostrare quella grezza descriverebbe un
        // salvataggio che non avverrà.
        if let original = header.originalName {
            MetadataRow(
                label: "Nome originale",
                value: safeOutputName(storedName: original, fallback: "—")
            )
        } else if header.summary.filenameEncrypted {
            MetadataRow(label: "Nome originale", value: "cifrato — serve la password")
        }

        MetadataRow(label: "Dimensione", value: SizeFormatter.string(header.meta.plainSize))
        MetadataRow(label: "Compressione", value: compressionLabel(header.summary.payloadCompression))
        // In chiaro invece che "k/r": il rapporto grezzo è il vocabolario del
        // formato, non quello di chi sta guardando se il suo file è a posto.
        MetadataRow(
            label: "Recupero",
            value: "\(header.meta.r) blocchi ogni \(header.meta.k)"
        )
    }

    private var passwordCard: some View {
        Card(title: "Password") {
            SecretField(title: "Password", text: $model.password, identifier: "decrypt.password")

            if let keyfile = model.keyfile {
                Divider()
                FileTile(
                    name: keyfile.name,
                    detail: "Keyfile",
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: "Rimuovi",
                    onChange: { model.clearKeyfile() }
                )
            } else {
                Divider()
                Button("Aggiungi un keyfile") { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
            }

            if model.offersExtraction {
                Divider()
                Toggle("Estrai l'archivio", isOn: $model.extractArchive)
                    .accessibilityIdentifier("decrypt.extract")
                Text("Disattivalo per ottenere l'archivio così com'è, senza estrarne il contenuto.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    identifierPrefix: "decrypt"
                )
            } else {
                PrimaryButton(
                    title: "Decifra",
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
        Card(title: "Risultato") {
            Notice(
                kind: .success,
                text: output.isDirectory ? "Archivio estratto." : "File decifrato.",
                identifier: "decrypt.outcome.banner"
            )
            FileTile(
                name: output.name,
                detail: output.isDirectory ? "Cartella" : nil,
                systemImage: output.isDirectory ? "folder" : "doc.text"
            )
            .accessibilityIdentifier("decrypt.outcome.success")

            PrimaryButton(
                title: "Salva in File",
                systemImage: "square.and.arrow.down",
                identifier: "decrypt.save"
            ) {
                exporting = true
            }

            // `ShareLink` solo sui file: una cartella non è un contenuto che le
            // destinazioni della share sheet sappiano trattare in modo
            // prevedibile. Per l'archivio estratto resta "Salva in File", che
            // gestisce entrambi.
            if !output.isDirectory {
                ShareLink(item: output.url)
                    .accessibilityIdentifier("decrypt.share")
            }

            Button("Elimina la copia in chiaro", role: .destructive) {
                model.discardWork()
            }
            .font(.subheadline)
            .accessibilityIdentifier("decrypt.discard")
        }
    }

    private func compressionLabel(_ compression: PayloadCompression) -> String {
        switch compression {
        case .none: return "Nessuna"
        case .zlib: return "Zlib"
        case .lzma: return "LZMA"
        }
    }
}
