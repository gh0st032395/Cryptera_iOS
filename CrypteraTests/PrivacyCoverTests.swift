import XCTest
import SwiftUI
@testable import Cryptera

/// Quando l'interfaccia va coperta (M10, SPEC §12.3).
///
/// Verifica la **regola**, non il rendering: che iOS scatti davvero la
/// miniatura mentre la copertura è su non è osservabile da un test — l'app in
/// quel momento non è più interrogabile. Quella parte è annotata come da
/// provare a mano nel piano, e non viene spacciata per verificata qui.
final class PrivacyCoverTests: XCTestCase {

    func testSiCopreAncheInInactiveNonSoloInBackground() {
        // È il caso che conta: la miniatura per il selettore delle app viene
        // scattata mentre la scena è `.inactive`, cioè *prima* di `.background`.
        // Coprire solo in background fotograferebbe la schermata scoperta.
        XCTAssertTrue(PrivacyCoverPolicy.shouldCover(.inactive))
        XCTAssertTrue(PrivacyCoverPolicy.shouldCover(.background))
    }

    func testInPrimoPianoNonSiCopre() {
        XCTAssertFalse(
            PrivacyCoverPolicy.shouldCover(.active),
            "una copertura che resta su in primo piano rende l'app inutilizzabile"
        )
    }
}
