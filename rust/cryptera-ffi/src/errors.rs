//! Mapping degli errori verso Swift.
//!
//! I codici del core (SPEC §10.1) sono **stabili e non vanno rinominati**: sono
//! le stesse stringhe usate dal desktop, e le chiavi di localizzazione le
//! rispecchiano. Rinominarne uno significa rompere la corrispondenza fra i
//! messaggi mostrati su iOS e quelli del desktop.

use std::panic::{catch_unwind, AssertUnwindSafe};

/// Errore esposto a Swift come enum tipizzato.
///
/// Le varianti senza payload corrispondono 1:1 ai codici del core. Solo
/// `Internal` porta un messaggio diagnostico, che **non va mai mostrato
/// all'utente** (SPEC §10.3: può contenere percorsi). Swift mostra la stringa
/// localizzata mappata dalla variante.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CrypteraError {
    // ─── Codici dal core (SPEC §10.1) ──────────────────────────
    #[error("PASSWORD_INVALID")]
    PasswordInvalid,
    #[error("HEADER_AUTH_FAILED")]
    HeaderAuthFailed,
    #[error("HEADER_INVALID")]
    HeaderInvalid,
    #[error("PARAMS_OUT_OF_LIMITS")]
    ParamsOutOfLimits,
    #[error("TRUNCATED")]
    Truncated,
    #[error("CORRUPT_BEYOND_FEC")]
    CorruptBeyondFec,
    #[error("IO_ERROR")]
    IoError,
    #[error("CANCELLED")]
    Cancelled,
    #[error("UNKNOWN_ERROR")]
    UnknownError,

    // ─── Codici applicativi dal desktop (SPEC §10.2) ───────────
    #[error("PASSWORD_REQUIRED")]
    PasswordRequired,
    #[error("INPUT_REQUIRED")]
    InputRequired,
    #[error("OUTPUT_REQUIRED")]
    OutputRequired,
    #[error("OUTPUT_EXISTS")]
    OutputExists,
    #[error("TAR_ERROR")]
    TarError,
    #[error("EXTRACT_ERROR")]
    ExtractError,

    // ─── Specifici iOS (SPEC §10.2) ────────────────────────────
    /// Security scope negato o scaduto.
    #[error("ACCESS_DENIED")]
    AccessDenied,
    /// Spazio insufficiente: verificato *prima* di iniziare (SPEC §11.4).
    #[error("INSUFFICIENT_STORAGE")]
    InsufficientStorage,
    /// Data Protection ha reso il file illeggibile a device bloccato (SPEC §11.3).
    #[error("DEVICE_LOCKED")]
    DeviceLocked,
    /// Il profilo richiesto eccede la memoria disponibile (SPEC §11.2).
    /// Mai degradare silenziosamente i parametri: cambierebbe la chiave derivata.
    #[error("INSUFFICIENT_MEMORY")]
    InsufficientMemory,

    /// Panic catturato al confine FFI, o fallimento non classificabile.
    #[error("INTERNAL")]
    Internal { message: String },
}

impl From<crypto_core_rs::CoreError> for CrypteraError {
    fn from(e: crypto_core_rs::CoreError) -> Self {
        match e.code {
            "PASSWORD_INVALID" => Self::PasswordInvalid,
            "HEADER_AUTH_FAILED" => Self::HeaderAuthFailed,
            "HEADER_INVALID" => Self::HeaderInvalid,
            "PARAMS_OUT_OF_LIMITS" => Self::ParamsOutOfLimits,
            "TRUNCATED" => Self::Truncated,
            "CORRUPT_BEYOND_FEC" => Self::CorruptBeyondFec,
            "IO_ERROR" => Self::IoError,
            "CANCELLED" => Self::Cancelled,
            _ => Self::UnknownError,
        }
    }
}

/// Panic barrier per gli entry point FFI (SPEC §5.4).
///
/// Un panic che attraversa il confine FFI è undefined behaviour. Ogni funzione
/// `#[uniffi::export]` va avvolta qui.
///
/// Funziona **solo** perché il profilo release usa `panic = "unwind"`: con
/// `panic = "abort"` `catch_unwind` non cattura nulla. Vedi la nota in
/// `rust/Cargo.toml`.
pub(crate) fn guard<T, F>(f: F) -> Result<T, CrypteraError>
where
    F: FnOnce() -> Result<T, CrypteraError>,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(payload) => {
            // Il messaggio del panic è diagnostico e non viene mai mostrato
            // all'utente; serve solo a distinguere i casi in fase di sviluppo.
            let message = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic senza messaggio".to_string());
            Err(CrypteraError::Internal { message })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_converte_panic_in_internal() {
        let r: Result<(), _> = guard(|| panic!("boom"));
        match r {
            Err(CrypteraError::Internal { message }) => assert!(message.contains("boom")),
            other => panic!("atteso Internal, ottenuto {other:?}"),
        }
    }

    #[test]
    fn guard_lascia_passare_il_successo() {
        assert_eq!(guard(|| Ok::<_, CrypteraError>(42)).unwrap(), 42);
    }
}
