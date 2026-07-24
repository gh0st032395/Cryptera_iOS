import XCTest

extension XCTestCase {
    /// URL di una fixture dell'upstream nel bundle di test.
    ///
    /// Le fixture entrano come folder reference, quindi conservano la
    /// sottocartella `Fixtures/`: senza `subdirectory` la lookup fallisce.
    ///
    /// Una fixture mancante **deve far fallire il test**, mai skipparlo: sono la
    /// base dei test di compatibilità di formato (M7), e uno skip li
    /// trasformerebbe in un verde che non dimostra nulla.
    func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "ecf", subdirectory: "Fixtures")
        return try XCTUnwrap(url, "fixture \(name).ecf assente dal bundle di test")
    }
}
