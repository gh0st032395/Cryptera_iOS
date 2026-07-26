import SwiftUI

/// Quando coprire l'interfaccia (SPEC §12.3).
///
/// Estratta come regola verificabile invece di restare un `if` dentro la vista:
/// il comportamento visivo — che iOS scatti la miniatura nel momento giusto —
/// non è verificabile da un test, ma *quando* decidiamo di coprire sì.
enum PrivacyCoverPolicy {
    /// Si copre in **tutto** ciò che non è `.active`, non solo in `.background`.
    ///
    /// La miniatura che iOS conserva per il selettore delle app viene scattata
    /// mentre la scena è `.inactive`, cioè *prima* di `.background`: coprire
    /// solo in background significherebbe fotografare la schermata scoperta e
    /// accorgersene mai, perché l'app a quel punto è già sparita dallo schermo.
    static func shouldCover(_ phase: ScenePhase) -> Bool {
        phase != .active
    }
}

/// Schermata neutra sovrapposta quando l'app lascia il primo piano.
///
/// Non protegge un segreto crittografico: protegge i **nomi dei file**. La
/// miniatura che iOS conserva per il selettore delle app resta su disco e
/// finisce nei backup, e una schermata di Cryptera mostra come si chiama ciò
/// che l'utente sta cifrando — che per chi cifra è già l'informazione di
/// troppo.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            // Opaca e oltre le safe area: una copertura che lascia scoperta la
            // striscia sotto la barra di stato non copre niente.
            Design.pageBackground
                .ignoresSafeArea()

            VStack(spacing: Design.Space.m) {
                // Cartella e non lucchetto: è lo stesso glifo dell'icona, e
                // per la stessa ragione — Cryptera cifra file e cartelle, non
                // custodisce credenziali, e il lucchetto sposta la percezione
                // verso i gestori di password.
                Image(systemName: "folder.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Design.accent)
                Text("Cryptera")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        // Un solo elemento per VoiceOver, e nessun contenuto reale esposto:
        // l'albero di accessibilità è leggibile anche quando lo schermo non lo è.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cryptera")
        .accessibilityIdentifier("privacy.cover")
    }
}
