import XCTest

/// La schermata Batch e il registro (M8).
///
/// La coda si riempie dal `.fileImporter`, che non è pilotabile: questi test
/// coprono ciò che si può guidare — la presenza della scheda, lo stato iniziale,
/// e il registro nelle impostazioni. La decifratura in blocco vera è verificata
/// da `BatchFlowTests` sul modello.
final class BatchUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// A coda vuota non compaiono né password né esecuzione: non c'è ancora
    /// niente su cui agire.
    func testACodaVuotaCompareSoloLInvitoAdAggiungere() {
        let app = launch()

        app.tabBars.buttons["Batch"].tap()

        XCTAssertTrue(
            element(app, "batch.add").waitForExistence(timeout: 15),
            "manca l'invito ad aggiungere file"
        )
        XCTAssertFalse(app.secureTextFields["batch.password"].exists)
        XCTAssertFalse(app.buttons["batch.run"].exists)
        XCTAssertFalse(app.buttons["batch.reset"].isEnabled)
    }

    /// Il selettore multiplo deve aprirsi davvero: è la stessa classe di
    /// difetto già trovata sulle altre schermate.
    func testLAggiuntaApreIlSelettoreDiSistema() {
        let app = launch()

        app.tabBars.buttons["Batch"].tap()
        element(app, "batch.add").tap()

        XCTAssertTrue(
            app.buttons["Annulla"].waitForExistence(timeout: 15)
                || app.buttons["Cancel"].waitForExistence(timeout: 3),
            "il selettore di sistema non si è aperto"
        )
    }

    /// Il registro è raggiungibile e, se non si è fatto nulla, lo dice.
    func testIlRegistroSiApreDalleImpostazioni() {
        let app = launch()

        app.tabBars.buttons["Settings"].tap()
        let link = element(app, "settings.viewAudit")
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()

        XCTAssertTrue(
            app.navigationBars["Activity"].waitForExistence(timeout: 10),
            "la schermata del registro non si è aperta"
        )
    }

    /// L'interruttore della registrazione esiste ed è acceso di serie, come sul
    /// desktop.
    func testLaRegistrazioneEAttivaDiSerie() {
        let app = launch()

        app.tabBars.buttons["Settings"].tap()
        let toggle = element(app, "settings.audit")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "1", "la registrazione deve essere attiva di serie")
    }
}
