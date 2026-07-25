import SwiftUI

/// Impostazioni (SPEC §8.1).
///
/// Contiene solo ciò che cambia davvero il comportamento dell'app o risponde a
/// una domanda che ci si pone usandola. Niente voci decorative: in un'app di
/// sicurezza ogni interruttore in più è una cosa in più da capire.
struct SettingsView: View {
    @AppStorage(PreferenceKey.language) private var language = AppLanguage.system.rawValue
    @AppStorage(PreferenceKey.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(PreferenceKey.securityProfile) private var securityProfile =
        EncryptionDefaults.builtIn.securityProfile.storageValue
    @AppStorage(PreferenceKey.integrityProfile) private var integrityProfile =
        EncryptionDefaults.builtIn.integrityProfile.storageValue
    @AppStorage(PreferenceKey.payloadCompression) private var payloadCompression =
        EncryptionDefaults.builtIn.payloadCompression.storageValue
    @AppStorage(PreferenceKey.irreversibilityAcknowledged) private var acknowledged = false
    @AppStorage(PreferenceKey.auditEnabled) private var auditEnabled = true

    @State private var coreVersion = "…"

    var body: some View {
        NavigationStack {
            ScreenScroll {
                appearanceCard
                defaultsCard
                warningsCard
                activityCard
                aboutCard
            }
            .navigationTitle(L.t("Settings"))
        }
        .task { coreVersion = await CrypteraEngine.shared.version() }
    }

    // MARK: - Aspetto

    private var appearanceCard: some View {
        Card(title: L.t("Appearance")) {
            ChoiceRow(label: L.t("Language"), selection: $language, identifier: "settings.language") {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }

            Divider()

            ChoiceRow(label: L.t("Theme"), selection: $theme, identifier: "settings.theme") {
                ForEach(AppTheme.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        }
    }

    // MARK: - Predefiniti

    private var defaultsCard: some View {
        Card(
            title: L.t("Encryption defaults"),
            footnote: L.t("Applied to new files. You can still change them per file before encrypting.")
        ) {
            ChoiceRow(label: L.t("Password protection"), selection: $securityProfile, identifier: "settings.securityProfile") {
                ForEach(SecurityProfile.allCases, id: \.storageValue) { profile in
                    Text(profile.label).tag(profile.storageValue)
                }
            }

            Divider()

            ChoiceRow(label: L.t("Damage resistance"), selection: $integrityProfile) {
                ForEach(IntegrityProfile.allCases, id: \.storageValue) { profile in
                    Text(profile.label).tag(profile.storageValue)
                }
            }

            Divider()

            ChoiceRow(label: L.t("Compression"), selection: $payloadCompression) {
                ForEach(PayloadCompression.allCases, id: \.storageValue) { option in
                    Text(option.label).tag(option.storageValue)
                }
            }
        }
    }

    // MARK: - Registro

    private var activityCard: some View {
        Card(
            title: L.t("Activity"),
            footnote: L.t("The log stays on this device and records only the file name, never its location.")
        ) {
            Toggle(L.t("Record operations"), isOn: $auditEnabled)
                .accessibilityIdentifier("settings.audit")

            Divider()

            NavigationLink(L.t("View the log")) { AuditLogView() }
                .font(.subheadline.weight(.medium))
                .minimumHitTarget()
                .accessibilityIdentifier("settings.viewAudit")
        }
    }

    // MARK: - Avvisi

    private var warningsCard: some View {
        Card(title: L.t("Warnings")) {
            if acknowledged {
                Text(L.t("You have confirmed you understand that a lost password cannot be recovered."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(L.t("Show the warning again")) { acknowledged = false }
                    .font(.subheadline.weight(.medium))
                    .minimumHitTarget()
                    .accessibilityIdentifier("settings.resetWarning")
            } else {
                Text(L.t("The warning about unrecoverable passwords will appear before your next encryption."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Informazioni

    private var aboutCard: some View {
        Card(title: L.t("About")) {
            MetadataRow(label: L.t("App version"), value: appVersion)
            // Il tag del core è la cosa che conta davvero quando si dubita della
            // compatibilità di un file: viene dal binario, non da una costante
            // scritta a mano qui.
            MetadataRow(label: L.t("Core"), value: coreVersion, monospaced: true)
            MetadataRow(label: L.t("Format"), value: "ECF1 v5", monospaced: true)

            Divider()

            Notice(
                kind: .info,
                text: L.t("Cryptera works entirely on this device. It makes no network requests and collects nothing.")
            )
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
