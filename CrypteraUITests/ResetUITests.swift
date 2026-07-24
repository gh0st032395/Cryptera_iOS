import XCTest

/// Il ripristino e il tema, che sono azioni sulla schermata intera.
///
/// Entrambi sono verificabili solo dalla vista: sui modelli il ripristino è
/// banale, e il tema non li tocca affatto.
final class ResetUITests: XCTestCase {

    private let fixturePassword = "FixtureP@ssw0rd42"

    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func testIlRipristinoSvuotaLaSchermataDecifra() {
        let app = XCUIApplication()
        app.launchArguments = ["-apri-fixture", "v4-basic", "-appLanguage", "english"]
        app.launch()

        // Stato "sporco": file aperto e password digitata.
        let password = app.secureTextFields["decrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText("qualcosa")
        XCTAssertTrue(element(app, "decrypt.input").exists)

        app.buttons["decrypt.reset"].tap()

        XCTAssertTrue(
            element(app, "decrypt.chooseInput").waitForExistence(timeout: 10),
            "dopo il ripristino deve tornare l'invito a scegliere un file"
        )
        XCTAssertFalse(element(app, "decrypt.input").exists)
        XCTAssertFalse(
            app.secureTextFields["decrypt.password"].exists,
            "senza file non c'è più nulla da sbloccare, quindi niente campo password"
        )
    }

    /// Ripristinare dopo una decifratura riuscita **cancella un file**: va
    /// chiesta conferma, altrimenti un tocco distratto butta via il risultato.
    func testIlRipristinoChiedeConfermaSeCiSonoDatiDaPerdere() {
        let app = XCUIApplication()
        app.launchArguments = ["-apri-fixture", "v4-basic", "-appLanguage", "english"]
        app.launch()

        let password = app.secureTextFields["decrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText(fixturePassword)
        app.buttons["decrypt.run"].tap()
        XCTAssertTrue(element(app, "decrypt.outcome.success").waitForExistence(timeout: 60))

        app.buttons["decrypt.reset"].tap()

        let conferma = app.buttons["Discard and start over"]
        XCTAssertTrue(
            conferma.waitForExistence(timeout: 10),
            "con un file non salvato il ripristino deve chiedere conferma"
        )
        conferma.tap()

        XCTAssertTrue(element(app, "decrypt.chooseInput").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "decrypt.outcome.success").exists)
    }

    /// Senza nulla da azzerare il pulsante resta visibile ma spento: sparire e
    /// ricomparire lo renderebbe difficile da ritrovare.
    func testIlPulsanteEspentoQuandoNonCEnullaDaAzzerare() {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english"]
        app.launch()

        let reset = app.buttons["decrypt.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 15))
        XCTAssertFalse(reset.isEnabled)
    }

    /// Il tema deve raggiungere **anche la barra delle schede**, che è UIKit
    /// sotto SwiftUI: con il solo `preferredColorScheme` restava con l'aspetto
    /// precedente finché non la si toccava, e l'app appariva metà chiara e metà
    /// scura.
    ///
    /// La barra non espone il proprio colore a XCUITest, quindi si confrontano
    /// due catture dello schermo: cambiare tema deve cambiare **qualcosa**
    /// subito, senza toccare altro.
    func testCambiareTemaAggiornaSubitoTuttaLaFinestra() {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let theme = element(app, "settings.theme")
        XCTAssertTrue(theme.waitForExistence(timeout: 10))

        // Si parte da uno stato noto: il tema resta salvato fra un'esecuzione e
        // l'altra, e senza questo il test confronterebbe scuro con scuro —
        // fallendo pur funzionando l'app. Non si può fissarlo dall'argomento di
        // lancio: quel dominio ha la precedenza e la scelta fatta qui dentro
        // verrebbe ignorata.
        theme.tap()
        app.buttons["Light"].tap()
        Thread.sleep(forTimeInterval: 1)

        let prima = XCUIScreen.main.screenshot().pngRepresentation

        element(app, "settings.theme").tap()
        app.buttons["Dark"].tap()

        // Nessun tocco su altro: si guarda solo se lo schermo è cambiato.
        let cambiato = (0..<10).contains { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return XCUIScreen.main.screenshot().pngRepresentation != prima
        }
        XCTAssertTrue(cambiato, "il tema non ha avuto effetto immediato")

        // Si rimette Sistema: il tema resta salvato fra un'esecuzione e l'altra.
        element(app, "settings.theme").tap()
        app.buttons["System"].tap()
    }
}
