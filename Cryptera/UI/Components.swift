import SwiftUI

// MARK: - Contenitori

/// Blocco di contenuto su superficie chiara/scura.
///
/// Sostituisce le `Section` di `Form`, che avrebbero dato all'app l'aspetto di
/// una schermata di Impostazioni. La struttura resta quella nativa — contenuto
/// scorrevole, superfici raggruppate, colori semantici — ma con respiro e
/// gerarchia decisi da noi.
struct Card<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Space.xs)
            }

            VStack(alignment: .leading, spacing: Design.Space.m) {
                content
            }
            .padding(Design.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.cardBackground,
                in: RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            )

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Space.xs)
            }
        }
    }
}

/// Impaginazione comune a tutte le schermate.
struct ScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Lo sfondo sta **dietro** allo scroll e ignora le safe area: applicato
        // alla `ScrollView` copre solo l'area del contenuto, e appena si
        // scorre oltre la fine compare il bianco della finestra.
        ZStack {
            Design.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Design.Space.xl) {
                    content
                }
                .padding(Design.Space.l)
                // Lo spazio in fondo evita che l'ultimo elemento resti
                // incastrato sopra la barra delle tab quando il contenuto è
                // appena più alto dello schermo.
                .padding(.bottom, Design.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

// MARK: - File

/// Riga del file scelto: icona, nome, dettaglio, azione per cambiarlo.
struct FileTile: View {
    let name: String
    var detail: String?
    var systemImage: String = "doc"
    var tint: Color = Design.accent
    var changeTitle: String?
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Design.Space.s)

            if let onChange, let changeTitle {
                Button(changeTitle, action: onChange)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
        // Nome e dettaglio sono una cosa sola per VoiceOver: leggerli come due
        // elementi separati costringerebbe a scorrere per capire di che file si
        // tratta.
        .accessibilityElement(children: .combine)
    }
}

/// Invito a scegliere un file, quando non ce n'è ancora uno.
struct FilePlaceholder: View {
    let title: String
    let subtitle: String
    var systemImage: String = "doc.badge.plus"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Design.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        Design.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Password

/// Campo password con interruttore di visibilità.
///
/// `SecureField` impedisce anche la cattura del contenuto negli screenshot
/// (SPEC §12.3): mostrare in chiaro è quindi una scelta esplicita dell'utente,
/// mai lo stato iniziale.
struct SecretField: View {
    let title: String
    @Binding var text: String
    var identifier: String?

    @State private var revealed = false

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            // L'identificatore sta sul campo vero, non sul contenitore:
            // XCUITest cerca `secureTextFields[...]`, e su un wrapper non lo
            // troverebbe.
            .accessibilityIdentifier(identifier ?? "")

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            // Grigio e non verde: il verde è il colore delle azioni della
            // schermata, e un interruttore di visibilità non compete con
            // "Cifra". Va sul pulsante, non sull'icona, perché `buttonStyle`
            // applica comunque il tint all'etichetta.
            .tint(.secondary)
            .accessibilityLabel(revealed ? L.t("Hide password") : L.t("Show password"))
        }
    }
}

/// Indicatore di robustezza: quattro segmenti più l'esito a parole.
///
/// I segmenti da soli non bastano — il colore non è leggibile da tutti, e senza
/// etichetta non si sa quanti gradini mancano.
struct StrengthBar: View {
    let assessment: PasswordStrength

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < assessment.level ? color : Color(.quaternaryLabel))
                        .frame(height: 4)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(assessment.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(color)
                if let hint = assessment.hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch assessment.level {
        case 0, 1: return Design.danger
        case 2: return Design.warning
        default: return Design.accent
        }
    }
}

// MARK: - Righe e avvisi

/// Coppia etichetta/valore. Il valore è monospaziato quando è tecnico: le cifre
/// restano allineate fra righe diverse e si confrontano a colpo d'occhio.
struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false
    var identifier: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Design.Space.m)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Riga di scelta: etichetta a sinistra, valore selezionabile a destra.
///
/// Serve perché **fuori da un `Form` SwiftUI non mostra l'etichetta di un
/// `Picker`**: resta visibile il solo valore corrente, e una schermata di
/// impostazioni diventa un elenco di parole senza sapere cosa regolino. Qui
/// l'etichetta è un `Text` vero e al picker si dice esplicitamente di nascondere
/// la propria.
struct ChoiceRow<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    var identifier: String?
    @ViewBuilder var options: Options

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer(minLength: Design.Space.m)
            // L'identificatore va sul picker, non sulla riga: su un contenitore
            // si propaga ai discendenti, e una ricerca per identificatore
            // troverebbe più elementi invece di quello da toccare.
            Picker(label, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

/// Messaggio in evidenza: informativo, di avviso o di errore.
struct Notice: View {
    enum Kind {
        case info
        case warning
        case danger
        case success

        var tint: Color {
            switch self {
            case .info: return Design.info
            case .warning: return Design.warning
            case .danger: return Design.danger
            case .success: return Design.accent
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            case .success: return "checkmark.seal.fill"
            }
        }
    }

    let kind: Kind
    let text: String
    var identifier: String?

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.m) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Design.Space.m)
        .background(
            kind.tint.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "")
    }
}

// MARK: - Azioni ed esecuzione

/// Azione principale della schermata.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var enabled = true
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Design.Space.m)
        }
        // Da disattivato resta leggibile ma non pesa: un blocco grigio pieno
        // attira l'occhio esattamente quanto quello attivo, e in una schermata
        // dove il pulsante è spento per la maggior parte del tempo è la cosa
        // sbagliata da mettere in evidenza.
        .background(
            (enabled ? Design.accent : Color(.tertiarySystemFill)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .foregroundStyle(enabled ? Color.white : Color(.tertiaryLabel))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Stato di un'operazione in corso, con pausa e annullamento.
struct RunningPanel: View {
    let progress: OperationProgress?
    let paused: Bool
    let onPause: () -> Void
    let onCancel: () -> Void
    var identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack {
                Text(progress?.stage.displayName ?? L.t("Starting"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let fraction = progress?.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Barra indeterminata quando il totale non è noto: fingere una
            // percentuale sarebbe peggio che ammettere di non saperla.
            if let fraction = progress?.fraction {
                ProgressView(value: fraction).tint(Design.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Design.accent)
            }

            HStack(spacing: Design.Space.m) {
                Button(paused ? L.t("Resume") : L.t("Pause"), action: onPause)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(identifierPrefix).pause")
                Button(L.t("Cancel"), role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(identifierPrefix).cancel")
                Spacer()
            }
        }
    }
}
