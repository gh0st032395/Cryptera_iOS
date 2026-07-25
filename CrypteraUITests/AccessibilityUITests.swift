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
    /// Le due esclusioni sono state ricavate sperimentalmente, non assunte:
    /// portando in vista gli elementi segnalati, i rilievi di contrasto
    /// cambiavano o sparivano.
    private static func daIgnorare(
        _ issue: XCUIAccessibilityAuditIssue,
        schermo: CGRect,
        dove: String,
        raccolta: Rilievi
    ) -> Bool {
        let descrizione = issue.compactDescription

        // 1. Contrasto su elementi fuori dallo schermo. Dentro una ScrollView
        //    il contenuto oltre il bordo esiste nell'albero ma non è disegnato,
        //    e il controllo del contrasto campiona i pixel: su un elemento non
        //    renderizzato misura uno sfondo che non c'è. Verificato scorrendo
        //    fino in fondo alle Impostazioni — tre "Contrast failed" in cima
        //    diventavano "nearly passed" o sparivano una volta in vista.
        //
        //    L'esclusione vale **solo per il contrasto**: il testo tagliato e
        //    l'area toccabile sono proprietà geometriche, che non dipendono dal
        //    fatto che l'elemento sia disegnato. Ignorarle anche lì lascerebbe
        //    passare un'etichetta troncata sotto la piega — cioè metà delle
        //    Impostazioni.
        let riguardaIlContrasto = descrizione.localizedCaseInsensitiveContains("contrast")
        if riguardaIlContrasto,
           let frame = issue.element?.frame,
           !schermo.intersects(frame) {
            return true
        }

        // 2. "Contrast nearly passed" sul testo secondario. È la gerarchia
        //    scelta da Apple per il testo di supporto (`secondaryLabel` sta
        //    sotto il 4,5:1 a contrasto normale in ogni app di sistema), e si
        //    scurisce da sola quando l'utente attiva "Aumenta contrasto".
        //    Sostituirla con un grigio nostro darebbe un'app che ignora quella
        //    impostazione. Il comportamento è verificato con numeri esatti in
        //    `DesignSystemContrastTests`, che è il posto giusto per misurarlo:
        //    qui si controlla che non ci siano fallimenti veri.
        if descrizione.localizedCaseInsensitiveContains("nearly passed") {
            return true
        }

        raccolta.aggiungi("[\(dove)] \(descrizione) — elemento: \(issue.element?.label ?? "?")")
        return true  // raccolto sopra: si segnala in blocco a fine giro
    }

    func testNessunRilievoDiAccessibilitaSulleSchermate() throws {
        let raccolta = Rilievi()

        for (etichetta, lingua, corpo) in Self.configurazioni {
            let app = launch(language: lingua, contentSize: corpo)
            let schermo = app.frame
            try visitEachTab(of: app) { index in
                let dove = "\(etichetta), scheda \(index)"
                try app.performAccessibilityAudit { issue in
                    Self.daIgnorare(issue, schermo: schermo, dove: dove, raccolta: raccolta)
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
