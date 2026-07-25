import XCTest
import SwiftUI
@testable import Cryptera

/// Contrasto dei colori del design system, misurato invece che valutato a occhio.
///
/// `performAccessibilityAudit()` nei UI test segnala il contrasto insufficiente,
/// ma lo fa **una schermata alla volta e solo dove quel colore compare**: un
/// colore usato in un punto non ancora coperto passerebbe inosservato, e il
/// rilievo arriva senza un numero con cui decidere di quanto correggere.
///
/// Qui i colori si misurano alla sorgente, in entrambi i temi, con la formula
/// WCAG 2.1. È anche il motivo per cui i valori dell'upstream non si possono
/// copiare senza verificarli: `ui/styles.css` è pensato per pannelli scuri, e
/// sul fondo chiaro di iOS lo stesso verde non regge.
final class DesignSystemContrastTests: XCTestCase {

    // MARK: - WCAG 2.1

    /// Luminanza relativa (WCAG 2.1, §Relative luminance).
    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Rapporto di contrasto fra due colori già risolti.
    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        let (hi, lo) = la > lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func resolve(
        _ color: Color,
        _ style: UIUserInterfaceStyle,
        _ contrast: UIAccessibilityContrast = .normal
    ) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        })
    }

    /// Sovrappone `foreground` a `background` rispettandone l'alfa.
    ///
    /// Serve per i colori semantici di sistema: `secondaryLabel` non è un
    /// grigio pieno ma un nero al 60%, e misurarne le componenti ignorando
    /// l'alfa darebbe il contrasto di un colore che sullo schermo non compare
    /// mai — cioè un risultato sbagliato e per giunta ottimista.
    private func composite(_ foreground: UIColor, over background: UIColor) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        foreground.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: fr * fa + br * (1 - fa),
            green: fg * fa + bg * (1 - fa),
            blue: fb * fa + bb * (1 - fa),
            alpha: 1
        )
    }

    /// Verifica un accostamento in **entrambi** i temi.
    ///
    /// Il tema scuro non è il caso facile per costruzione: lo è per questi
    /// colori, che nascono su fondo scuro. È il chiaro a rompersi, ed è la
    /// ragione per cui misurarli solo dove si sviluppa non basta.
    private func assertContrast(
        _ foreground: Color,
        on background: Color,
        atLeast minimum: Double,
        _ what: String,
        contrast accessibilityContrast: UIAccessibilityContrast = .normal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let nome = style == .light ? "chiaro" : "scuro"
            let sfondo = resolve(background, style, accessibilityContrast)
            let ratio = contrast(
                composite(resolve(foreground, style, accessibilityContrast), over: sfondo),
                sfondo
            )
            XCTAssertGreaterThanOrEqual(
                ratio, minimum,
                String(
                    format: "%@ (tema %@): %.2f:1, servono %.1f:1",
                    what, nome, ratio, minimum
                ),
                file: file, line: line
            )
        }
    }

    // MARK: - Soglie WCAG 2.1 AA

    /// Testo normale.
    private let testo = 4.5
    /// Testo grande (≥18pt, oppure ≥14pt in grassetto) ed elementi di interfaccia.
    private let testoGrande = 3.0

    // MARK: - Testo colorato sulle superfici dell'app

    func testAccentoLeggibileComeTestoSulleCard() {
        // È il caso di "Vedi il registro": un NavigationLink prende il tint
        // dell'app, quindi l'accento diventa testo piccolo su una card.
        assertContrast(Design.accent, on: Design.cardBackground, atLeast: testo,
                       "accento come testo su card")
        assertContrast(Design.accent, on: Design.pageBackground, atLeast: testo,
                       "accento come testo su pagina")
    }

    /// In `Notice` questi colori tingono **l'icona e un fondo al 10%**, mentre
    /// il testo resta del colore primario. La soglia applicabile è quindi
    /// quella degli elementi grafici (3:1), non quella del testo: chiedere 4,5
    /// qui significherebbe scurire tre colori per un problema che non esiste.
    func testColoriDiStatoLeggibiliComeIcone() {
        assertContrast(Design.info, on: Design.cardBackground, atLeast: testoGrande,
                       "icona info su card")
        assertContrast(Design.warning, on: Design.cardBackground, atLeast: testoGrande,
                       "icona avviso su card")
        assertContrast(Design.danger, on: Design.cardBackground, atLeast: testoGrande,
                       "icona errore su card")
    }

    /// Il testo secondario è il più diffuso dell'app — sottotitoli, note in
    /// fondo alle card, dettagli dei file — ed è quello che l'audit segnala in
    /// modo incoerente, perché il rilievo cambia a seconda che la nota stia su
    /// una card o sullo sfondo della pagina.
    ///
    /// **Non lo sostituiamo con un grigio nostro.** A contrasto normale
    /// `secondaryLabel` sta sotto il 4,5:1 (3,4:1 su card): è la gerarchia che
    /// Apple ha scelto per il testo di supporto, la stessa in ogni app di
    /// sistema, e rimpiazzarla darebbe un'app che ignora l'impostazione
    /// dell'utente invece di rispettarla.
    ///
    /// Il punto è che quell'impostazione **esiste**: chi ha bisogno di più
    /// contrasto attiva "Aumenta contrasto", e i colori semantici si scuriscono
    /// da soli. Il test verifica proprio questo — che il testo di supporto resti
    /// distinguibile a contrasto normale, e che superi la soglia del testo
    /// quando il contrasto elevato è attivo. È anche la ragione per cui i
    /// colori dell'app sono semantici e non grigi fissi: un grigio fisso non
    /// reagirebbe.
    func testTestoSecondarioSegueLaSceltaDellUtente() {
        for superficie in [(Design.cardBackground, "card"), (Design.pageBackground, "pagina")] {
            assertContrast(Color(.secondaryLabel), on: superficie.0, atLeast: testoGrande,
                           "testo secondario su \(superficie.1), contrasto normale")
            assertContrast(Color(.secondaryLabel), on: superficie.0, atLeast: testo,
                           "testo secondario su \(superficie.1), contrasto elevato",
                           contrast: .high)
        }
    }

    // MARK: - Testo sopra un riempimento colorato

    func testEtichettaDelPulsantePrincipaleLeggibile() {
        // Il pulsante principale riempie con l'accento e ci scrive sopra: qui
        // l'accento è sfondo, non testo, e il rapporto va calcolato nell'altro
        // verso. `.body.weight(.semibold)` è 17pt in grassetto, quindi "testo
        // grande".
        //
        // È il caso che il solo tema chiaro non avrebbe rivelato: nel tema
        // scuro l'accento è **più chiaro**, e un'etichetta bianca ci sparisce
        // sopra. Per questo l'etichetta è `onAccent` e non `.white`.
        assertContrast(Design.onAccent, on: Design.accent, atLeast: testoGrande,
                       "etichetta del pulsante principale")
    }
}
