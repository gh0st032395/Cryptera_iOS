import XCTest

/// Audit di accessibilità su tutte le schermate (M9).
///
/// Usa `performAccessibilityAudit()`, il controllo automatico di XCTest:
/// verifica etichette mancanti, testo tagliato ai corpi grandi, contrasto, aree
/// toccabili sotto la soglia e tratti incoerenti. Non sostituisce una prova con
/// VoiceOver acceso, ma trova la classe di difetti che sfugge guardando l'app a
/// corpo normale — che è il modo in cui il supporto ai corpi grandi si rompe
/// senza che nessuno se ne accorga.
///
/// **Va eseguito anche in italiano.** Le stesse schermate con stringhe più
/// lunghe si tagliano prima: al primo giro il rilievo "Text clipped" comparve
/// una volta in inglese e due in italiano, e la seconda riga sarebbe rimasta
/// nascosta provando solo la lingua sorgente.
final class AccessibilityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    /// Configurazioni provate. Il corpo AX5 è l'ultimo passo di Dynamic Type:
    /// se la schermata regge lì, regge ovunque sotto.
    private static let configurazioni: [(String, String, String?)] = [
        ("EN corpo normale", "english", nil),
        ("EN corpo AX5", "english", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"),
        ("IT corpo AX5", "italian", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"),
    ]

    private func launch(language: String, contentSize: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", language]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        return app
    }

    /// Le schede si raggiungono **per posizione**: legarsi ai titoli
    /// richiederebbe di fissare la lingua, e l'audit gira anche in italiano.
    private func visitEachTab(
        of app: XCUIApplication,
        _ body: (Int) throws -> Void
    ) rethrows {
        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 15), "barra delle schede assente")
        for index in 0..<tabs.count {
            tabs.element(boundBy: index).tap()
            // Senza attesa l'audit girerebbe sulla schermata precedente e
            // passerebbe per sbaglio.
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            try body(index)
        }
    }

    /// Raccoglie i rilievi non ignorati.
    ///
    /// Serve perché il controllo di concorrenza di Swift 6 non lascia catturare
    /// il caso di test dentro la closure dell'audit: i fallimenti si accumulano
    /// qui e si segnalano dopo, fuori dalla closure.
    private final class Rilievi: @unchecked Sendable {
        private let lock = NSLock()
        private var voci: [String] = []

        func aggiungi(_ voce: String) {
            lock.lock(); defer { lock.unlock() }
            voci.append(voce)
        }

        var tutti: [String] {
            lock.lock(); defer { lock.unlock() }
            return voci
        }
    }

    /// Decide se un rilievo va ignorato, e **perché**.
    ///
    /// L'unica esclusione è stata ricavata sperimentalmente, non assunta: gli
    /// stessi colori danno esiti diversi a seconda di dove e su cosa la
    /// schermata viene disegnata.
    private static func daIgnorare(
        _ issue: XCUIAccessibilityAuditIssue,
        dove: String,
        raccolta: Rilievi
    ) -> Bool {
        let descrizione = issue.compactDescription

        // Il **contrasto** non si giudica qui, si misura in
        // `DesignSystemContrastTests`.
        //
        // Questo controllo campiona i pixel di uno screenshot, e il risultato
        // dipende da dove e come la schermata è disegnata. Due prove lo mostrano:
        //
        //   * scorrendo fino in fondo alle Impostazioni, tre "Contrast failed"
        //     in cima diventavano "nearly passed" o sparivano — erano elementi
        //     oltre il bordo, presenti nell'albero ma non renderizzati;
        //   * gli stessi identici colori danno "nearly passed" in simulatore e
        //     "Contrast failed" su iPhone, perché cambia lo spazio colore con
        //     cui la schermata viene catturata.
        //
        // Un test che passa o fallisce a seconda dell'hardware non dice niente
        // sul codice. `DesignSystemContrastTests` calcola invece il rapporto
        // WCAG dai valori dei colori, in entrambi i temi, e copre gli stessi
        // casi — compreso quello che l'audit aveva trovato per primo, l'accento
        // usato come testo. Lì un numero sbagliato resta sbagliato ovunque.
        //
        // Tutto il resto continua a far fallire: testo tagliato, aree toccabili
        // troppo piccole, etichette ed elementi mancanti sono proprietà
        // geometriche o strutturali, stabili fra simulatore e device — e sono i
        // rilievi che hanno trovato i difetti veri di M9.
        if descrizione.localizedCaseInsensitiveContains("contrast") {
            return true
        }

        // "Potentially inaccessible text" — rilievo non azionabile, e verificato
        // infondato per quanto è possibile verificarlo.
        //
        // Nasce dall'analisi dell'immagine, non dall'albero: `element` è nil e
        // non c'è né frame né testo, quindi l'API non dice *cosa* segnala.
        // Compare solo su device e solo nelle Impostazioni. Il dump completo
        // dell'albero di quella schermata su iPhone mostra che ogni testo
        // visibile **ha** il suo elemento — intestazioni, etichette, i menu
        // (esposti come `'Language, English'`), gli interruttori e la barra
        // schede — quindi non esiste il testo non rappresentato che il rilievo
        // descrive.
        //
        // Non viene silenziato perché scomodo: viene silenziato perché un test
        // che fallisce senza indicare su cosa intervenire insegna solo a
        // ignorare i fallimenti. La domanda che pone — "un lettore di schermo
        // arriva a tutto?" — resta aperta e va chiusa dove si può davvero
        // rispondere: la prova con VoiceOver acceso su device, che è in M10.
        if descrizione.localizedCaseInsensitiveContains("inaccessible text") {
            return true
        }

        // `detailedDescription` va sempre incluso: alcuni rilievi arrivano
        // dall'analisi dello screenshot e non da un elemento dell'albero, quindi
        // `element` è nil e senza il dettaglio non c'è modo di sapere *cosa*
        // sia stato segnalato.
        let elemento = issue.element
        raccolta.aggiungi(
            """
            [\(dove)] \(descrizione)
                elemento: \(elemento?.label ?? "(nessuno)") \
            tipo=\(elemento?.elementType.rawValue.description ?? "-") \
            frame=\(elemento.map { "\($0.frame)" } ?? "-")
                dettaglio: \(issue.detailedDescription)
            """
        )
        return true  // raccolto sopra: si segnala in blocco a fine giro
    }

    func testNessunRilievoDiAccessibilitaSulleSchermate() throws {
        let raccolta = Rilievi()

        for (etichetta, lingua, corpo) in Self.configurazioni {
            let app = launch(language: lingua, contentSize: corpo)
            try visitEachTab(of: app) { index in
                let dove = "\(etichetta), scheda \(index)"
                try app.performAccessibilityAudit { issue in
                    Self.daIgnorare(issue, dove: dove, raccolta: raccolta)
                }
            }
            app.terminate()
        }

        let problemi = raccolta.tutti
        XCTAssertTrue(
            problemi.isEmpty,
            "rilievi di accessibilità:\n" + problemi.joined(separator: "\n")
        )
    }
}
