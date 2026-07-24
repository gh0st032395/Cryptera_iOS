import XCTest

/// Le impostazioni devono avere effetto **subito e su tutta l'app**.
///
/// È il punto fragile della localizzazione scelta: `L.t(...)` legge la lingua al
/// momento della chiamata, quindi cambiarla non invalida da sola alcuna vista.
/// L'albero viene ricostruito di proposito (`.id(language)` in `RootView`), e se
/// quel meccanismo saltasse l'impostazione sembrerebbe non funzionare pur
/// essendo salvata correttamente — un difetto che nessun test sul modello
/// vedrebbe.
final class SettingsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english"]
        app.launch()
        return app
    }

    /// ⚠️ Questo test **non** fissa la lingua con l'argomento di lancio, al
    /// contrario degli altri.
    ///
    /// Il dominio degli argomenti ha la precedenza su `UserDefaults`: con
    /// `-appLanguage` impostato, la scelta salvata dalle impostazioni verrebbe
    /// letta comunque come quella dell'argomento, e il test fallirebbe pur
    /// funzionando l'app. Le schede si raggiungono quindi per posizione, che non
    /// dipende dalla lingua.
    func testCambiareLinguaAggiornaTuttaLInterfaccia() {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15), "scheda impostazioni assente")
        settingsTab.tap()

        let language = app.descendants(matching: .any)["settings.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 10), "riga della lingua assente")
        language.tap()

        // I nomi delle lingue non si traducono: "Italiano" è "Italiano" ovunque.
        app.buttons["Italiano"].tap()

        XCTAssertTrue(
            app.tabBars.buttons["Cifra"].waitForExistence(timeout: 10),
            "le altre schermate devono seguire la lingua scelta, non solo quella corrente"
        )
        XCTAssertTrue(app.tabBars.buttons["Impostazioni"].exists)

        // Si rimette l'inglese, altrimenti l'impostazione resta salvata e le
        // esecuzioni successive partirebbero in italiano.
        app.descendants(matching: .any)["settings.language"].tap()
        app.buttons["English"].tap()
    }

    /// L'etichetta di ogni scelta deve essere visibile: fuori da un `Form`
    /// SwiftUI mostra il solo valore, e la schermata diventa un elenco di parole
    /// senza sapere cosa regolino.
    func testOgniSceltaMostraLaPropriaEtichetta() {
        let app = launch()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Language"].waitForExistence(timeout: 10))

        for label in ["Theme", "Password protection", "Damage resistance", "Compression"] {
            XCTAssertTrue(app.staticTexts[label].exists, "etichetta assente: \(label)")
        }
    }

    /// I predefiniti salvati devono arrivare alla schermata Cifra: se non ci
    /// arrivassero, l'impostazione sarebbe salvata e inerte.
    ///
    /// Il valore si inietta dal dominio degli argomenti — cioè come se fosse già
    /// stato scelto nelle impostazioni in una sessione precedente — perché è
    /// così che lo si trova nell'uso reale: salvato prima, letto all'avvio.
    func testIPredefinitiSalvatiRaggiungonoLaSchermataCifra() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-appLanguage", "english",
            "-defaultSecurityProfile", "paranoid",
            // Il pannello opzioni compare solo con un file scelto.
            "-cifra-fixture", "v4-basic",
        ]
        app.launch()

        // Il riassunto accanto a "Options" riporta i profili in uso senza dover
        // aprire il pannello.
        let summary = app.staticTexts["encrypt.optionsSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "riassunto delle opzioni assente")
        XCTAssertTrue(
            summary.label.contains("Maximum"),
            "il predefinito non è arrivato alla schermata Cifra: \(summary.label)"
        )
    }
}
