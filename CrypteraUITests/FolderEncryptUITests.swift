import XCTest

/// La schermata Cifra con una **cartella** scelta (M6).
///
/// Le cartelle non si possono mettere nel bundle come le fixture, e il selettore
/// di sistema non è pilotabile: l'argomento di lancio `-cifra-cartella` ne
/// costruisce una e la consegna alla schermata, passando dallo stesso percorso
/// di una scelta reale.
final class FolderEncryptUITests: XCTestCase {

    private let strongPassword = "Abcdefgh1!"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-cifra-cartella",
            "-appLanguage", "english",
            "-irreversibilityAcknowledged", "YES",
        ]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Una cartella mostra quanto contiene, non solo il nome: la dimensione da
    /// sola non dice quanto lavoro sarà.
    func testUnaCartellaMostraQuantiFileContiene() {
        let app = launch()

        let input = element(app, "encrypt.input")
        XCTAssertTrue(input.waitForExistence(timeout: 15), "la cartella non è arrivata alla schermata")
        XCTAssertTrue(input.label.contains("cartella-di-prova"))
        XCTAssertTrue(
            input.label.contains("2 files"),
            "atteso il conteggio dei file, ottenuto: \(input.label)"
        )
    }

    /// Con una cartella si sceglie la compressione **dell'archivio**, non del
    /// payload: sono due cose diverse e mostrarle entrambe confonderebbe.
    func testConUnaCartellaCompaionoLeOpzioniDArchivio() {
        let app = launch()

        let options = element(app, "encrypt.options")
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        options.tap()

        XCTAssertTrue(
            app.staticTexts["Archive compression"].waitForExistence(timeout: 10),
            "manca la compressione dell'archivio"
        )

        // Il pannello aperto è più alto dello schermo: gli interruttori in fondo
        // entrano nell'albero solo dopo aver scorso.
        app.swipeUp()
        XCTAssertTrue(
            element(app, "encrypt.skipSpecial").waitForExistence(timeout: 10),
            "salta i file speciali riguarda solo le cartelle e deve comparire qui"
        )
        // Le opzioni dell'upstream, con il compromesso nell'etichetta.
        XCTAssertTrue(app.buttons["Gzip (fast)"].exists || app.staticTexts["Gzip (fast)"].exists)
    }

    func testCifraturaDiUnaCartellaProduceUnEcf() {
        let app = launch()

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
            element(app, "encrypt.outcome.success").waitForExistence(timeout: 120),
            "la cifratura della cartella non ha prodotto un risultato"
        )
        XCTAssertTrue(
            element(app, "encrypt.output").label.contains("cartella-di-prova.ecf"),
            "ottenuto: \(element(app, "encrypt.output").label)"
        )
    }
}
