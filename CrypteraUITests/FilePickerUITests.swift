import XCTest

/// Ogni schermata apre davvero il proprio selettore di file.
///
/// Copre una regressione **già avvenuta e sfuggita a tutta la suite**: due
/// `.fileImporter` applicati alla stessa view entrano in conflitto, SwiftUI ne
/// onora uno solo e l'altro non apre nulla — senza errori, senza avvisi. Il
/// pulsante che sceglie il file non faceva niente, su tutte e tre le schermate.
///
/// Nessun test se ne accorgeva perché tutti iniettano il file dall'argomento di
/// lancio, che è il solo modo di pilotare un input che altrimenti passa da
/// un'interfaccia di sistema. Quella scorciatoia salta esattamente il pezzo che
/// si era rotto: da qui in avanti questi test lo attraversano.
///
/// ⚠️ Il selettore è di sistema: il suo pulsante di chiusura segue la **lingua
/// del dispositivo**, non quella dell'app. Si accettano le due lingue
/// dell'upstream; altrove il test fallisce con un messaggio esplicito invece di
/// dare un verde che non dimostra nulla.
final class FilePickerUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func pickerAppeared(_ app: XCUIApplication) -> Bool {
        app.buttons["Annulla"].waitForExistence(timeout: 15)
            || app.buttons["Cancel"].waitForExistence(timeout: 3)
    }

    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(identifier) non è comparso")
        element.tap()
    }

    func testDecryptApreIlSelettore() {
        let app = XCUIApplication()
        app.launch()

        tap(app, "decrypt.chooseInput")

        XCTAssertTrue(
            pickerAppeared(app),
            "il pulsante di scelta del file non ha aperto il selettore di sistema"
        )
    }

    func testVerifyApreIlSelettore() {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Verifica"].tap()
        tap(app, "verify.chooseInput")

        XCTAssertTrue(pickerAppeared(app), "il selettore non si è aperto in Verifica")
    }

    func testEncryptApreIlSelettore() {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Cifra"].tap()
        tap(app, "encrypt.chooseInput")

        XCTAssertTrue(pickerAppeared(app), "il selettore non si è aperto in Cifra")
    }

    /// Il caso che ha prodotto il difetto: **due** selettori sulla stessa
    /// schermata. Con entrambi attaccati alla stessa view ne funzionava uno
    /// solo, quindi non basta verificarne uno per schermata.
    func testEncryptApreAncheIlSelettoreDelKeyfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-cifra-fixture", "v4-basic"]
        app.launch()

        tap(app, "encrypt.addKeyfile")

        XCTAssertTrue(
            pickerAppeared(app),
            "il secondo selettore della schermata non si è aperto"
        )
    }
}
