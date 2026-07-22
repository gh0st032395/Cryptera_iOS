import XCTest
@testable import Cryptera

/// Verifica M2: i binding Swift generati raggiungono il core Rust e il core
/// interpreta davvero un file ECF1.
///
/// `coreVersion()` da sola dimostra solo che il binario è linkato. Leggere una
/// fixture dell'upstream dimostra che l'intera catena
/// Swift → UniFFI → cryptera-ffi → crypto_core_rs funziona.
final class EngineTests: XCTestCase {

    func testCoreVersionRaggiungeIlCore() {
        let version = coreVersion()
        XCTAssertTrue(
            version.contains("core v"),
            "coreVersion() dovrebbe riportare il tag del core, ottenuto: \(version)"
        )
    }

    func testLeggeMetadatiDaFixtureUpstream() throws {
        let url = try fixtureURL("v4-basic")
        let meta = try readMetadata(path: url.path)

        XCTAssertEqual(meta.version, 4, "v4-basic deve essere header v4")
        XCTAssertGreaterThan(meta.k, 0)
        XCTAssertGreaterThan(meta.r, 0)
        XCTAssertGreaterThanOrEqual(meta.shardSize, 1024, "shard_size sotto il minimo di FORMAT_SPEC §16.6")
    }

    func testFixtureZlibHaIlFlagDiCompressione() throws {
        let url = try fixtureURL("v4-zlib-hidden")
        let meta = try readMetadata(path: url.path)

        // FLAG_COMPRESS_ZLIB = 0x02 (SPEC §16.3)
        XCTAssertEqual(meta.flags & 0x02, 0x02, "la fixture zlib deve avere FLAG_COMPRESS_ZLIB")
    }

    func testErroreSuFileInesistenteEHTipizzato() {
        // Il mapping deve produrre un caso tipizzato, non un errore opaco:
        // è ciò che permette alla UI di mostrare la stringa localizzata
        // corretta invece del messaggio grezzo (SPEC §10.3).
        XCTAssertThrowsError(try readMetadata(path: "/nonexistent-cryptera")) { error in
            guard let err = error as? CrypteraError else {
                return XCTFail("atteso CrypteraError, ottenuto \(type(of: error))")
            }
            switch err {
            case .IoError, .HeaderInvalid:
                break
            default:
                XCTFail("errore inatteso: \(err)")
            }
        }
    }

    // MARK: - Helper

    /// Le fixture entrano nel bundle come folder reference, quindi conservano la
    /// sottocartella `Fixtures/`: senza `subdirectory` la lookup fallisce.
    ///
    /// Una fixture mancante **deve far fallire il test**, mai skipparlo: sono la
    /// base dei test di compatibilità di formato (M7), e uno skip li
    /// trasformerebbe in un verde che non dimostra nulla.
    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "ecf", subdirectory: "Fixtures")
        return try XCTUnwrap(url, "fixture \(name).ecf assente dal bundle di test")
    }
}
