import XCTest

/// Guida la schermata Cifra.
///
/// Come per Decrypt, il `.fileImporter` non è pilotabile — è interfaccia di
/// sistema, fuori processo — quindi l'input entra dall'argomento di lancio
/// `-cifra-fixture`. A cifrare, un `.ecf` vale come qualsiasi altro file.
final class EncryptFlowUITests: XCTestCase {

    private let strongPassword = "Abcdefgh1!"

    override func setUp() {
        continueAfterFailure = false
    }

    /// L'avviso di irreversibilità si mostra una volta sola e il consenso resta
    /// memorizzato. Il dominio degli argomenti ha la precedenza su
    /// `UserDefaults`, quindi impostarlo qui rende l'esito **deterministico**
    /// invece che dipendente da cosa ha fatto l'esecuzione precedente.
    private func launch(acknowledged: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-cifra-fixture", "v4-basic",
            "-irreversibilityAcknowledged", acknowledged ? "YES" : "NO",
            // La lingua dell'app è fissata: senza, le asserzioni sui messaggi
            // dipenderebbero dalla lingua del simulatore.
            "-appLanguage", "english",
        ]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Il pulsante resta disattivato finché la password non regge la policy, e
    /// il motivo è scritto: un pulsante spento senza spiegazione è un vicolo
    /// cieco.
    func testPasswordDeboleTieneIlPulsanteDisattivato() {
        let app = launch(acknowledged: true)

        let password = app.secureTextFields["encrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15), "campo password assente")
        password.tap()
        password.typeText("abc")

        XCTAssertFalse(app.buttons["encrypt.run"].isEnabled)
        let motivo = element(app, "encrypt.blockingReason")
        XCTAssertTrue(motivo.waitForExistence(timeout: 5))
        XCTAssertTrue(motivo.label.contains("10 characters"), "ottenuto: \(motivo.label)")
    }

    func testLAvvisoDiIrreversibilitaPrecedeLaPrimaCifratura() {
        let app = launch(acknowledged: false)

        let password = app.secureTextFields["encrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText(strongPassword)

        let conferma = app.secureTextFields["encrypt.passwordConfirmation"]
        XCTAssertTrue(conferma.waitForExistence(timeout: 5))
        conferma.tap()
        conferma.typeText(strongPassword)

        app.buttons["encrypt.run"].tap()

        let avviso = app.alerts.firstMatch
        XCTAssertTrue(
            avviso.waitForExistence(timeout: 10),
            "la prima cifratura deve avvertire che non esiste recupero password"
        )
        XCTAssertTrue(
            avviso.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("gone for good") },
            "l'avviso deve dire cosa si perde, non solo che c'è un rischio"
        )
        avviso.buttons["I understand, encrypt"].tap()

        XCTAssertTrue(
            element(app, "encrypt.outcome.success").waitForExistence(timeout: 90),
            "la cifratura non ha prodotto un risultato"
        )
        XCTAssertTrue(app.buttons["encrypt.save"].exists)
    }

    /// Con il consenso già dato l'avviso non si ripresenta: ripeterlo a ogni
    /// cifratura lo trasformerebbe in un ostacolo da chiudere senza leggere.
    func testConIlConsensoGiaDatoSiCifraSenzaAvviso() {
        let app = launch(acknowledged: true)

        let password = app.secureTextFields["encrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText(strongPassword)

        let conferma = app.secureTextFields["encrypt.passwordConfirmation"]
        XCTAssertTrue(conferma.waitForExistence(timeout: 5))
        conferma.tap()
        conferma.typeText(strongPassword)

        app.buttons["encrypt.run"].tap()

        XCTAssertTrue(
            element(app, "encrypt.outcome.success").waitForExistence(timeout: 90)
        )
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
