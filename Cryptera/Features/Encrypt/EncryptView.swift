import SwiftUI

/// Schermata Encrypt (SPEC §8.2).
///
/// L'ordine delle sezioni è l'ordine delle decisioni: cosa cifrare, con quale
/// password, con quali parametri. Le opzioni restano chiuse — hanno buoni valori
/// predefiniti, e aprirle in faccia a chi vuole solo cifrare un file
/// trasformerebbe un gesto semplice in un modulo da compilare.
struct EncryptView: View {
    let router: AppRouter

    @State private var model = EncryptModel()
    @State private var choosingInput = false
    @State private var choosingKeyfile = false
    @State private var exporting = false
    @State private var optionsExpanded = false
    @State private var askingIrreversibility = false

    /// L'avviso di irreversibilità si mostra **una volta sola**, come sul
    /// desktop (`warning.js`, chiave in `localStorage`). Ripeterlo a ogni
    /// cifratura lo trasformerebbe in un ostacolo da chiudere senza leggere.
    @AppStorage("irreversibilityAcknowledged") private var acknowledged = false

    var body: some View {
        NavigationStack {
            ScreenScroll {
                inputCard
                if model.input != nil {
                    passwordCard
                    optionsCard
                    actionCard
                }
                if let output = model.output { resultCard(output) }
                if let message = model.errorMessage {
                    Notice(kind: .danger, text: message, identifier: "encrypt.outcome.failure")
                }
            }
            .navigationTitle("Cifra")
        }
        .task(id: router.pendingEncryptInput) {
            guard let pending = router.pendingEncryptInput else { return }
            model.select(pending.url)
        }
        .fileImporter(isPresented: $choosingInput, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.select(url) }
        }
        .fileImporter(isPresented: $choosingKeyfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.selectKeyfile(url) }
        }
        .fileMover(isPresented: $exporting, file: model.output?.url) { result in
            if case .success = result { model.discardWork() }
        }
        .alert("Non esiste recupero password", isPresented: $askingIrreversibility) {
            Button("Annulla", role: .cancel) {}
            Button("Ho capito, cifra") {
                acknowledged = true
                Task { await run() }
            }
        } message: {
            Text(
                """
                Cryptera non ha backdoor né meccanismi di recupero: se dimentichi \
                la password — e perdi il keyfile, se ne usi uno — i dati cifrati \
                sono irrecuperabili per sempre.

                Conservala in un posto sicuro, ad esempio un gestore di password.
                """
            )
        }
    }

    // MARK: - Sezioni

    private var inputCard: some View {
        Card(title: "Da cifrare") {
            if let input = model.input {
                FileTile(
                    name: input.name,
                    detail: input.size.map(SizeFormatter.string),
                    systemImage: "doc",
                    changeTitle: "Cambia",
                    onChange: { choosingInput = true }
                )
                .accessibilityIdentifier("encrypt.input")
            } else {
                FilePlaceholder(
                    title: "Scegli un file",
                    subtitle: "Le cartelle arrivano più avanti",
                    action: { choosingInput = true }
                )
                .accessibilityIdentifier("encrypt.chooseInput")
            }
        }
    }

    private var passwordCard: some View {
        Card(title: "Password") {
            SecretField(
                title: "Password",
                text: $model.password,
                identifier: "encrypt.password"
            )

            if !model.password.isEmpty {
                StrengthBar(assessment: model.strength)
                Divider()
                SecretField(
                    title: "Ripeti la password",
                    text: $model.passwordConfirmation,
                    identifier: "encrypt.passwordConfirmation"
                )
                if !model.passwordConfirmation.isEmpty && !model.passwordsMatch {
                    Notice(kind: .warning, text: "Le due password non coincidono.")
                }
            }

            Divider()

            if let keyfile = model.keyfile {
                FileTile(
                    name: keyfile.name,
                    detail: "Keyfile",
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: "Rimuovi",
                    onChange: { model.clearKeyfile() }
                )
                Notice(
                    kind: .warning,
                    text: "Senza questo keyfile il file non si apre, nemmeno con la password giusta. Conservalo con la stessa cura."
                )
            } else {
                Button("Aggiungi un keyfile") { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("encrypt.addKeyfile")
            }
        }
    }

    private var optionsCard: some View {
        Card {
            // Etichetta in colore normale: verde vorrebbe dire "porta
            // altrove", mentre questo pannello si apre sul posto.
            DisclosureGroup(isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    securityOption
                    Divider()
                    integrityOption
                    Divider()
                    compressionOption
                    Divider()
                    Toggle("Nascondi il nome del file", isOn: $model.hideFilename)
                    Toggle("Controllo password nel file", isOn: $model.enablePasswordCheck)
                        .accessibilityIdentifier("encrypt.passwordCheck")
                }
                .padding(.top, Design.Space.m)
                // Il tint grigio dell'intestazione si propagherebbe qui dentro,
                // spegnendo interruttori e segmenti: dentro il pannello si
                // torna al verde delle azioni.
                .tint(Design.accent)
            } label: {
                HStack(spacing: Design.Space.s) {
                    Text("Opzioni").font(.body.weight(.medium))
                    Text(optionsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.secondary)
            .foregroundStyle(Color.primary)
            .accessibilityIdentifier("encrypt.options")
        }
    }

    /// Riassunto delle scelte quando il pannello è chiuso: senza, l'unico modo
    /// di sapere con quali parametri si sta per cifrare è aprirlo.
    private var optionsSummary: String {
        let security: String
        switch model.securityProfile {
        case .standard: security = "Standard"
        case .strong: security = "Forte"
        case .paranoid: security = "Paranoico"
        }
        let integrity: String
        switch model.integrityProfile {
        case .low: integrity = "bassa"
        case .standard: integrity = "standard"
        case .high: integrity = "alta"
        case .max: integrity = "massima"
        }
        return "\(security) · resistenza \(integrity)"
    }

    private var securityOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Protezione della password")
                .font(.subheadline.weight(.medium))
            Picker("Protezione", selection: $model.securityProfile) {
                Text("Standard").tag(SecurityProfile.standard)
                Text("Forte").tag(SecurityProfile.strong)
                Text("Paranoico").tag(SecurityProfile.paranoid)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("encrypt.securityProfile")

            Text(securityDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // L'avviso memoria di SPEC §11.2. Non si abbassano i parametri di
            // nascosto: cambierebbero la chiave derivata, quindi il file.
            if !model.securityProfileFitsMemory {
                Notice(
                    kind: .danger,
                    text: "Questo profilo chiede più memoria di quanta ne sia disponibile ora. Cifrare potrebbe far chiudere l'app di colpo.",
                    identifier: "encrypt.memoryWarning"
                )
            }
        }
    }

    private var integrityOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Resistenza ai danneggiamenti")
                .font(.subheadline.weight(.medium))
            Picker("Resistenza", selection: $model.integrityProfile) {
                Text("Bassa").tag(IntegrityProfile.low)
                Text("Standard").tag(IntegrityProfile.standard)
                Text("Alta").tag(IntegrityProfile.high)
                Text("Massima").tag(IntegrityProfile.max)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("encrypt.integrityProfile")

            // Overhead e dimensione stimata insieme: la percentuale da sola non
            // dice granché, ed è con "Massima" che serve capirlo prima.
            Text(integrityDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("encrypt.sizeEstimate")
        }
    }

    private var compressionOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Compressione")
                .font(.subheadline.weight(.medium))
            Picker("Compressione", selection: $model.payloadCompression) {
                Text("Nessuna").tag(PayloadCompression.none)
                Text("Zlib").tag(PayloadCompression.zlib)
                Text("LZMA").tag(PayloadCompression.lzma)
            }
            .pickerStyle(.segmented)
            Text("LZMA comprime di più ed è più lenta. Su file già compressi — foto, video, archivi — nessuna delle due aiuta.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    identifierPrefix: "encrypt"
                )
            } else {
                PrimaryButton(
                    title: "Cifra",
                    systemImage: "lock",
                    enabled: model.canRun,
                    identifier: "encrypt.run"
                ) {
                    if acknowledged {
                        Task { await run() }
                    } else {
                        askingIrreversibility = true
                    }
                }
                if let reason = model.blockingReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("encrypt.blockingReason")
                }
            }
        }
    }

    private func resultCard(_ output: EncryptModel.Output) -> some View {
        Card(title: "Risultato") {
            Notice(
                kind: .success,
                text: "File cifrato.",
                identifier: "encrypt.outcome.success"
            )
            FileTile(
                name: output.name,
                detail: SizeFormatter.string(output.meta.storedSize),
                systemImage: "lock.doc",
                tint: Design.accent
            )
            .accessibilityIdentifier("encrypt.output")

            MetadataRow(label: "Formato", value: "ECF1 v\(output.meta.version)", monospaced: true)
            MetadataRow(
                label: "Ridondanza",
                value: "k \(output.meta.k) / r \(output.meta.r)",
                monospaced: true
            )

            PrimaryButton(title: "Salva in File", systemImage: "square.and.arrow.down", identifier: "encrypt.save") {
                exporting = true
            }
            ShareLink(item: output.url)
                .accessibilityIdentifier("encrypt.share")
        }
    }

    // MARK: - Testi derivati

    /// Memoria e passaggi vengono da Rust; il rapporto è aritmetica su quei
    /// numeri. Non si dichiara un tempo in secondi: dipenderebbe dal
    /// dispositivo e sarebbe inventato.
    private var securityDescription: String {
        let params = securityProfileParams(profile: model.securityProfile)
        let standard = securityProfileParams(profile: .standard)
        let work = Double(params.timeCost) * Double(params.memoryKib)
        let reference = Double(standard.timeCost) * Double(standard.memoryKib)
        let ratio = reference > 0 ? work / reference : 1

        var text = "\(model.securityProfileMemory) di memoria, \(params.timeCost) passaggi"
        if ratio > 1.5 {
            text += " — circa \(Int(ratio.rounded()))× più lento del profilo Standard"
        }
        return text + "."
    }

    private var integrityDescription: String {
        var text = "Aggiunge circa \(model.integrityOverheadPercent)% di dati di recupero"
        if let estimate = model.estimatedOutputSize {
            text += ", per un file di circa \(estimate)"
        }
        text += ". Più dati di recupero significa sopravvivere a più danni."
        if model.payloadCompression != .none {
            text += " Con la compressione attiva il risultato sarà più piccolo."
        }
        return text
    }

    private func run() async {
        await model.run()
        // La password non serve più: si accorcia la sua vita in memoria per
        // quel che Swift permette (SPEC §12.1).
        if model.output != nil { model.clearPasswords() }
    }
}
