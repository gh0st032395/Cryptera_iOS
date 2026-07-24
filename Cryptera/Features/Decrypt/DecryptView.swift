import SwiftUI

/// Schermata Decrypt (SPEC §8.3).
///
/// Il design vero arriva in M9: qui contano il flusso e il cablaggio —
/// selezione del `.ecf`, metadati leggibili **senza** password, esecuzione con
/// progress e annullamento, consegna dell'output al sistema.
struct DecryptView: View {
    let router: AppRouter

    @State private var model = DecryptModel()
    @State private var choosingInput = false
    @State private var choosingKeyfile = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                inputSection
                if model.header != nil {
                    passwordSection
                    if model.offersExtraction { optionsSection }
                    runSection
                }
                if let output = model.output { resultSection(output) }
                if let message = model.errorMessage { errorSection(message) }
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
        .fileImporter(
            isPresented: $choosingInput,
            allowedContentTypes: [.crypteraECF]
        ) { result in
            if case .success(let url) = result {
                Task { await model.select(url) }
            }
        }
        .fileImporter(
            isPresented: $choosingKeyfile,
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result {
                model.selectKeyfile(url)
            }
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

    private var inputSection: some View {
        Section("File cifrato") {
            Button("Scegli un file .ecf") { choosingInput = true }
                .accessibilityIdentifier("decrypt.chooseInput")

            if let input = model.input {
                LabeledContent("File", value: input.name)
                    .accessibilityIdentifier("decrypt.input")
            }

            if let problem = model.headerProblem {
                Text(problem)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("decrypt.header.problem")
            }

            if let header = model.header {
                metadata(header)
            }
        }
    }

    /// Ciò che si può dire del file **senza** password (SPEC §8.3).
    @ViewBuilder
    private func metadata(_ header: DecryptModel.Header) -> some View {
        LabeledContent("Formato", value: "ECF1 v\(header.meta.version)")
        LabeledContent(
            "Contenuto",
            value: header.summary.isTarContainer ? "Archivio di più file" : "File singolo"
        )
        .accessibilityIdentifier("decrypt.meta.content")

        // Il nome è memorizzato **dentro** il file e lo sceglie chi lo ha
        // creato: si mostra la forma sanificata, che è quella con cui verrà
        // effettivamente salvato. Mostrare quella grezza descriverebbe un
        // salvataggio che non avverrà.
        if let original = header.originalName {
            LabeledContent(
                "Nome originale",
                value: safeOutputName(storedName: original, fallback: "—")
            )
        } else if header.summary.filenameEncrypted {
            LabeledContent("Nome originale", value: "cifrato — serve la password")
        }

        LabeledContent("Dimensione", value: SizeFormatter.string(header.meta.plainSize))
        LabeledContent("Compressione", value: compressionLabel(header.summary.payloadCompression))
        LabeledContent("Ridondanza", value: "k \(header.meta.k) / r \(header.meta.r)")
    }

    private var passwordSection: some View {
        Section("Password") {
            SecureField("Password", text: $model.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("decrypt.password")

            if let keyfile = model.keyfile {
                LabeledContent("Keyfile", value: keyfile.name)
                Button("Rimuovi keyfile", role: .destructive) { model.clearKeyfile() }
            } else {
                Button("Aggiungi un keyfile") { choosingKeyfile = true }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Estrai l'archivio", isOn: $model.extractArchive)
                .accessibilityIdentifier("decrypt.extract")
        } footer: {
            Text("Disattivalo per ottenere l'archivio così com'è, senza estrarne il contenuto.")
        }
    }

    private var runSection: some View {
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
                        .accessibilityIdentifier("decrypt.cancel")
                }
            } else {
                Button("Decifra") { Task { await model.run() } }
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("decrypt.run")
            }
        }
    }

    private func resultSection(_ output: DecryptModel.Output) -> some View {
        Section("Risultato") {
            LabeledContent(output.isDirectory ? "Cartella" : "File", value: output.name)
                .accessibilityIdentifier("decrypt.outcome.success")

            Button("Salva in File") { exporting = true }
                .accessibilityIdentifier("decrypt.save")

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
            .accessibilityIdentifier("decrypt.discard")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("decrypt.outcome.failure")
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
