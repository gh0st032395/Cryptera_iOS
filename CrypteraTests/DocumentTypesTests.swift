import UniformTypeIdentifiers
import XCTest
@testable import Cryptera

/// L'integrazione con l'app File (SPEC §6.5) vive interamente nell'`Info.plist`,
/// dove un errore non produce alcun fallimento di compilazione: il `.ecf`
/// semplicemente non si apre più con Cryptera, e ce ne si accorge usando l'app.
final class DocumentTypesTests: XCTestCase {

    func testIlTipoEcfEDichiaratoNelBundle() {
        XCTAssertEqual(UTType.crypteraECF.identifier, "com.cryptera.ecf")
        XCTAssertEqual(UTType.crypteraECF.preferredFilenameExtension, "ecf")
        XCTAssertTrue(UTType.crypteraECF.conforms(to: .data))
        XCTAssertFalse(
            UTType.crypteraECF.isDynamic,
            "tipo dinamico: la dichiarazione dell'Info.plist non è stata riconosciuta"
        )
    }

    /// È ciò che rende un `.ecf` selezionabile nel picker e apribile da File:
    /// il sistema deve risolvere l'estensione **sul nostro** tipo.
    func testUnFileConEstensioneEcfRisolveSulNostroTipo() throws {
        let risolto = try XCTUnwrap(UTType(filenameExtension: "ecf"))
        XCTAssertEqual(risolto, .crypteraECF)
    }

    func testAperturaInPlaceDichiarata() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool,
            true,
            "senza questa chiave ogni apertura duplica il file in Documents/Inbox"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UISupportsDocumentBrowser") as? Bool,
            false,
            "l'app non espone il proprio container in File: vi tiene output decifrati"
        )
    }

    func testIlTipoEAssociatoAllAppComeEditor() throws {
        let tipi = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]]
        )
        let ecf = try XCTUnwrap(
            tipi.first { ($0["LSItemContentTypes"] as? [String])?.contains("com.cryptera.ecf") == true },
            "nessun CFBundleDocumentTypes associato a com.cryptera.ecf"
        )
        XCTAssertEqual(
            ecf["CFBundleTypeRole"] as? String,
            "Editor",
            "con ruolo Viewer il sistema non proporrebbe Cryptera per un .ecf"
        )
    }
}
