//! Superficie UniFFI di Cryptera iOS.
//!
//! Regola architetturale (SPEC §2.2): tutta la logica che determina il
//! *contenuto* del file vive qui o nel core, mai in Swift. Swift si occupa solo
//! di UI, accesso file iOS e presentazione errori.
//!
//! Stato: **M2** — superficie minima, sufficiente a dimostrare che
//! l'XCFramework è linkabile e che il core gira davvero su device.
//! La superficie completa (encrypt / decrypt / verify, ProgressListener,
//! CancelToken) arriva in M3.

uniffi::setup_scaffolding!();

mod errors;

pub use errors::CrypteraError;
use errors::guard;

/// Tag di `crypto_core_rs` su cui questa build è compilata.
///
/// Deve restare allineato al `tag = ...` in `Cargo.toml`. È duplicato perché
/// cargo non espone la revisione di una dipendenza git al codice; il test
/// `core_version_riporta_il_tag` fa da promemoria, non da verifica reale.
const CORE_TAG: &str = "v2.0.4";

/// Metadati dell'header ECF1.
///
/// Rispecchia esattamente `crypto_core_rs::MetaInfo` e il DTO Tauri
/// `MetaInfoDto` (SPEC §5.1). **Non aggiungere né rimuovere campi** senza
/// allineare l'upstream.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MetaInfo {
    /// Vuoto su file v5 con nome cifrato letti senza password: è atteso.
    pub filename: String,
    pub version: u8,
    pub k: u16,
    pub r: u16,
    pub shard_size: u32,
    pub plain_size: u64,
    pub stored_size: u64,
    pub flags: u8,
    pub argon2_time: u32,
    pub argon2_mem_kib: u32,
    pub argon2_par: u16,
}

impl From<crypto_core_rs::MetaInfo> for MetaInfo {
    fn from(m: crypto_core_rs::MetaInfo) -> Self {
        Self {
            filename: m.filename,
            version: m.version,
            k: m.k,
            r: m.r,
            shard_size: m.shard_size,
            plain_size: m.plain_size,
            stored_size: m.stored_size,
            flags: m.flags,
            argon2_time: m.argon2_time,
            argon2_mem_kib: m.argon2_mem_kib,
            argon2_par: m.argon2_par,
        }
    }
}

/// Versione dell'FFI e tag del core su cui è compilata.
#[uniffi::export]
pub fn core_version() -> String {
    format!("cryptera-ffi {} (core {})", env!("CARGO_PKG_VERSION"), CORE_TAG)
}

/// Legge l'header senza password: non deriva chiavi, non autentica.
///
/// Su file v5 con nome cifrato `filename` torna vuoto — è il comportamento
/// atteso, non un errore (SPEC §5.3).
#[uniffi::export]
pub fn read_metadata(path: String) -> Result<MetaInfo, CrypteraError> {
    guard(|| {
        let meta = crypto_core_rs::read_metadata_rs(&path)?;
        Ok(meta.into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_riporta_il_tag() {
        let v = core_version();
        assert!(v.contains(CORE_TAG), "versione inattesa: {v}");
    }

    #[test]
    fn read_metadata_su_file_inesistente_da_errore_tipizzato() {
        // Verifica che il mapping CoreError -> CrypteraError sia attivo e che
        // l'errore non arrivi come panic attraverso il confine FFI.
        match read_metadata("/nonexistent-cryptera-test".to_string()) {
            Err(CrypteraError::IoError) | Err(CrypteraError::HeaderInvalid) => {}
            other => panic!("atteso errore tipizzato, ottenuto {other:?}"),
        }
    }

    #[test]
    fn read_metadata_legge_una_fixture_upstream() {
        // La prova che conta in M2: il core è linkato e interpreta davvero un
        // file ECF1 reale attraverso il confine FFI.
        let fixture = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../CrypteraTests/Fixtures/v4-basic.ecf"
        );
        let meta = read_metadata(fixture.to_string()).expect("fixture leggibile");
        assert_eq!(meta.version, 4, "la fixture v4-basic deve essere v4");
        assert!(meta.k > 0 && meta.r > 0);
        assert!(meta.shard_size >= 1024);
    }
}
