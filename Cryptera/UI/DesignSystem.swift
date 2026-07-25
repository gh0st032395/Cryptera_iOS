import SwiftUI

/// Fondamenta visive dell'app.
///
/// **Cosa si prende dal desktop e cosa no** (SPEC §8.4). Si prendono i *colori*,
/// perché sono l'identità di Cryptera e renderla irriconoscibile fra desktop e
/// mobile non aiuterebbe nessuno. Non si prende la *forma*: la finestra
/// 1120×740 con titlebar custom, pannelli in vetro e bordi luminosi è pensata
/// per un mouse su uno schermo grande, e riprodurla su iPhone darebbe un'app
/// che sembra un sito.
///
/// Il resto poggia sui colori semantici di sistema, così chiaro/scuro,
/// contrasto elevato e Dynamic Type funzionano senza manutenzione.
enum Design {

    // MARK: - Colori

    /// Verde Cryptera: `--accent` dell'upstream, nelle due varianti di tema.
    ///
    /// È il colore delle azioni e dello stato "riuscito".
    ///
    /// **La variante chiara è più scura di quella dell'upstream** (`#1AAB82`),
    /// e non per gusto: misurata, faceva 2,9:1 sulle card e 2,6:1 sulla pagina,
    /// sotto il 4,5:1 richiesto da WCAG AA per il testo. L'accento non è solo
    /// decorativo — `.tint` lo rende il colore di ogni link e pulsante di
    /// testo dell'app — quindi quel valore rendeva davvero meno leggibile
    /// l'interfaccia su fondo chiaro. `#0D7A5C` arriva a 4,8:1 restando lo
    /// stesso verde.
    ///
    /// Il desktop la correzione la fa già (`#35D0A1` → `#1AAB82`), solo non
    /// abbastanza per un fondo chiaro come quello di iOS: là l'accento vive
    /// quasi sempre su pannelli scuri. Le soglie sono verificate da
    /// `DesignSystemContrastTests`.
    static let accent = Color(
        light: Color(red: 0.051, green: 0.478, blue: 0.361),  // #0D7A5C
        dark: Color(red: 0.208, green: 0.816, blue: 0.631)    // #35D0A1
    )

    /// Colore da scrivere **sopra** un riempimento `accent`.
    ///
    /// Non è sempre bianco. Nel tema scuro l'accento è chiaro e brillante:
    /// un'etichetta bianca sopra fa 2,0:1, cioè sparisce. È il difetto che
    /// guardare solo il tema chiaro non fa vedere, ed è il motivo per cui
    /// questo colore esiste invece di un `.white` scritto sul pulsante.
    static let onAccent = Color(
        light: .white,
        dark: Color(red: 0.055, green: 0.078, blue: 0.106)    // #0E141B
    )

    /// Blu informativo (`--accent-2`): metadati, elementi neutri in evidenza.
    static let info = Color(
        light: Color(red: 0.157, green: 0.471, blue: 0.831),  // #2878D4
        dark: Color(red: 0.290, green: 0.659, blue: 1.000)    // #4AA8FF
    )

    /// Ambra (`--accent-3`): avvisi che non sono errori.
    static let warning = Color(
        light: Color(red: 0.769, green: 0.514, blue: 0.039),  // #C4830A
        dark: Color(red: 0.961, green: 0.690, blue: 0.298)    // #F5B04C
    )

    /// Errori e azioni distruttive: rosso di sistema, non uno nostro. È il
    /// colore che l'utente ha già imparato a leggere come "attenzione" ovunque.
    static let danger = Color.red

    /// Sfondo della pagina e delle card.
    ///
    /// Semantici e non fissi: seguono da soli tema, contrasto elevato e
    /// l'aspetto delle superfici raggruppate di sistema.
    static let pageBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let separator = Color(.separator)

    // MARK: - Metriche

    /// Scala di spaziatura. Avere pochi valori fissi è ciò che tiene una UI
    /// allineata: le costanti sparse a occhio sono la ragione per cui le cose
    /// "quasi" combaciano.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Raggio delle card. L'upstream usa 18; 16 è più vicino al raggio delle
    /// superfici raggruppate di iOS e non stona accanto a quelle di sistema.
    static let cornerRadius: CGFloat = 16

    /// Larghezza massima del contenuto.
    ///
    /// Su iPhone non ha effetto — nessuno schermo ci arriva — e serve su iPad,
    /// dove le card si stiravano per tutti i 1200 e più punti disponibili:
    /// una riga con un'icona e due parole diventava larga quanto la finestra,
    /// con il testo a sinistra e mezzo schermo vuoto a destra. Il limite non è
    /// estetico: oltre una certa lunghezza di riga l'occhio perde il capo
    /// successivo, ed è la stessa ragione per cui iOS ha una "readable width".
    static let maxContentWidth: CGFloat = 700

    /// Lato minimo di un'area toccabile (Human Interface Guidelines).
    ///
    /// Un controllo di solo testo è alto quanto la sua riga — una ventina di
    /// punti — e resta difficile da colpire anche se si legge benissimo. Non è
    /// un problema di aspetto e non si vede guardando l'app: si vede provando
    /// a toccarlo, oppure con `performAccessibilityAudit()`, che è come è
    /// saltato fuori.
    static let minimumHitTarget: CGFloat = 44
}

extension View {
    /// Porta l'area toccabile al minimo delle HIG senza cambiare la posizione
    /// del testo.
    ///
    /// `contentShape` è la parte che conta: senza, l'area cresce ma i tocchi
    /// nello spazio aggiunto continuano a non arrivare al controllo, e il
    /// bersaglio resta grande come prima.
    func minimumHitTarget(alignment: Alignment = .leading) -> some View {
        frame(minHeight: Design.minimumHitTarget, alignment: alignment)
            .contentShape(Rectangle())
    }
}

// MARK: - Colore con varianti di tema

extension Color {
    /// Colore che cambia con il tema, senza passare da un asset catalog.
    ///
    /// Un catalogo sarebbe l'idiomatico, ma qui i valori arrivano da
    /// `ui/styles.css` dell'upstream e tenerli **nel codice, accanto al
    /// riferimento**, li rende confrontabili con la sorgente da cui vengono.
    /// In un `.xcassets` sarebbero numeri senza provenienza.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
