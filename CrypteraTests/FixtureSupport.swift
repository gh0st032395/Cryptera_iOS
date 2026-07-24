import XCTest
@testable import Cryptera

extension XCTestCase {
    /// Fissa la lingua dell'app per la durata del test.
    ///
    /// Senza, le asserzioni sui messaggi dipenderebbero dalla lingua del
    /// **simulatore**: verdi su una macchina italiana, rosse altrove. Si sceglie
    /// l'inglese perché è la lingua sorgente, quindi le stringhe attese sono le
    /// stesse che si leggono nel codice.
    func useEnglish() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L.languageKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: L.languageKey) }
    }
}

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
