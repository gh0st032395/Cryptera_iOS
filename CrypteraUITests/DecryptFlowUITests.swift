import XCTest

/// Guida davvero la schermata Decrypt — criterio di uscita di M4.
///
/// Gli XCTest esercitano `DecryptModel`, non la vista: un errore di cablaggio
/// fra le due (binding sbagliato, risultato mai mostrato, pulsante che resta
/// disabilitato) passerebbe inosservato.
///
/// L'input entra dall'argomento di lancio `-apri-fixture`, che percorre lo
/// **stesso** codice di `.onOpenURL`: il test copre quindi anche l'apertura di
/// un `.ecf` arrivato da fuori. Il `.fileImporter` non è pilotabile — è
/// interfaccia di sistema, in un altro processo — e simularlo sarebbe un test
/// che verifica sé stesso.
final class DecryptFlowUITests: XCTestCase {

    /// Password con cui l'upstream ha generato le fixture.
    private let fixturePassword = "FixtureP@ssw0rd42"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apri-fixture", fixture]
        app.launch()
        return app
    }

    /// Un `.ecf` aperto dall'esterno deve arrivare nella schermata Decrypt già
    /// compilato, con i metadati leggibili senza password già mostrati.
    func testEcfApertoDallEsternoPrecompilaLaSchermata() {
        let app = launch(fixture: "v4-basic")

        let file = app.staticTexts["decrypt.input"]
        XCTAssertTrue(file.waitForExistence(timeout: 15), "il file aperto non è arrivato alla schermata")
        XCTAssertTrue(file.label.contains("v4-basic"))

        XCTAssertTrue(
            app.staticTexts["decrypt.meta.content"].exists,
            "i metadati devono essere leggibili prima di chiedere la password"
        )
        XCTAssertFalse(
            app.switches["decrypt.extract"].exists,
            "un file singolo non deve offrire l'estrazione dell'archivio"
        )
    }

    func testDecifraturaCompletaMostraIlNomeOriginale() {
        let app = launch(fixture: "v4-basic")

        let password = app.secureTextFields["decrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15), "campo password assente")
        password.tap()
        password.typeText(fixturePassword)

        app.buttons["decrypt.run"].tap()

        let outcome = app.staticTexts["decrypt.outcome.success"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 60), "la decifratura non ha prodotto un risultato")
        XCTAssertTrue(
            outcome.label.contains("secret-note.txt"),
            "l'output deve prendere il nome dall'header, ottenuto: \(outcome.label)"
        )
        // L'output è in chiaro: la schermata deve offrire di rimuoverlo.
        XCTAssertTrue(app.buttons["decrypt.save"].exists)
        XCTAssertTrue(app.buttons["decrypt.discard"].exists)
    }

    /// Il salvataggio apre davvero il picker di sistema, col nome giusto già
    /// proposto.
    ///
    /// Copre una regressione **già avvenuta**: la prima versione presentava un
    /// `UIDocumentPickerViewController` dentro uno `.sheet` SwiftUI, e il picker
    /// non compariva affatto — un pulsante che non faceva nulla, invisibile a
    /// qualunque test che si fermasse alla sua esistenza.
    ///
    /// Si ferma **prima** della conferma: il salvataggio vero è idempotente solo
    /// la prima volta, perché alla seconda il sistema trova un file con lo
    /// stesso nome e chiede cosa fare. Asserire oltre renderebbe l'esito
    /// dipendente da quanto c'è già sul dispositivo. Che l'output venga poi
    /// rimosso lo verifica `DecryptFlowTests`.
    ///
    /// ⚠️ Il pulsante di conferma è del picker di sistema: la sua etichetta
    /// segue la **lingua del dispositivo**, non quella dell'app. Si accettano le
    /// due lingue dell'upstream; altrove il test fallisce con questo messaggio
    /// invece di dare un verde che non dimostra nulla.
    func testIlSalvataggioApreIlPickerDiSistema() {
        let app = launch(fixture: "v4-basic")

        let password = app.secureTextFields["decrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText(fixturePassword)
        app.buttons["decrypt.run"].tap()
        XCTAssertTrue(app.staticTexts["decrypt.outcome.success"].waitForExistence(timeout: 60))

        app.buttons["decrypt.save"].tap()

        let conferma = app.buttons["Salva"].waitForExistence(timeout: 20)
            ? app.buttons["Salva"]
            : app.buttons["Save"]
        XCTAssertTrue(
            conferma.exists,
            "il picker di sistema non si è aperto (o il dispositivo non è in italiano né in inglese)"
        )
        XCTAssertTrue(
            app.staticTexts["secret-note"].exists || app.textFields["secret-note"].exists,
            "il picker deve proporre il nome originale, non quello del file cifrato"
        )
    }

    func testPasswordSbagliataMostraUnMessaggioNonUnCrash() {
        let app = launch(fixture: "v4-basic")

        let password = app.secureTextFields["decrypt.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText("password-sbagliata")

        app.buttons["decrypt.run"].tap()

        let failure = app.staticTexts["decrypt.outcome.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 60), "atteso un messaggio, non un crash")

        // SPEC §10.3: né codici grezzi né percorsi raggiungono l'utente.
        let shown = failure.label
        XCTAssertFalse(shown.contains("PASSWORD_INVALID"), "codice grezzo in UI: \(shown)")
        XCTAssertFalse(shown.contains("HEADER_AUTH_FAILED"), "codice grezzo in UI: \(shown)")
        XCTAssertFalse(shown.contains("/"), "percorso in UI: \(shown)")

        XCTAssertFalse(
            app.buttons["decrypt.save"].exists,
            "un fallimento non deve offrire il salvataggio di un output inesistente"
        )
    }
}
