import Foundation

/// Valutazione della robustezza di una password.
///
/// **Port fedele di `ui/modules/password.js` dell'upstream** (SPEC §8.2:
/// *replicare* la logica, non inventarne una nuova). Le soglie sono quelle del
/// desktop e non vanno "migliorate" qui: un utente che passa da desktop a
/// iPhone deve vedere lo stesso giudizio sulla stessa password, altrimenti uno
/// dei due sta mentendo.
///
/// Vive in Swift e non in Rust perché non determina il *contenuto* del file:
/// non entra nella chiave, non entra nell'header, non cambia un byte di output.
/// La regola di SPEC §2.2 riguarda ciò che finisce nel formato.
struct PasswordStrength: Equatable {

    /// Da 0 (molto debole) a 4 (molto robusta).
    let level: Int
    let length: Int
    /// Cosa manca, nell'ordine dell'upstream. Vuoto se non manca nulla.
    let missing: [Requirement]

    enum Requirement: Equatable {
        case tooShort
        case uppercase
        case lowercase
        case number
        case special

        var text: String {
            switch self {
            case .tooShort: return L.t("at least 10 characters")
            case .uppercase: return L.t("an uppercase letter")
            case .lowercase: return L.t("a lowercase letter")
            case .number: return L.t("a digit")
            case .special: return L.t("a symbol")
            }
        }
    }

    /// `pwd_strength_*` dell'upstream.
    var label: String {
        switch level {
        case 0: return L.t("Very weak")
        case 1: return L.t("Weak")
        case 2: return L.t("Medium")
        case 3: return L.t("Strong")
        default: return L.t("Very strong")
        }
    }

    /// `pwd_feedback_*`: cosa manca, o l'incoraggiamento quando non manca nulla.
    ///
    /// L'incoraggiamento è subordinato alla **policy**, non al solo livello.
    /// L'upstream lo lega al livello, e nella sua interfaccia funziona perché
    /// mostra la violazione della policy solo al momento di cifrare: qui invece
    /// barra e pulsante bloccato stanno sotto gli occhi insieme, e una password
    /// di 9 caratteri con tipi misti arriva a livello 3 — quindi diceva
    /// contemporaneamente "Va bene" e "troppo debole".
    ///
    /// La policy non cambia: cambia quale messaggio si mostra.
    var hint: String? {
        if meetsEncryptionPolicy {
            return level >= 4 ? L.t("Great password") : L.t("Good password")
        }
        guard !missing.isEmpty else { return nil }
        return L.t("Add:") + " " + missing.map(\.text).joined(separator: ", ")
    }

    /// Cosa impedisce di cifrare, o `nil` se la policy è soddisfatta.
    ///
    /// Distingue le due condizioni invece di dire "troppo debole" anche a chi ha
    /// scelto bene i caratteri e si è fermato a nove: quel messaggio manda a
    /// cercare il problema dove non è.
    var policyViolation: String? {
        guard !meetsEncryptionPolicy else { return nil }
        if length < 10 {
            return L.t("The password must be at least 10 characters long.")
        }
        return L.t("The password is too simple: mix uppercase, lowercase, digits and symbols.")
    }

    /// La policy di cifratura del desktop: almeno 10 caratteri **e** livello
    /// almeno medio.
    ///
    /// Sul desktop questa condizione **blocca** la cifratura, non avvisa
    /// soltanto (`operations.js`: `handleEncrypt` esce senza cifrare). Si
    /// comporta allo stesso modo qui: un limite che si può ignorare non è un
    /// limite, e la differenza fra le due piattaforme sarebbe silenziosa.
    var meetsEncryptionPolicy: Bool {
        length >= 10 && level >= 2
    }

    /// Valuta una password secondo i punteggi dell'upstream.
    ///
    /// Il punteggio somma cinque condizioni indipendenti; i gradini sono
    /// `<=1 → 0`, `2 → 1`, `3 → 2`, `4 → 3`, `5 → 4`.
    init(_ password: String) {
        // `utf16.count` e non `count`: la lunghezza dell'upstream è quella di
        // JavaScript, cioè unità UTF-16. Su una password con emoji le due
        // misure differiscono, e siccome la lunghezza **blocca** la cifratura
        // una password accettata sul desktop verrebbe rifiutata qui.
        length = password.utf16.count

        guard !password.isEmpty else {
            level = 0
            missing = [.tooShort]
            return
        }

        // Le classi sono quelle delle regex dell'upstream — `[A-Z]`, `[a-z]`,
        // `\d`, `[^A-Za-z0-9]` — cioè **solo ASCII**. Le proprietà Unicode di
        // Swift sono più larghe: `isUppercase` vale per "À" e `isNumber` per le
        // cifre arabo-indiane, che il desktop non conta. Usarle darebbe un
        // giudizio diverso sulla stessa password.
        let scalars = password.unicodeScalars
        let isUpper = { (s: Unicode.Scalar) in s >= "A" && s <= "Z" }
        let isLower = { (s: Unicode.Scalar) in s >= "a" && s <= "z" }
        let isDigit = { (s: Unicode.Scalar) in s >= "0" && s <= "9" }

        let hasUpper = scalars.contains(where: isUpper)
        let hasLower = scalars.contains(where: isLower)
        let hasNumber = scalars.contains(where: isDigit)
        let hasSpecial = scalars.contains { !isUpper($0) && !isLower($0) && !isDigit($0) }

        var missing: [Requirement] = []
        if length < 10 { missing.append(.tooShort) }
        if !hasUpper { missing.append(.uppercase) }
        if !hasLower { missing.append(.lowercase) }
        if !hasNumber { missing.append(.number) }
        if !hasSpecial { missing.append(.special) }
        self.missing = missing

        var points = 0
        if length >= 8 { points += 1 }
        if length >= 10 { points += 1 }
        if hasLower && hasUpper { points += 1 }
        if hasNumber { points += 1 }
        if hasSpecial { points += 1 }

        switch points {
        case ...1: level = 0
        case 2: level = 1
        case 3: level = 2
        case 4: level = 3
        default: level = 4
        }
    }
}
