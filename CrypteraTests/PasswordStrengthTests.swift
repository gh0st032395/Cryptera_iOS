import XCTest
@testable import Cryptera

/// Fissa le soglie del port di `ui/modules/password.js`.
///
/// Non sono valori scelti da noi: sono quelli del desktop, e devono restare
/// identici. Un utente che valuta la stessa password sulle due piattaforme deve
/// leggere lo stesso giudizio — altrimenti una delle due sta mentendo, e sulla
/// robustezza di una password mentire ha conseguenze.
final class PasswordStrengthTests: XCTestCase {

    func testGradiniDelPunteggio() {
        // punti: <8 caratteri, nessuna combinazione → 0
        XCTAssertEqual(PasswordStrength("abc").level, 0)
        // 8 caratteri (1) + minuscole senza maiuscole (0) → 1 punto → livello 0
        XCTAssertEqual(PasswordStrength("abcdefgh").level, 0)
        // 8 (1) + 10 caratteri (1) → 2 punti → livello 1
        XCTAssertEqual(PasswordStrength("abcdefghij").level, 1)
        // 8 (1) + 10 (1) + maiuscole e minuscole (1) → 3 punti → livello 2
        XCTAssertEqual(PasswordStrength("Abcdefghij").level, 2)
        // + numero → 4 punti → livello 3
        XCTAssertEqual(PasswordStrength("Abcdefghi1").level, 3)
        // + simbolo → 5 punti → livello 4
        XCTAssertEqual(PasswordStrength("Abcdefgh1!").level, 4)
    }

    func testPasswordVuota() {
        let vuota = PasswordStrength("")
        XCTAssertEqual(vuota.level, 0)
        XCTAssertEqual(vuota.length, 0)
        XCTAssertEqual(vuota.missing, [.tooShort])
        XCTAssertFalse(vuota.meetsEncryptionPolicy)
    }

    /// La policy del desktop: almeno 10 caratteri **e** livello almeno medio.
    /// Sul desktop non avvisa soltanto — impedisce la cifratura.
    func testPolicyDiCifratura() {
        XCTAssertFalse(PasswordStrength("Abc1!").meetsEncryptionPolicy, "troppo corta")
        XCTAssertFalse(
            PasswordStrength("abcdefghij").meetsEncryptionPolicy,
            "lunga abbastanza ma di livello 1"
        )
        XCTAssertTrue(PasswordStrength("Abcdefghij").meetsEncryptionPolicy)
        XCTAssertTrue(PasswordStrength("FixtureP@ssw0rd42").meetsEncryptionPolicy)
    }

    /// Il confine esatto dei 10 caratteri, che è anche quello della policy.
    func testConfineDeiDieciCaratteri() {
        XCTAssertFalse(PasswordStrength("Abcdefgh1").meetsEncryptionPolicy, "9 caratteri")
        XCTAssertTrue(PasswordStrength("Abcdefgh12").meetsEncryptionPolicy, "10 caratteri")
    }

    /// Le classi di caratteri dell'upstream sono **solo ASCII**.
    ///
    /// Le proprietà Unicode di Swift sono più larghe: senza il vincolo, "À"
    /// conterebbe come maiuscola e "٣" come cifra, che il desktop non conta.
    func testSoloICaratteriAsciiContano() {
        // Accentate: per il desktop non sono lettere, sono simboli.
        let accentata = PasswordStrength("àààààààààà")
        XCTAssertTrue(accentata.missing.contains(.uppercase))
        XCTAssertTrue(accentata.missing.contains(.lowercase))
        XCTAssertFalse(accentata.missing.contains(.special), "una accentata vale come simbolo")

        // Cifre arabo-indiane: non sono `\d`.
        XCTAssertTrue(PasswordStrength("Abcdefgh٣٣").missing.contains(.number))
    }

    /// La lunghezza è quella di JavaScript, in unità UTF-16.
    ///
    /// Contando i caratteri Swift, un'emoji varrebbe 1 invece di 2 e una
    /// password accettata dal desktop verrebbe rifiutata qui — su un limite che
    /// blocca l'operazione.
    func testLunghezzaInUnitaUtf16ComeIlDesktop() {
        XCTAssertEqual(PasswordStrength("😀").length, 2)
        XCTAssertEqual(PasswordStrength("Abc1!😀😀😀").length, 11)
    }

    func testSuggerimentiElencanoCioCheManca() {
        let debole = PasswordStrength("abcdefghij")
        XCTAssertEqual(debole.missing, [.uppercase, .number, .special])
        let hint = debole.hint ?? ""
        XCTAssertTrue(hint.contains("maiuscola"), "ottenuto: \(hint)")

        XCTAssertEqual(PasswordStrength("Abcdefgh1!").hint, "Ottima scelta.")
        XCTAssertEqual(PasswordStrength("Abcdefghi1").hint, "Va bene.")
    }
}
