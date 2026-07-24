import SwiftUI

/// Schermata Encrypt (SPEC §8.2).
///
/// L'ordine delle sezioni è l'ordine delle decisioni: cosa cifrare, con quale
/// password, con quali parametri. Le opzioni restano chiuse — hanno buoni valori
/// predefiniti, modificabili nelle impostazioni, e aprirle in faccia a chi vuole
/// solo cifrare un file trasformerebbe un gesto semplice in un modulo da
/// compilare.
struct EncryptView: View {
    let router: AppRouter

    /// Cosa si sta scegliendo. **Un solo `.fileImporter`** serve entrambi i
    /// pulsanti: due, sulla stessa view, entrerebbero in conflitto e uno dei due
    /// non aprirebbe nulla — è già successo.
    private enum Picking {
        case file
        case folder
    }

    @State private var model = EncryptModel()
    @State private var picking: Picking?
    @State private var choosingKeyfile = false
    @State private var exporting = false
    @State private var optionsExpanded = false
    @State private var askingIrreversibility = false

    /// L'avviso di irreversibilità si mostra **una volta sola**, come sul
    /// desktop (`warning.js`, chiave in `localStorage`). Ripeterlo a ogni
    /// cifratura lo trasformerebbe in un ostacolo da chiudere senza leggere.
    /// Si può farlo ricomparire dalle impostazioni.
    @AppStorage(PreferenceKey.irreversibilityAcknowledged) private var acknowledged = false

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
            .navigationTitle(L.t("Encrypt"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ResetButton(
                        enabled: model.hasWorkInProgress && !model.isRunning,
                        confirmationMessage: model.output == nil ? nil
                            : L.t("The encrypted file has not been saved yet. It will be deleted."),
                        identifier: "encrypt.reset"
                    ) {
                        model.reset()
                    }
                }
            }
        }
        .task(id: router.pendingEncryptInput) {
            guard let pending = router.pendingEncryptInput else { return }
            await model.select(pending.url)
        }
        // I predefiniti possono essere cambiati mentre questa schermata esiste
        // già: la `TabView` la costruisce una volta sola.
        .onAppear { model.refreshDefaultsIfIdle() }
        // ⚠️ I due `.fileImporter` **non** stanno qui, ma ciascuno sulla card
        // che lo apre. Due modificatori di presentazione dello stesso tipo sulla
        // stessa view entrano in conflitto: SwiftUI ne onora uno solo e l'altro
        // non apre nulla, senza errori né avvisi. È esattamente ciò che
        // succedeva — il pulsante di scelta del file non faceva niente.
        .fileMover(isPresented: $exporting, file: model.output?.url) { result in
            if case .success = result { model.discardWork() }
        }
        .alert(L.t("There is no password recovery"), isPresented: $askingIrreversibility) {
            Button(L.t("Cancel"), role: .cancel) {}
            Button(L.t("I understand, encrypt")) {
                acknowledged = true
                Task { await run() }
            }
        } message: {
            Text(L.t("Cryptera has no backdoor and no recovery mechanism: if you forget the password — and lose the keyfile, if you use one — the encrypted data is gone for good.\n\nKeep it somewhere safe, such as a password manager."))
        }
    }

    // MARK: - Sezioni

    private var inputCard: some View {
        Card(title: L.t("To encrypt")) {
            if let input = model.input {
                FileTile(
                    name: input.name,
                    detail: inputDetail(input),
                    systemImage: input.isFolder ? "folder" : "doc",
                    changeTitle: L.t("Change"),
                    onChange: { picking = input.isFolder ? .folder : .file }
                )
                .accessibilityIdentifier("encrypt.input")
            } else {
                FilePlaceholder(
                    title: L.t("Choose a file"),
                    subtitle: L.t("Any file on this device or in iCloud"),
                    action: { picking = .file }
                )
                .accessibilityIdentifier("encrypt.chooseInput")

                Divider()

                FilePlaceholder(
                    title: L.t("Choose a folder"),
                    subtitle: L.t("Everything inside goes into a single encrypted archive"),
                    systemImage: "folder.badge.plus",
                    action: { picking = .folder }
                )
                .accessibilityIdentifier("encrypt.chooseFolder")
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { picking != nil },
                set: { if !$0 { picking = nil } }
            ),
            // Le cartelle richiedono un tipo diverso: un unico selettore che
            // cambia tipo evita di averne due sulla stessa view.
            allowedContentTypes: picking == .folder ? [.folder] : [.item]
        ) { result in
            picking = nil
            // Il tipo si rilegge dall'URL e non da cosa si stava scegliendo: il
            // selettore di sistema può sempre restituire altro.
            if case .success(let url) = result {
                Task { await model.select(url) }
            }
        }
    }

    /// Riga di dettaglio dell'input: per una cartella la dimensione da sola non
    /// dice quanto lavoro sarà, il numero di file sì.
    private func inputDetail(_ input: EncryptModel.Selection) -> String? {
        if model.isMeasuring { return L.t("Measuring…") }
        guard let size = input.size else { return nil }
        guard input.isFolder, let files = input.fileCount else {
            return SizeFormatter.string(size)
        }
        return L.t("%d files · %@", files, SizeFormatter.string(size))
    }

    private var passwordCard: some View {
        Card(title: L.t("Password")) {
            SecretField(
                title: L.t("Password"),
                text: $model.password,
                identifier: "encrypt.password"
            )

            if !model.password.isEmpty {
                StrengthBar(assessment: model.strength)
                Divider()
                SecretField(
                    title: L.t("Repeat the password"),
                    text: $model.passwordConfirmation,
                    identifier: "encrypt.passwordConfirmation"
                )
                if !model.passwordConfirmation.isEmpty && !model.passwordsMatch {
                    Notice(kind: .warning, text: L.t("The two passwords do not match."))
                }
            }

            Divider()

            if let keyfile = model.keyfile {
                FileTile(
                    name: keyfile.name,
                    detail: L.t("Keyfile"),
                    systemImage: "key",
                    tint: Design.info,
                    changeTitle: L.t("Remove"),
                    onChange: { model.clearKeyfile() }
                )
                Notice(
                    kind: .warning,
                    text: L.t("Without this keyfile the file will not open, not even with the right password. Keep it as carefully as the password.")
                )
            } else {
                Button(L.t("Add a keyfile")) { choosingKeyfile = true }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("encrypt.addKeyfile")
            }
        }
        .fileImporter(isPresented: $choosingKeyfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.selectKeyfile(url) }
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
                    if model.isFolderInput {
                        Toggle(L.t("Skip symlinks and special files"), isOn: $model.skipSpecialFiles)
                            .accessibilityIdentifier("encrypt.skipSpecial")
                    }
                    Toggle(L.t("Hide the file name"), isOn: $model.hideFilename)
                    Toggle(L.t("Password check record"), isOn: $model.enablePasswordCheck)
                        .accessibilityIdentifier("encrypt.passwordCheck")
                }
                .padding(.top, Design.Space.m)
                // Il tint grigio dell'intestazione si propagherebbe qui dentro,
                // spegnendo interruttori e segmenti: dentro il pannello si
                // torna al verde delle azioni.
                .tint(Design.accent)
            } label: {
                HStack(spacing: Design.Space.s) {
                    // L'identificatore sta sulle **foglie**, non sul
                    // `DisclosureGroup`: su un contenitore sovrascrive quelli dei
                    // discendenti, e gli interruttori qui dentro finivano tutti
                    // per chiamarsi "encrypt.options".
                    Text(L.t("Options"))
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("encrypt.options")
                    Text(optionsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("encrypt.optionsSummary")
                }
            }
            .tint(.secondary)
            .foregroundStyle(Color.primary)
        }
    }

    private var securityOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(L.t("Password protection"))
                .font(.subheadline.weight(.medium))
            Picker(L.t("Password protection"), selection: $model.securityProfile) {
                ForEach(SecurityProfile.allCases, id: \.storageValue) { profile in
                    Text(profile.label).tag(profile)
                }
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
                    text: L.t("This profile needs more memory than is available right now. Encrypting could make the app quit abruptly."),
                    identifier: "encrypt.memoryWarning"
                )
            }
        }
    }

    private var integrityOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(L.t("Damage resistance"))
                .font(.subheadline.weight(.medium))
            Picker(L.t("Damage resistance"), selection: $model.integrityProfile) {
                ForEach(IntegrityProfile.allCases, id: \.storageValue) { profile in
                    Text(profile.label).tag(profile)
                }
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

    /// Per una cartella si comprime **l'archivio**, non il payload: il TAR è
    /// già il payload, e comprimerlo due volte lo farebbe solo crescere.
    @ViewBuilder
    private var compressionOption: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(model.isFolderInput ? L.t("Archive compression") : L.t("Compression"))
                .font(.subheadline.weight(.medium))

            if model.isFolderInput {
                Picker(L.t("Archive compression"), selection: $model.archiveCompression) {
                    ForEach(ArchiveCompression.allCases, id: \.storageValue) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("encrypt.archiveCompression")
            } else {
                Picker(L.t("Compression"), selection: $model.payloadCompression) {
                    ForEach(PayloadCompression.allCases, id: \.storageValue) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(L.t("Stronger compression means a smaller file and a longer wait. On already compressed content — photos, video, archives — none of them helps."))
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
                    title: L.t("Encrypt"),
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
        Card(title: L.t("Result")) {
            Notice(
                kind: .success,
                text: L.t("File encrypted."),
                identifier: "encrypt.outcome.success"
            )
            FileTile(
                name: output.name,
                detail: SizeFormatter.string(output.meta.storedSize),
                systemImage: "lock.doc",
                tint: Design.accent
            )
            .accessibilityIdentifier("encrypt.output")

            MetadataRow(label: L.t("Format"), value: "ECF1 v\(output.meta.version)", monospaced: true)
            MetadataRow(
                label: L.t("Recovery"),
                value: L.t("%d blocks per %d", Int(output.meta.r), Int(output.meta.k))
            )

            PrimaryButton(
                title: L.t("Save to Files"),
                systemImage: "square.and.arrow.down",
                identifier: "encrypt.save"
            ) {
                exporting = true
            }
            ShareLink(item: output.url)
                .accessibilityIdentifier("encrypt.share")
        }
    }

    // MARK: - Testi derivati

    /// Riassunto delle scelte quando il pannello è chiuso: senza, l'unico modo
    /// di sapere con quali parametri si sta per cifrare è aprirlo.
    private var optionsSummary: String {
        "\(model.securityProfile.label) · \(model.integrityProfile.label)"
    }

    /// Memoria e passaggi vengono da Rust; il rapporto è aritmetica su quei
    /// numeri. Non si dichiara un tempo in secondi: dipenderebbe dal
    /// dispositivo e sarebbe inventato.
    private var securityDescription: String {
        let params = securityProfileParams(profile: model.securityProfile)
        let standard = securityProfileParams(profile: .standard)
        let work = Double(params.timeCost) * Double(params.memoryKib)
        let reference = Double(standard.timeCost) * Double(standard.memoryKib)
        let ratio = reference > 0 ? work / reference : 1

        var text = L.t("%@ of memory, %d passes", model.securityProfileMemory, Int(params.timeCost))
        if ratio > 1.5 {
            text += " " + L.t("— about %d× slower than Standard", Int(ratio.rounded()))
        }
        return text + "."
    }

    private var integrityDescription: String {
        var text = L.t("Adds about %d%% of recovery data", Int(model.integrityOverheadPercent))
        if let estimate = model.estimatedOutputSize {
            text += L.t(", for a file of about %@", estimate)
        }
        text += ". " + L.t("More recovery data means surviving more damage.")
        if model.payloadCompression != .none {
            text += " " + L.t("With compression on, the result will be smaller.")
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
