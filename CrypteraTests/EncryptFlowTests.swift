import XCTest
@testable import Cryptera

/// Percorso di M5 al livello del modello, fino al round-trip con Decrypt.
@MainActor
final class EncryptFlowTests: XCTestCase {

    private let strongPassword = "Abcdefgh1!"

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    private func fileDiProva(_ contenuto: String = "contenuto di prova") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorgente-\(UUID().uuidString).txt")
        try Data(contenuto.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Il giro completo: si cifra dalla schermata Cifra e si ridecifra da
    /// quella Decifra. È il test che dimostra che le due schermate parlano
    /// davvero dello stesso file.
    func testRoundTripFraLeDueSchermate() async throws {
        let contenuto = "un segreto che deve tornare identico"
        let model = EncryptModel()
        await model.select(try fileDiProva(contenuto))
        model.password = strongPassword
        model.passwordConfirmation = strongPassword

        XCTAssertNil(model.blockingReason)
        await model.run()

        XCTAssertNil(model.errorMessage)
        let cifrato = try XCTUnwrap(model.output)
        XCTAssertTrue(cifrato.name.hasSuffix(".ecf"))
        XCTAssertEqual(cifrato.meta.version, 5, "il writer corrente produce header v5")

        let decrypt = DecryptModel()
        await decrypt.select(cifrato.url)
        decrypt.password = strongPassword
        await decrypt.run()

        XCTAssertNil(decrypt.errorMessage)
        let uscita = try XCTUnwrap(decrypt.output)
        XCTAssertEqual(try String(contentsOf: uscita.url, encoding: .utf8), contenuto)

        decrypt.discardWork()
        model.discardWork()
    }

    /// La policy del desktop **blocca** la cifratura, non avvisa soltanto.
    func testPasswordDeboleImpedisceLaCifratura() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())

        model.password = "abc"
        model.passwordConfirmation = "abc"
        XCTAssertFalse(model.canRun)
        let motivo = try XCTUnwrap(model.blockingReason)
        XCTAssertTrue(motivo.contains("10 characters"), "ottenuto: \(motivo)")

        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        XCTAssertTrue(model.canRun)
    }

    func testConfermaDiversaImpedisceLaCifratura() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())
        model.password = strongPassword
        model.passwordConfirmation = strongPassword + "x"

        XCTAssertFalse(model.canRun)
        XCTAssertEqual(model.blockingReason, "The two passwords do not match.")
    }

    func testSenzaFileNonSiPuoAvviare() {
        let model = EncryptModel()
        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        XCTAssertFalse(model.canRun)
        XCTAssertEqual(model.blockingReason, "Choose a file or folder to encrypt.")
    }

    /// I profili devono cambiare davvero il file prodotto, non solo l'etichetta
    /// mostrata: se la scelta non arrivasse fino a Rust, `k`/`r` resterebbero
    /// quelli di default e nessun'altra asserzione se ne accorgerebbe.
    func testIlProfiloDiIntegritaArrivaFinoAllHeader() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())
        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        model.integrityProfile = .max

        await model.run()

        let output = try XCTUnwrap(model.output)
        XCTAssertEqual(output.meta.k, 8, "profilo Massima (SPEC §5.2)")
        XCTAssertEqual(output.meta.r, 24, "profilo Massima (SPEC §5.2)")
        model.discardWork()
    }

    func testIlProfiloDiSicurezzaArrivaFinoAllHeader() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())
        model.password = strongPassword
        model.passwordConfirmation = strongPassword
        model.securityProfile = .strong

        await model.run()

        let output = try XCTUnwrap(model.output)
        XCTAssertEqual(output.meta.argon2MemKib, 256 * 1024, "profilo Forte (SPEC §5.2)")
        XCTAssertEqual(output.meta.argon2Time, 6)
        model.discardWork()
    }

    /// I predefiniti si rileggono a schermata ferma, non mentre si sta
    /// lavorando su un file.
    ///
    /// Il modello si costruisce una volta sola, quando la `TabView` crea la
    /// schermata: senza rilettura, un predefinito cambiato nelle impostazioni
    /// resterebbe salvato e inerte. Ma rileggerlo sempre sovrascriverebbe le
    /// scelte fatte apposta per il file in corso.
    func testIPredefinitiSiRileggonoSoloASchermataFerma() async throws {
        let defaults = UserDefaults.standard
        // Si parte da pulito: le impostazioni sopravvivono fra un'esecuzione e
        // l'altra nel contenitore dell'app, e un UI test che ne ha cambiata una
        // renderebbe questo test verde o rosso a seconda di cosa è girato prima.
        defaults.removeObject(forKey: PreferenceKey.securityProfile)
        addTeardownBlock { defaults.removeObject(forKey: PreferenceKey.securityProfile) }

        let model = EncryptModel()
        XCTAssertEqual(model.securityProfile, EncryptionDefaults.builtIn.securityProfile)

        defaults.set(SecurityProfile.paranoid.storageValue, forKey: PreferenceKey.securityProfile)
        model.refreshDefaultsIfIdle()
        XCTAssertEqual(model.securityProfile, .paranoid, "a schermata ferma il nuovo predefinito vale")

        // Con un file scelto la rilettura non deve toccare nulla: quelle sono
        // scelte fatte per **questo** file.
        await model.select(try fileDiProva())
        model.securityProfile = .standard
        defaults.set(SecurityProfile.strong.storageValue, forKey: PreferenceKey.securityProfile)
        model.refreshDefaultsIfIdle()
        XCTAssertEqual(model.securityProfile, .standard, "una scelta in corso non va sovrascritta")
    }

    /// La stima serve a non far scoprire a operazione finita che il file è
    /// quattro volte più grande.
    func testLaStimaCresceConIlProfiloDiIntegrita() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva(String(repeating: "x", count: 100_000)))

        model.integrityProfile = .low
        XCTAssertEqual(model.integrityOverheadPercent, 14)  // r 4 / k 28
        let bassa = try XCTUnwrap(model.estimatedOutputSize)

        model.integrityProfile = .max
        XCTAssertEqual(model.integrityOverheadPercent, 300)  // r 24 / k 8
        let massima = try XCTUnwrap(model.estimatedOutputSize)

        XCTAssertNotEqual(bassa, massima, "la stima deve reagire al profilo")
    }

    func testLePasswordVengonoAzzerateDopoLUso() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())
        model.password = strongPassword
        model.passwordConfirmation = strongPassword

        await model.run()
        XCTAssertNotNil(model.output)

        model.clearPasswords()
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.passwordConfirmation.isEmpty)
        model.discardWork()
    }

    func testUnaSecondaEsecuzioneNonLasciaOrfanaLaPrecedente() async throws {
        let model = EncryptModel()
        await model.select(try fileDiProva())
        model.password = strongPassword
        model.passwordConfirmation = strongPassword

        await model.run()
        let primo = try XCTUnwrap(model.output).url
        await model.run()
        let secondo = try XCTUnwrap(model.output).url

        XCTAssertNotEqual(primo, secondo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primo.path))
        model.discardWork()
    }
}
