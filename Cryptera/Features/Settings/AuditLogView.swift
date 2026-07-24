import SwiftUI

/// Registro delle operazioni (SPEC §8.1, riferimento `src-tauri/src/audit.rs`).
///
/// L'upstream tiene due cose separate: un registro persistente su file e uno
/// storico volatile di 100 voci in memoria. Qui ce n'è **uno solo**, e questa
/// schermata lo mostra. Due elenchi della stessa cosa, uno dei quali sparisce
/// alla chiusura, sarebbero due posti dove cercare la stessa risposta — e con
/// l'interruttore spento lo storico volatile registrerebbe comunque, il che
/// vanificherebbe l'interruttore.
struct AuditLogView: View {
    @State private var entries: [AuditEntry] = []
    @State private var confirmingClear = false

    var body: some View {
        ScreenScroll {
            if entries.isEmpty {
                Card {
                    Text(L.t("No operations recorded yet."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("audit.empty")
                }
            } else {
                Card(
                    title: L.t("Recent operations"),
                    footnote: L.t("Only the file name is recorded, never its location.")
                ) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        row(entry)
                    }
                }

                Button(L.t("Clear the log"), role: .destructive) { confirmingClear = true }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("audit.clear")
            }
        }
        .navigationTitle(L.t("Activity"))
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = AuditLog.shared.recent() }
        .confirmationDialog(
            L.t("Clear the log?"),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(L.t("Clear"), role: .destructive) {
                AuditLog.shared.clear()
                entries = []
            }
            Button(L.t("Cancel"), role: .cancel) {}
        }
    }

    private func row(_ entry: AuditEntry) -> some View {
        HStack(spacing: Design.Space.m) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.succeeded ? Design.accent : Design.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.file)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(entry))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ entry: AuditEntry) -> String {
        var parts = [operationLabel(entry.op), entry.date.formatted(date: .abbreviated, time: .shortened)]
        if let duration = entry.durationS, duration >= 0.1 {
            parts.append(String(format: "%.1f s", duration))
        }
        // Il codice grezzo compare **solo qui**, dove serve a capire cosa è
        // andato storto mesi dopo. Nelle schermate operative resta la stringa
        // localizzata (SPEC §10.3).
        if let error = entry.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func operationLabel(_ op: String) -> String {
        switch op {
        case "encrypt": return L.t("Encrypt")
        case "decrypt": return L.t("Decrypt")
        case "verify": return L.t("Verify")
        case "batch": return L.t("Batch")
        default: return op
        }
    }
}
