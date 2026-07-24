import XCTest
@testable import Cryptera

/// Verify dopo il passaggio al document picker.
///
/// Fino a M3 questi due casi erano UI test sulla schermata a fixture. Ora
/// l'input di Verify arriva dal `.fileImporter`, che non è pilotabile da
/// XCUITest, quindi la copertura si sposta sul modello — dove peraltro passa
/// l'intera catena `FileAccess` → UniFFI → Rust → core.
@MainActor
final class VerifyFlowTests: XCTestCase {

    private let fixturePassword = "FixtureP@ssw0rd42"

    func testPasswordCorrettaDaEsitoPositivo() async throws {
        let model = VerifyModel()
        model.select(try fixtureURL("v4-basic"))
        model.password = fixturePassword
        XCTAssertTrue(model.canRun)

        await model.run()

        guard case .success(let meta) = try XCTUnwrap(model.outcome) else {
            return XCTFail("la verifica di una fixture valida deve riuscire")
        }
        XCTAssertEqual(meta.version, 4)
        XCTAssertEqual(meta.plainSize, 3000)
    }

    func testPasswordSbagliataDaUnMessaggioPresentabile() async throws {
        let model = VerifyModel()
        model.select(try fixtureURL("v4-basic"))
        model.password = "password-sbagliata"

        await model.run()

        guard case .failure(let message) = try XCTUnwrap(model.outcome) else {
            return XCTFail("atteso un fallimento")
        }
        XCTAssertFalse(message.contains("PASSWORD_INVALID"), "codice grezzo in UI: \(message)")
        XCTAssertFalse(message.contains("/"), "percorso in UI: \(message)")
    }

    func testSenzaFileNonSiPuoAvviare() {
        let model = VerifyModel()
        model.password = "qualcosa"
        XCTAssertFalse(model.canRun)
    }
}
