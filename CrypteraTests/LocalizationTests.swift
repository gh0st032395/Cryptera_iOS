import XCTest
@testable import Cryptera

/// La localizzazione ha una proprietà scomoda: quando è rotta **non sembra
/// rotta**. Una chiave senza traduzione ricade sull'inglese, che è la scelta
/// giusta in produzione ma nasconde le dimenticanze.
///
/// Questi test coprono il meccanismo; che ogni chiave usata nel codice abbia una
/// traduzione lo verifica `scripts/check-localization.sh`, perché richiede di
/// leggere i sorgenti e non è esprimibile qui.
final class LocalizationTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: L.languageKey)
        super.tearDown()
    }

    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        UserDefaults.standard.set(language.rawValue, forKey: L.languageKey)
        body()
    }

    func testLIngleseELaChiaveStessa() {
        withLanguage(.english) {
            XCTAssertEqual(L.t("Encrypt"), "Encrypt")
            // Anche una chiave che non esiste da nessuna parte: in inglese non
            // c'è nulla da cercare.
            XCTAssertEqual(L.t("Chiave inventata"), "Chiave inventata")
        }
    }

    func testLItalianoTraduce() {
        withLanguage(.italian) {
            XCTAssertEqual(L.t("Encrypt"), "Cifra")
            XCTAssertEqual(L.t("Decrypt"), "Decifra")
            XCTAssertEqual(L.t("Wrong password or keyfile."), "Password o keyfile non corretti.")
        }
    }

    /// Una chiave senza traduzione non deve mostrare un identificatore
    /// all'utente: ricade sull'inglese, che resta una frase leggibile.
    func testChiaveNonTradottaRicadeSullInglese() {
        withLanguage(.italian) {
            XCTAssertEqual(L.t("An untranslated sentence"), "An untranslated sentence")
        }
    }

    /// I segnaposto posizionali devono sopravvivere alla traduzione: in italiano
    /// l'ordine delle parole cambia, e `%1$@`/`%2$d` esistono proprio per questo.
    func testSegnapostoPosizionali() {
        withLanguage(.italian) {
            XCTAssertEqual(L.t("%d blocks per %d", 8, 24), "8 blocchi ogni 24")
            XCTAssertEqual(L.t("%@ of memory, %d passes", "64 MB", 3), "64 MB di memoria, 3 passaggi")
        }
    }

    /// Gli errori passano tutti da `ErrorPresenter`: se la localizzazione non
    /// li raggiungesse, l'utente italiano leggerebbe messaggi in inglese senza
    /// che nulla fallisca.
    func testGliErroriSonoLocalizzati() {
        withLanguage(.italian) {
            XCTAssertEqual(
                ErrorPresenter.message(for: .Cancelled),
                "Operazione annullata."
            )
        }
        withLanguage(.english) {
            XCTAssertEqual(ErrorPresenter.message(for: .Cancelled), "Operation cancelled.")
        }
    }

    /// Anche le etichette dei profili, che vengono da enum di UniFFI.
    func testLeEtichetteDeiProfiliSonoLocalizzate() {
        withLanguage(.italian) {
            XCTAssertEqual(IntegrityProfile.max.label, "Massima")
            XCTAssertEqual(PayloadCompression.none.label, "Nessuna")
            // I nomi degli algoritmi non si traducono.
            XCTAssertEqual(PayloadCompression.lzma.label, "LZMA")
        }
    }

    func testIProfiliSopravvivonoAlSalvataggio() {
        for profile in SecurityProfile.allCases {
            XCTAssertEqual(SecurityProfile(storageValue: profile.storageValue), profile)
        }
        for profile in IntegrityProfile.allCases {
            XCTAssertEqual(IntegrityProfile(storageValue: profile.storageValue), profile)
        }
        for option in PayloadCompression.allCases {
            XCTAssertEqual(PayloadCompression(storageValue: option.storageValue), option)
        }
        // Un valore mai scritto, o scritto da una versione futura, non deve
        // impedire l'avvio: si ricade sul predefinito.
        XCTAssertNil(SecurityProfile(storageValue: nil))
        XCTAssertNil(SecurityProfile(storageValue: "profilo-che-non-esiste"))
    }

    /// I valori predefiniti della schermata Cifra vengono dalle impostazioni.
    func testIPredefinitiArrivanoDalleImpostazioni() {
        let defaults = UserDefaults.standard
        defaults.set(SecurityProfile.paranoid.storageValue, forKey: PreferenceKey.securityProfile)
        defaults.set(IntegrityProfile.max.storageValue, forKey: PreferenceKey.integrityProfile)
        // La compressione va **azzerata esplicitamente**: il test verifica che
        // una preferenza non impostata ricada sul valore di serie, e non può
        // dare per scontato che non lo sia. Sul simulatore appena creato è vero
        // per caso; su un iPhone davvero usato le impostazioni sopravvivono
        // nel container, e qui il test falliva leggendo la scelta dell'utente.
        // `string(forKey:)` e non `object(forKey:)`: quest'ultima restituisce
        // `Any?`, che non è `Sendable` e non può attraversare la closure di
        // teardown sotto la concorrenza rigorosa di Swift 6.
        let compressioneSalvata = defaults.string(forKey: PreferenceKey.payloadCompression)
        defaults.removeObject(forKey: PreferenceKey.payloadCompression)
        addTeardownBlock {
            defaults.removeObject(forKey: PreferenceKey.securityProfile)
            defaults.removeObject(forKey: PreferenceKey.integrityProfile)
            // Ripristinata: è una preferenza di chi usa il telefono, non del test.
            if let compressioneSalvata {
                defaults.set(compressioneSalvata, forKey: PreferenceKey.payloadCompression)
            }
        }

        let current = EncryptionDefaults.current
        XCTAssertEqual(current.securityProfile, .paranoid)
        XCTAssertEqual(current.integrityProfile, .max)
        // Non impostata: resta quella di serie.
        XCTAssertEqual(current.payloadCompression, EncryptionDefaults.builtIn.payloadCompression)
    }
}
