import XCTest

/// La copertura privacy non deve restare incastrata (M10, SPEC §12.3).
///
/// Che la miniatura di sistema esca coperta non è verificabile da un test:
/// nell'istante in cui iOS la scatta l'app non è più interrogabile. È
/// verificabile però il modo di fallire che rovinerebbe l'app a chiunque —
/// una copertura che non si toglie al ritorno in primo piano, lasciando
/// un'interfaccia opaca e inutilizzabile.
final class PrivacyCoverUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testLaCoperturaSpariscceAlRitornoInPrimoPiano() {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english"]
        app.launch()

        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 15), "barra delle schede assente")
        XCTAssertFalse(
            app.otherElements["privacy.cover"].exists,
            "in primo piano non deve esserci alcuna copertura"
        )

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            tabs.firstMatch.waitForExistence(timeout: 15),
            "tornando in primo piano l'interfaccia deve essere di nuovo raggiungibile"
        )
        XCTAssertFalse(
            app.otherElements["privacy.cover"].waitForExistence(timeout: 2),
            "la copertura è rimasta su: l'app resterebbe opaca e inutilizzabile"
        )

        // Raggiungibile davvero, non solo presente nell'albero.
        let ultima = tabs.element(boundBy: tabs.count - 1)
        ultima.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.language"].waitForExistence(timeout: 10),
            "dopo il ritorno in primo piano i controlli devono rispondere"
        )
    }
}
