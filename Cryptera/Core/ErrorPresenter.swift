import Foundation

/// Traduce un `CrypteraError` in un messaggio mostrabile.
///
/// Regola non negoziabile (SPEC §10.3): all'utente si mostra **solo** la stringa
/// mappata dal codice, mai il campo `message` grezzo — è diagnostico e può
/// contenere percorsi.
///
/// La chiave dell'upstream è annotata accanto a ogni caso. È l'unico punto in
/// cui la corrispondenza con `ui/modules/i18n.js` è reale — le schermate di iOS
/// sono altre — e serve a poter confrontare i due messaggi quando si dubita di
/// uno dei due.
enum ErrorPresenter {

    static var unexpected: String { L.t("Something went wrong.") }

    static func message(for error: CrypteraError) -> String {
        switch error {

        // ─── Core ───────────────────────────────────────────────
        case .PasswordInvalid:              // err_password_invalid
            return L.t("Wrong password or keyfile.")

        case .HeaderAuthFailed:             // err_header_auth
            // ⚠️ Il desktop mostra qui "Il file potrebbe essere stato
            // manomesso". Su header v5 però questo è **anche** l'errore di una
            // semplice password sbagliata: il tag di autenticazione dell'header
            // deriva dalla master key, quindi una password errata lo invalida, e
            // quel controllo precede il record PWCHK.
            //
            // Accusare di manomissione chi ha solo sbagliato a digitare è
            // allarmante e quasi sempre falso. Il messaggio copre onestamente
            // entrambe le cause, nell'ordine di probabilità reale.
            //
            // Non si rimappa il codice su PasswordInvalid: nasconderebbe le
            // manomissioni vere.
            return L.t("Wrong password or keyfile, or the file has been modified.")

        case .HeaderInvalid:                // err_header_invalid
            return L.t("This is not a valid Cryptera file.")

        case .ParamsOutOfLimits:            // err_params_limits
            return L.t("The file's parameters are outside the allowed limits.")

        case .Truncated:                    // err_file_truncated
            return L.t("The file is incomplete.")

        case .CorruptBeyondFec:             // err_corrupt_beyond_fec
            return L.t("The file is damaged beyond what can be recovered.")

        case .IoError:                      // err_io
            return L.t("Could not read or write the file.")

        case .Cancelled:                    // err_cancelled
            return L.t("Operation cancelled.")

        case .UnknownError:
            return unexpected

        // ─── Livello applicativo ────────────────────────────────
        case .PasswordRequired:             // err_password_required
            return L.t("Enter a password.")

        case .InputRequired:                // err_input_required
            return L.t("Choose a file or folder.")

        case .OutputRequired:               // err_output_required
            return L.t("Choose a destination.")

        case .OutputExists:                 // err_output_exists
            return L.t("A file with this name already exists. It will not be overwritten.")

        case .TarError:                     // err_tar
            return L.t("Could not create the archive.")

        case .ExtractError:                 // err_extract
            return L.t("Could not extract the archive.")

        // ─── Specifici iOS ──────────────────────────────────────
        case .AccessDenied:
            return L.t("Access to the file was denied. Try selecting it again.")

        case .InsufficientStorage:
            return L.t("Not enough space to complete the operation.")

        case .DeviceLocked:
            return L.t("The device locked during the operation. Unlock it and try again.")

        case .InsufficientMemory:
            // Non si abbassano i parametri di nascosto: cambierebbero la chiave
            // derivata, quindi il file (SPEC §11.2).
            return L.t("This device does not have enough memory for the chosen security profile.")

        case .Internal:
            // Il messaggio diagnostico resta fuori dalla UI.
            return unexpected
        }
    }
}
