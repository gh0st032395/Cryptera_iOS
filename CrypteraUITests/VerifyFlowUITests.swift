import XCTest

/// Guida davvero la schermata Verify — criterio di uscita di M3 (SPEC §15).
///
/// Gli XCTest unitari esercitano `CrypteraEngine`, non la UI: un errore di
/// cablaggio fra vista e motore (binding sbagliato, stato non aggiornato,
/// risultato mai mostrato) passerebbe inosservato. Questo test copre proprio
/// quel tratto.
final class VerifyFlowUITests: XCTestCase {

    /// Password con cui sono state generate le fixture dell'upstream.
    private let fixturePassword = "FixtureP@ssw0rd42"

    override func setUp() {
        continueAfterFailure = false
    }

    func testVerificaConPasswordCorrettaMostraEsitoPositivo() {
        let app = XCUIApplication()
        app.launch()

        let password = app.secureTextFields["verify.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), "campo password assente")
        password.tap()
        password.typeText(fixturePassword)

        app.buttons["verify.run"].tap()

        let success = app.staticTexts["verify.outcome.success"]
        XCTAssertTrue(
            success.waitForExistence(timeout: 30),
            "la verifica di una fixture valida deve riuscire"
        )
    }

    func testVerificaConPasswordSbagliataMostraErroreNonUnCrash() {
        let app = XCUIApplication()
        app.launch()

        let password = app.secureTextFields["verify.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("password-sbagliata")

        app.buttons["verify.run"].tap()

        let failure = app.staticTexts["verify.outcome.failure"]
        XCTAssertTrue(
            failure.waitForExistence(timeout: 30),
            "una password errata deve produrre un messaggio, non un crash"
        )
        // Il messaggio grezzo del core non deve mai raggiungere l'utente
        // (SPEC §10.3): niente codici né percorsi in schermata.
        let shown = failure.label
        XCTAssertFalse(shown.contains("HEADER_AUTH_FAILED"), "codice grezzo in UI: \(shown)")
        XCTAssertFalse(shown.contains("/"), "percorso in UI: \(shown)")
    }
}
