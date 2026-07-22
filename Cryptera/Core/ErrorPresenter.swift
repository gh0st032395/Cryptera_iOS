import Foundation

/// Traduce un `CrypteraError` in un messaggio mostrabile.
///
/// Regola non negoziabile (SPEC §10.3): all'utente si mostra **solo** la stringa
/// mappata dal codice, mai il campo `message` grezzo — è diagnostico e può
/// contenere percorsi.
///
/// **Stato M3:** stringhe inline. In M9 diventano lookup su
/// `Localizable.strings`, usando le stesse chiavi del desktop
/// (`ui/modules/i18n.js`) così che il confronto resti possibile. Le chiavi sono
/// già indicate qui accanto a ogni caso.
enum ErrorPresenter {

    static let unexpected = "Si è verificato un errore imprevisto."

    static func message(for error: CrypteraError) -> String {
        switch error {

        // ─── Core ───────────────────────────────────────────────
        case .PasswordInvalid:              // err_password_invalid
            return "Password o keyfile non corretti."

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
            return "Password o keyfile non corretti, oppure il file è stato modificato."

        case .HeaderInvalid:                // err_header_invalid
            return "Il file non è un archivio Cryptera valido."

        case .ParamsOutOfLimits:            // err_params_limits
            return "I parametri del file sono fuori dai limiti consentiti."

        case .Truncated:                    // err_truncated
            return "Il file è incompleto."

        case .CorruptBeyondFec:             // err_corrupt_beyond_fec
            return "Il file è danneggiato oltre la capacità di recupero."

        case .IoError:                      // err_io
            return "Errore di lettura o scrittura."

        case .Cancelled:                    // err_cancelled
            return "Operazione annullata."

        case .UnknownError:
            return unexpected

        // ─── Livello applicativo ────────────────────────────────
        case .PasswordRequired:             // err_password_required
            return "Inserisci una password."

        case .InputRequired:                // err_input_required
            return "Seleziona un file o una cartella."

        case .OutputRequired:               // err_output_required
            return "Scegli una destinazione."

        case .OutputExists:                 // err_output_exists
            return "Esiste già un file con questo nome. Non verrà sovrascritto."

        case .TarError:                     // err_tar
            return "Non è stato possibile creare l'archivio."

        case .ExtractError:                 // err_extract
            return "Non è stato possibile estrarre l'archivio."

        // ─── Specifici iOS ──────────────────────────────────────
        case .AccessDenied:
            return "Accesso al file negato. Riprova selezionandolo di nuovo."

        case .InsufficientStorage:
            return "Spazio insufficiente per completare l'operazione."

        case .DeviceLocked:
            return "Il dispositivo si è bloccato durante l'operazione. Sbloccalo e riprova."

        case .InsufficientMemory:
            // Non si abbassano i parametri di nascosto: cambierebbero la chiave
            // derivata, quindi il file (SPEC §11.2).
            return "Questo dispositivo non ha memoria sufficiente per il profilo di sicurezza scelto."

        case .Internal:
            // Il messaggio diagnostico resta fuori dalla UI.
            return unexpected
        }
    }
}
