import XCTest
@testable import Cryptera

/// Preflight memoria, nelle due forme in cui la domanda si pone (M10).
///
/// In cifratura il profilo lo sceglie l'utente e un rifiuto è un invito a
/// sceglierne un altro. In decifratura i parametri arrivano dall'header: chi
/// apre il file non li ha scelti e **non può abbassarli**, perché cambiarli
/// cambierebbe la chiave derivata — non aprirebbe il file, lo renderebbe
/// illeggibile. Sono due situazioni diverse dietro la stessa aritmetica, ed è
/// il motivo per cui la regola sta in un punto solo.
final class MemoryPreflightTests: XCTestCase {

    private func meta(argon2MemKib: UInt32) -> MetaInfo {
        MetaInfo(
            filename: "prova.txt",
            version: 5,
            k: 24,
            r: 8,
            shardSize: 1024,
            plainSize: 10,
            storedSize: 20,
            flags: 0,
            argon2Time: 3,
            argon2MemKib: argon2MemKib,
            argon2Par: 2
        )
    }

    func testLaMemoriaRichiestaVieneDallHeader() {
        XCTAssertEqual(meta(argon2MemKib: 64 * 1024).argon2MemoryBytes, 64 * 1024 * 1024)
        XCTAssertEqual(meta(argon2MemKib: 512 * 1024).argon2MemoryBytes, 512 * 1024 * 1024)
    }

    /// Senza una stima non si blocca.
    ///
    /// È il caso del simulatore, dove `os_proc_available_memory()` risponde 0.
    /// Rifiutare tutto lì renderebbe l'app inutilizzabile proprio dove il
    /// sistema non sa rispondere — e in una app di cifratura un rifiuto
    /// immotivato somiglia molto a un file corrotto.
    func testSenzaStimaNonSiBlocca() throws {
        try XCTSkipUnless(
            MemoryPreflight.availableBytes == nil,
            "questo dispositivo la stima ce l'ha: caso non riproducibile qui"
        )
        XCTAssertTrue(MemoryPreflight.fits(UInt64.max))
    }

    /// La soglia è la stessa per entrambe le forme della domanda.
    ///
    /// Se `SecurityProfile` e `MetaInfo` avessero due regole proprie, un file
    /// cifrato con un profilo **accettato** in cifratura potrebbe risultare
    /// rifiutato in decifratura sullo stesso telefono: l'app produrrebbe file
    /// che poi si rifiuta di aprire.
    func testStessaSogliaPerCifraturaEDecifratura() throws {
        try XCTSkipIf(
            MemoryPreflight.availableBytes == nil,
            "senza stima entrambe rispondono sempre sì: il confronto non dimostra nulla"
        )

        for profilo in [SecurityProfile.standard, .strong, .paranoid] {
            let richiesti = securityProfileMemoryBytes(profile: profilo)
            let comeHeader = meta(argon2MemKib: UInt32(richiesti / 1024))
            XCTAssertEqual(
                profilo.fitsInAvailableMemory, comeHeader.fitsInAvailableMemory,
                "\(profilo): cifratura e decifratura devono rispondere allo stesso modo"
            )
        }
    }

    /// Una richiesta assurda viene rifiutata dove la stima esiste.
    func testUnaRichiestaFuoriScalaVieneRifiutata() throws {
        try XCTSkipIf(
            MemoryPreflight.availableBytes == nil,
            "senza stima non si blocca per scelta: verificato in un test suo"
        )
        // 64 GiB: nessun dispositivo iOS concede tanto.
        XCTAssertFalse(meta(argon2MemKib: 64 * 1024 * 1024).fitsInAvailableMemory)
    }

    // MARK: - Effetto sulla schermata

    @MainActor
    func testIlModelloBloccaLEsecuzioneESpiegaPerche() throws {
        try XCTSkipIf(
            MemoryPreflight.availableBytes == nil,
            "senza stima il preflight non blocca: nulla da mostrare"
        )

        let model = DecryptModel()
        XCTAssertNil(model.memoryProblem, "senza file scelto non c'è nulla da dire")

        model.applyHeaderForTesting(meta(argon2MemKib: 64 * 1024 * 1024))
        model.password = "una-password-qualsiasi"

        let messaggio = try XCTUnwrap(model.memoryProblem)
        XCTAssertFalse(
            messaggio.localizedCaseInsensitiveContains("profil"),
            "in decifratura non si può suggerire un profilo diverso: non c'è nulla da scegliere"
        )
        XCTAssertFalse(
            model.canRun,
            "con il preflight fallito il pulsante non deve partire: fallirebbe comunque, dopo l'attesa"
        )
    }
}
