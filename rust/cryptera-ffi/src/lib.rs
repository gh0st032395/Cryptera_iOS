//! Superficie UniFFI di Cryptera iOS.
//!
//! Regola architetturale (SPEC §2.2): tutta la logica che determina il
//! *contenuto* del file vive qui o nel core, mai in Swift. Swift si occupa solo
//! di UI, accesso file iOS e presentazione errori.

uniffi::setup_scaffolding!();

mod control;
mod errors;
mod orchestration;

pub use control::{CancelToken, ProgressListener};
pub use errors::CrypteraError;
pub use orchestration::{
    ArchiveCompression, IntegrityProfile, PayloadCompression, SecurityProfile,
};

use std::path::Path;
use std::sync::{Arc, Once};

use control::Throttled;
use crypto_core_rs::ControlFlags;
use errors::guard;
use zeroize::Zeroizing;

/// Tag di `crypto_core_rs` su cui questa build è compilata.
///
/// Deve restare allineato al `tag = ...` in `Cargo.toml`. È duplicato perché
/// cargo non espone la revisione di una dipendenza git al codice.
const CORE_TAG: &str = "v2.0.4";

/// `FLAG_TAR_CONTAINER` (SPEC §16.3): il payload cifrato è un archivio TAR.
const FLAG_TAR_CONTAINER: u8 = 0x20;

// ─── Tipi di input (SPEC §5.1) ─────────────────────────────────────

#[derive(Debug, Clone, uniffi::Enum)]
pub enum InputSource {
    File { path: String },
    Folder { path: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EncryptRequest {
    pub source: InputSource,
    pub output_path: String,
    pub password: String,
    pub keyfile_path: Option<String>,
    pub payload_compression: PayloadCompression,
    pub archive_compression: ArchiveCompression,
    pub skip_special_files: bool,
    pub enable_password_check: bool,
    pub hide_filename: bool,
    pub security_profile: SecurityProfile,
    pub integrity_profile: IntegrityProfile,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DecryptRequest {
    pub input_path: String,
    pub output_path: String,
    pub password: String,
    pub keyfile_path: Option<String>,
    pub extract_archive: bool,
    pub keep_archive: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct VerifyRequest {
    pub input_path: String,
    pub password: String,
    pub keyfile_path: Option<String>,
}

// ─── Output (SPEC §5.1) ────────────────────────────────────────────

/// Metadati dell'header ECF1.
///
/// Rispecchia esattamente `crypto_core_rs::MetaInfo` e il DTO Tauri
/// `MetaInfoDto`. **Non aggiungere né rimuovere campi** senza allineare
/// l'upstream.
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

impl MetaInfo {
    /// Il payload è un archivio TAR e può essere estratto.
    pub fn is_tar_container(&self) -> bool {
        self.flags & FLAG_TAR_CONTAINER != 0
    }
}

// ─── Configurazione ────────────────────────────────────────────────

static THREAD_POOL_INIT: Once = Once::new();

/// Limita il pool di thread di rayon (SPEC §5.4).
///
/// Swift passa `min(activeProcessorCount, 4)`: saturare tutti i core di un
/// iPhone porta a throttling termico in pochi minuti, peggiorando i tempi
/// invece di migliorarli.
///
/// Ha effetto solo alla prima chiamata — il pool globale di rayon si inizializza
/// una volta sola — quindi va invocata all'avvio, prima di qualunque operazione.
#[uniffi::export]
pub fn configure_thread_pool(max_threads: u32) {
    THREAD_POOL_INIT.call_once(|| {
        let n = max_threads.clamp(1, 64) as usize;
        // Un fallimento qui non è fatale: rayon resta sul default.
        let _ = rayon::ThreadPoolBuilder::new().num_threads(n).build_global();
    });
}

/// Memoria richiesta da Argon2 per il profilo, in byte.
///
/// Esposta come funzione perché UniFFI non esporta i metodi degli enum. Swift
/// la confronta con `os_proc_available_memory()` prima di avviare (SPEC §11.2):
/// su iOS il superamento del limite jetsam non è un'eccezione catturabile, è la
/// morte del processo.
///
/// Deve restare l'unica fonte di questi valori: duplicarli in Swift li farebbe
/// divergere da quelli scritti nell'header.
#[uniffi::export]
pub fn security_profile_memory_bytes(profile: SecurityProfile) -> u64 {
    profile.memory_bytes()
}

/// Overhead di parità in percentuale per il profilo di integrità.
///
/// La UI lo mostra insieme alla dimensione finale stimata, altrimenti `Max`
/// sorprende l'utente con un file 4× più grande (SPEC §8.2).
#[uniffi::export]
pub fn integrity_profile_overhead_percent(profile: IntegrityProfile) -> u32 {
    profile.parity_overhead_percent()
}

/// Versione dell'FFI e tag del core su cui è compilata.
#[uniffi::export]
pub fn core_version() -> String {
    format!("cryptera-ffi {} (core {})", env!("CARGO_PKG_VERSION"), CORE_TAG)
}

// ─── Operazioni ────────────────────────────────────────────────────

/// Legge l'header senza password: non deriva chiavi, non autentica.
///
/// Su file v5 con nome cifrato `filename` torna vuoto — è il comportamento
/// atteso, non un errore (SPEC §5.3).
#[uniffi::export]
pub fn read_metadata(path: String) -> Result<MetaInfo, CrypteraError> {
    guard(|| Ok(crypto_core_rs::read_metadata_rs(&path)?.into()))
}

/// Verifica l'integrità senza scrivere alcun output.
#[uniffi::export]
pub fn verify(
    request: VerifyRequest,
    listener: Option<Arc<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError> {
    guard(move || {
        let password = Zeroizing::new(request.password);
        if password.trim().is_empty() {
            return Err(CrypteraError::PasswordRequired);
        }
        if request.input_path.is_empty() {
            return Err(CrypteraError::InputRequired);
        }

        let keyfile = load_keyfile(request.keyfile_path.as_deref())?;
        let flags = flags_of(&token);
        let mut throttled = Throttled::new(listener);
        let mut progress = |stage: &str, done: u64, total: u64| {
            throttled.emit(stage, done, total);
        };

        let meta = crypto_core_rs::verify_file_integrity_rs_controlled(
            &request.input_path,
            &password,
            keyfile.as_deref(),
            Some(&flags),
            Some(&mut progress),
        )?;
        Ok(meta.into())
    })
}

/// Decifra un `.ecf`, estraendo l'archivio se richiesto e se il file lo è
/// davvero.
#[uniffi::export]
pub fn decrypt(
    request: DecryptRequest,
    listener: Option<Arc<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError> {
    guard(move || {
        let password = Zeroizing::new(request.password);
        if password.trim().is_empty() {
            return Err(CrypteraError::PasswordRequired);
        }
        if request.input_path.is_empty() {
            return Err(CrypteraError::InputRequired);
        }
        if request.output_path.is_empty() {
            return Err(CrypteraError::OutputRequired);
        }

        let keyfile = load_keyfile(request.keyfile_path.as_deref())?;
        let flags = flags_of(&token);
        let mut throttled = Throttled::new(listener);

        if !request.extract_archive {
            if Path::new(&request.output_path).exists() {
                return Err(CrypteraError::OutputExists);
            }
            ensure_parent_dir(&request.output_path)?;
            let mut progress = |stage: &str, done: u64, total: u64| {
                throttled.emit(stage, done, total);
            };
            let meta = crypto_core_rs::decrypt_file_ex_rs_controlled(
                &request.input_path,
                &request.output_path,
                &password,
                keyfile.as_deref(),
                Some(&flags),
                Some(&mut progress),
            )?;
            return Ok(meta.into());
        }

        // Estrazione richiesta: si decifra prima in un temporaneo, perché il
        // nome dell'archivio (e quindi il suo tipo di compressione) si conosce
        // solo dopo aver letto l'header autenticato.
        let staging = tempfile::tempdir().map_err(|_| CrypteraError::IoError)?;
        let payload = staging.path().join("payload");
        let payload_str = payload.to_string_lossy().to_string();

        let meta: MetaInfo = {
            let mut progress = |stage: &str, done: u64, total: u64| {
                throttled.emit(stage, done, total);
            };
            crypto_core_rs::decrypt_file_ex_rs_controlled(
                &request.input_path,
                &payload_str,
                &password,
                keyfile.as_deref(),
                Some(&flags),
                Some(&mut progress),
            )?
            .into()
        };

        // Il fix di v2.0.4: non assumere che sia un container. Su un .ecf
        // singolo l'estrazione fallirebbe con EXTRACT_ERROR / OUTPUT_EXISTS
        // invece di produrre semplicemente il file.
        if !meta.is_tar_container() {
            let dest = Path::new(&request.output_path);
            if dest.exists() {
                return Err(CrypteraError::OutputExists);
            }
            ensure_parent_dir(&request.output_path)?;
            move_file(&payload, dest)?;
            return Ok(meta);
        }

        // La compressione si deduce dal nome memorizzato nell'header, ma il
        // nome **non diventa mai un percorso**: è dato scelto da chi ha creato
        // il file, e `Path::join` con un nome assoluto sostituirebbe la base,
        // scrivendo fuori dalla destinazione. Il payload resta dov'è e la
        // compressione viaggia come parametro.
        let comp = orchestration::archive_compression_from_name(&meta.filename);

        // ⚠️ Comportamento noto, allineato all'upstream: l'estrazione **sovrascrive**
        // i file già presenti nella destinazione, mentre SPEC §6.3 vieta di
        // sovrascrivere in silenzio. La regola è pensata per l'output di un
        // singolo file (dove infatti si torna `OutputExists`); per una cartella
        // servirebbe decidere fra rifiutare, rinominare o chiedere conferma —
        // ed è una scelta di prodotto, non di implementazione. Va risolta nella
        // UI di M4/M8, non cambiata qui di nascosto divergendo dal desktop.
        std::fs::create_dir_all(&request.output_path).map_err(|_| CrypteraError::IoError)?;
        orchestration::safe_extract_tar(&payload_str, &request.output_path, comp)?;

        if request.keep_archive {
            let name = if meta.filename.is_empty() {
                "decrypted.tar".to_string()
            } else {
                orchestration::safe_archive_basename(&meta.filename)
            };
            let kept = Path::new(&request.output_path).join(&name);
            // L'estrazione può già aver scritto un file con questo nome: in tal
            // caso l'archivio non lo sovrascrive.
            if !kept.exists() {
                move_file(&payload, &kept)?;
            }
        }

        Ok(meta)
    })
}

/// Cifra un file o una cartella.
///
/// Per le cartelle costruisce prima un TAR temporaneo: nel caso peggiore serve
/// ~2× la dimensione della sorgente più l'overhead di parità, e lo spazio va
/// verificato da Swift **prima** di chiamare (SPEC §11.4).
#[uniffi::export]
pub fn encrypt(
    request: EncryptRequest,
    listener: Option<Arc<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError> {
    guard(move || {
        let password = Zeroizing::new(request.password);
        if password.trim().is_empty() {
            return Err(CrypteraError::PasswordRequired);
        }
        if request.output_path.is_empty() {
            return Err(CrypteraError::OutputRequired);
        }
        // Mai sovrascrivere silenziosamente (SPEC §6.3).
        if Path::new(&request.output_path).exists() {
            return Err(CrypteraError::OutputExists);
        }
        ensure_parent_dir(&request.output_path)?;

        let keyfile = load_keyfile(request.keyfile_path.as_deref())?;
        let (argon2_t, argon2_m, argon2_p) = request.security_profile.params();
        let (k, r) = request.integrity_profile.params();
        let flags = flags_of(&token);
        let mut throttled = Throttled::new(listener);

        match &request.source {
            InputSource::File { path } => {
                if path.is_empty() {
                    return Err(CrypteraError::InputRequired);
                }
                // Su iOS un bookmark scaduto o uno scope non concesso danno un
                // percorso che non esiste più: senza questo controllo si
                // otterrebbe un errore molto più avanti e meno leggibile.
                if !Path::new(path).is_file() {
                    return Err(CrypteraError::IoError);
                }
                // `None` quando il nome non va nascosto: il core lo deriva
                // dall'input. Passare esplicitamente il nome qui produrrebbe un
                // header diverso da quello del desktop.
                let original_name = if request.hide_filename { Some("") } else { None };
                let mut progress = |stage: &str, done: u64, total: u64| {
                    throttled.emit(stage, done, total);
                };
                crypto_core_rs::encrypt_file_rs_controlled(
                    path,
                    &request.output_path,
                    &password,
                    keyfile.as_deref(),
                    request.payload_compression.core_arg(),
                    request.enable_password_check,
                    Some(k),
                    Some(r),
                    None,
                    Some(argon2_t),
                    Some(argon2_m),
                    Some(argon2_p),
                    original_name,
                    false,
                    Some(&flags),
                    Some(&mut progress),
                )?;
            }
            InputSource::Folder { path } => {
                if path.is_empty() {
                    return Err(CrypteraError::InputRequired);
                }
                let folder = Path::new(path);
                // Senza questo controllo, `walkdir` su una cartella inesistente
                // produce una singola entry di errore che `skip_special_files`
                // scarta: il risultato sarebbe un archivio **vuoto** cifrato con
                // successo, cioè una perdita di dati silenziosa.
                if !folder.is_dir() {
                    return Err(CrypteraError::IoError);
                }

                // Pre-conteggio delle entry, altrimenti la fase di archiviazione
                // resta a 0% (fix di v2.0.4).
                let total_entries = walkdir::WalkDir::new(folder)
                    .follow_links(false)
                    .into_iter()
                    .count() as u64;

                let (tmp_tar, base_name) = {
                    let mut archive_progress =
                        |done: u64| throttled.emit("archiving", done, total_entries);
                    orchestration::create_tar(
                        folder,
                        request.archive_compression,
                        request.skip_special_files,
                        &flags,
                        Some(&mut archive_progress),
                    )?
                };

                let tar_path = tmp_tar.path().to_string_lossy().to_string();
                // Qui il nome va passato: l'input è un temporaneo con nome
                // casuale, che finirebbe nell'header al posto di quello reale.
                let original_name = if request.hide_filename {
                    Some("")
                } else {
                    Some(base_name.as_str())
                };
                let mut progress = |stage: &str, done: u64, total: u64| {
                    throttled.emit(stage, done, total);
                };
                crypto_core_rs::encrypt_file_rs_controlled(
                    &tar_path,
                    &request.output_path,
                    &password,
                    keyfile.as_deref(),
                    // Nessuna compressione del payload: il TAR è già compresso
                    // secondo `archive_compression`.
                    None,
                    request.enable_password_check,
                    Some(k),
                    Some(r),
                    None,
                    Some(argon2_t),
                    Some(argon2_m),
                    Some(argon2_p),
                    original_name,
                    true,
                    Some(&flags),
                    Some(&mut progress),
                )?;
            }
        }

        // Il core non restituisce MetaInfo in cifratura: si rilegge l'header
        // appena scritto, che è anche una verifica che l'output sia valido.
        read_metadata(request.output_path)
    })
}

// ─── Helper ────────────────────────────────────────────────────────

fn flags_of(token: &Option<Arc<CancelToken>>) -> ControlFlags {
    token
        .as_ref()
        .map(|t| t.flags.clone())
        .unwrap_or_default()
}

fn load_keyfile(path: Option<&str>) -> Result<Option<Vec<u8>>, CrypteraError> {
    match path {
        Some(p) if !p.is_empty() => Ok(Some(crypto_core_rs::get_keyfile_hash_rs(p)?)),
        _ => Ok(None),
    }
}

fn ensure_parent_dir(path: &str) -> Result<(), CrypteraError> {
    if let Some(parent) = Path::new(path).parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent).map_err(|_| CrypteraError::IoError)?;
        }
    }
    Ok(())
}

/// Sposta un file, con fallback a copia+rimozione.
///
/// `rename` fallisce quando origine e destinazione sono su volumi diversi: su
/// iOS succede fra `TMPDIR` e una cartella ottenuta dal picker.
fn move_file(from: &Path, to: &Path) -> Result<(), CrypteraError> {
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to).map_err(|_| CrypteraError::IoError)?;
    let _ = std::fs::remove_file(from);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../CrypteraTests/Fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    #[test]
    fn core_version_riporta_il_tag() {
        assert!(core_version().contains(CORE_TAG));
    }

    #[test]
    fn read_metadata_legge_una_fixture_upstream() {
        let meta = read_metadata(fixture("v4-basic.ecf")).expect("fixture leggibile");
        assert_eq!(meta.version, 4);
        assert!(meta.k > 0 && meta.r > 0);
    }

    #[test]
    fn fixture_zlib_ha_il_flag_di_compressione() {
        let meta = read_metadata(fixture("v4-zlib-hidden.ecf")).unwrap();
        assert_eq!(meta.flags & 0x02, 0x02, "atteso FLAG_COMPRESS_ZLIB");
    }

    #[test]
    fn le_fixture_non_sono_container_tar() {
        assert!(!read_metadata(fixture("v4-basic.ecf")).unwrap().is_tar_container());
    }

    #[test]
    fn password_vuota_rifiutata_prima_di_toccare_il_file() {
        // Deve fallire con PASSWORD_REQUIRED, non con un errore di I/O: la
        // validazione precede qualunque accesso al filesystem.
        let r = verify(
            VerifyRequest {
                input_path: "/nonexistent".into(),
                password: "   ".into(),
                keyfile_path: None,
            },
            None,
            None,
        );
        assert!(matches!(r, Err(CrypteraError::PasswordRequired)), "ottenuto {r:?}");
    }

    #[test]
    fn round_trip_file_singolo() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("segreto.txt");
        let contenuto = b"contenuto di prova per il round-trip\n";
        std::fs::write(&plain, contenuto).unwrap();

        let encrypted = dir.path().join("segreto.ecf");
        let meta = encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "password-di-prova".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::Zlib,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: true,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Standard,
            },
            None,
            None,
        )
        .expect("cifratura riuscita");

        assert_eq!(meta.version, 5, "il writer corrente produce header v5");
        assert_eq!(meta.argon2_mem_kib, 64 * 1024, "profilo Standard");
        assert_eq!((meta.k, meta.r), (24, 8), "profilo integrità Standard");

        let restored = dir.path().join("restored.txt");
        decrypt(
            DecryptRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                output_path: restored.to_string_lossy().to_string(),
                password: "password-di-prova".into(),
                keyfile_path: None,
                extract_archive: false,
                keep_archive: false,
            },
            None,
            None,
        )
        .expect("decifratura riuscita");

        assert_eq!(std::fs::read(&restored).unwrap(), contenuto);
    }

    /// Su header v5 una password errata produce `HEADER_AUTH_FAILED`, non
    /// `PASSWORD_INVALID`.
    ///
    /// Motivo: il tag di autenticazione dell'header è derivato dalla master key
    /// (`auth_key = HMAC(master_key, "ECF1-HEADER-AUTH-V1")`), quindi una
    /// password sbagliata lo invalida, e quel controllo precede il record PWCHK.
    ///
    /// ⚠️ **Conseguenza per la UI.** Il desktop mappa `HEADER_AUTH_FAILED` su
    /// "Il file potrebbe essere stato manomesso": un messaggio allarmante e
    /// quasi sempre falso, dato che la causa normale è un refuso nella password.
    /// Su iOS il messaggio deve coprire onestamente entrambe le cause. Non si
    /// deve invece rimappare il codice su `PASSWORD_INVALID`: nasconderebbe le
    /// manomissioni vere.
    #[test]
    fn password_sbagliata_su_v5_da_header_auth_failed() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("a.txt");
        std::fs::write(&plain, b"x").unwrap();
        let encrypted = dir.path().join("a.ecf");

        encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "giusta".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: true,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        )
        .unwrap();

        let r = verify(
            VerifyRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                password: "sbagliata".into(),
                keyfile_path: None,
            },
            None,
            None,
        );
        assert!(matches!(r, Err(CrypteraError::HeaderAuthFailed)), "ottenuto {r:?}");
    }

    #[test]
    fn output_esistente_non_viene_sovrascritto() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("a.txt");
        std::fs::write(&plain, b"x").unwrap();
        let occupato = dir.path().join("occupato.ecf");
        std::fs::write(&occupato, b"gia qui").unwrap();

        let r = encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: occupato.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        );
        assert!(matches!(r, Err(CrypteraError::OutputExists)));
        assert_eq!(std::fs::read(&occupato).unwrap(), b"gia qui");
    }

    #[test]
    fn round_trip_cartella_con_estrazione() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("documenti");
        std::fs::create_dir_all(src.join("sub")).unwrap();
        std::fs::write(src.join("uno.txt"), b"primo").unwrap();
        std::fs::write(src.join("sub/due.txt"), b"secondo").unwrap();

        let encrypted = dir.path().join("documenti.ecf");
        let meta = encrypt(
            EncryptRequest {
                source: InputSource::Folder {
                    path: src.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::Gzip,
                skip_special_files: true,
                enable_password_check: true,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        )
        .expect("cifratura cartella riuscita");

        assert!(meta.is_tar_container(), "atteso FLAG_TAR_CONTAINER");

        let out = dir.path().join("estratto");
        decrypt(
            DecryptRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                output_path: out.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                extract_archive: true,
                keep_archive: false,
            },
            None,
            None,
        )
        .expect("estrazione riuscita");

        assert_eq!(std::fs::read(out.join("documenti/uno.txt")).unwrap(), b"primo");
        assert_eq!(
            std::fs::read(out.join("documenti/sub/due.txt")).unwrap(),
            b"secondo"
        );
    }

    #[test]
    fn estrazione_richiesta_su_file_singolo_non_fallisce() {
        // Il fix di v2.0.4: con extract_archive su un .ecf non-container si
        // deve ottenere il file, non EXTRACT_ERROR.
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("singolo.txt");
        std::fs::write(&plain, b"contenuto").unwrap();
        let encrypted = dir.path().join("singolo.ecf");

        encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        )
        .unwrap();

        let out = dir.path().join("uscita.txt");
        let meta = decrypt(
            DecryptRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                output_path: out.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                extract_archive: true,
                keep_archive: false,
            },
            None,
            None,
        )
        .expect("deve produrre il file, non un errore di estrazione");

        assert!(!meta.is_tar_container());
        assert_eq!(std::fs::read(&out).unwrap(), b"contenuto");
    }

    /// Un `.ecf` ostile non deve poter scrivere fuori dalla destinazione.
    ///
    /// Il nome del file è memorizzato **dentro** l'header: chi crea l'archivio
    /// lo sceglie liberamente, e il core non lo sanifica (valida solo UTF-8 e
    /// lunghezza). Un nome come `../../../evil.tar` o `/tmp/evil.tar` usato
    /// come componente di percorso permetterebbe una path traversal — e
    /// `Path::join` con un percorso assoluto **sostituisce** la base.
    ///
    /// Qui il file ostile si costruisce chiamando il core direttamente, perché
    /// la nostra `encrypt` non espone il nome arbitrario.
    #[test]
    fn nome_ostile_nell_header_non_scrive_fuori_dalla_destinazione() {
        let dir = tempfile::tempdir().unwrap();
        let fuori = dir.path().join("FUORI.txt");

        // Un vero TAR, così l'estrazione arriva fino in fondo.
        let contenuto = dir.path().join("dentro.txt");
        std::fs::write(&contenuto, b"payload").unwrap();
        let tar_path = dir.path().join("a.tar");
        {
            let f = std::fs::File::create(&tar_path).unwrap();
            let mut b = tar::Builder::new(f);
            b.append_path_with_name(&contenuto, "dentro.txt").unwrap();
            b.finish().unwrap();
        }

        // Nome ostile **assoluto**: è la variante deterministica, perché
        // `Path::join` con un percorso assoluto scarta la base e produce
        // esattamente questo percorso. Con una risalita relativa (`../../x`) la
        // scrittura finirebbe in un punto dipendente da dove il sistema colloca
        // le cartelle temporanee, e l'asserzione non proverebbe nulla.
        let nome_ostile = fuori.to_string_lossy().to_string();
        let encrypted = dir.path().join("ostile.ecf");
        crypto_core_rs::encrypt_file_rs_controlled(
            tar_path.to_str().unwrap(),
            encrypted.to_str().unwrap(),
            "p",
            None,
            None,
            false,
            Some(4),
            Some(2),
            None,
            Some(1),
            Some(8192),
            Some(1),
            Some(&nome_ostile),
            true, // is_tar_container
            None,
            None,
        )
        .expect("costruzione del file ostile");

        let out = dir.path().join("estratto");
        let meta = decrypt(
            DecryptRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                output_path: out.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                extract_archive: true,
                keep_archive: true, // il percorso che usa il nome
            },
            None,
            None,
        )
        .expect("l'estrazione deve riuscire");

        assert_eq!(meta.filename, nome_ostile, "il nome ostile arriva davvero dall'header");
        assert!(
            !fuori.exists(),
            "path traversal: scritto fuori dalla destinazione in {}",
            fuori.display()
        );
        assert!(out.join("dentro.txt").exists(), "il contenuto legittimo va estratto");
        // L'archivio conservato deve stare nella destinazione, col nome ridotto
        // al solo componente finale.
        assert!(
            out.join("FUORI.txt").exists(),
            "keep_archive deve restare dentro out/ col nome sanificato"
        );
    }

    #[test]
    fn basename_sicuro_neutralizza_i_percorsi() {
        use orchestration::safe_archive_basename as safe;
        assert_eq!(safe("../../evil.tar"), "evil.tar");
        assert_eq!(safe("/etc/passwd"), "passwd");
        assert_eq!(safe("a/b/c.tar.gz"), "c.tar.gz");
        assert_eq!(safe(".."), "decrypted.tar");
        assert_eq!(safe(""), "decrypted.tar");
        assert_eq!(safe("normale.tar"), "normale.tar");
    }

    #[test]
    fn compressione_dedotta_dal_nome() {
        use orchestration::archive_compression_from_name as comp;
        assert_eq!(comp("x.tar.gz"), ArchiveCompression::Gzip);
        assert_eq!(comp("x.TGZ"), ArchiveCompression::Gzip);
        assert_eq!(comp("x.tar.bz2"), ArchiveCompression::Bzip2);
        assert_eq!(comp("x.tar.xz"), ArchiveCompression::Xz);
        assert_eq!(comp("x.tar"), ArchiveCompression::None);
        // Il caso che rompe il desktop: file di lavoro senza estensione.
        assert_eq!(comp(""), ArchiveCompression::None);
    }

    /// Dimostra perché la compressione va passata esplicitamente.
    ///
    /// Il desktop decifra in un `NamedTempFile` (senza estensione) e passa quel
    /// percorso a `safe_extract_tar`, che deduce la compressione dal suffisso:
    /// un archivio gzip finisce quindi nel decoder "tar semplice" e
    /// l'estrazione fallisce. Questo test blocca quel comportamento da noi.
    #[test]
    fn archivio_compresso_si_estrae_anche_senza_estensione_nel_percorso() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("dati");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("f.txt"), b"contenuto").unwrap();

        let flags = ControlFlags::new();
        let (tmp, nome) = orchestration::create_tar(
            &src,
            ArchiveCompression::Gzip,
            true,
            &flags,
            None,
        )
        .unwrap();
        assert!(nome.ends_with(".tar.gz"));

        // Percorso senza estensione, come il temporaneo del desktop.
        let senza_estensione = dir.path().join("payload");
        std::fs::copy(tmp.path(), &senza_estensione).unwrap();

        let out = dir.path().join("out");
        std::fs::create_dir_all(&out).unwrap();
        orchestration::safe_extract_tar(
            senza_estensione.to_str().unwrap(),
            out.to_str().unwrap(),
            orchestration::archive_compression_from_name(&nome),
        )
        .expect("la compressione esplicita rende irrilevante il suffisso del percorso");

        assert_eq!(std::fs::read(out.join("dati/f.txt")).unwrap(), b"contenuto");
    }

    /// Annullare **durante** l'operazione, che è il caso reale.
    ///
    /// La cancellazione parte dal callback di progress, così il momento è
    /// deterministico e il test non dipende da un timer. Verifica anche che il
    /// token creato da Swift condivida davvero gli atomici con l'operazione in
    /// corso: se `flags_of` copiasse invece di clonare l'`Arc`, l'annullamento
    /// non avrebbe effetto e questo test fallirebbe.
    #[test]
    fn cancellazione_durante_l_operazione_non_lascia_output_parziale() {
        use std::sync::Mutex;

        struct CancellaAlPrimoProgress {
            token: Mutex<Option<Arc<CancelToken>>>,
        }
        impl ProgressListener for CancellaAlPrimoProgress {
            fn on_progress(&self, _stage: String, _done: u64, _total: u64) {
                if let Some(t) = self.token.lock().unwrap().take() {
                    t.cancel();
                }
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("grande.bin");
        std::fs::write(&plain, vec![7u8; 8 * 1024 * 1024]).unwrap();
        let out = dir.path().join("out.ecf");

        let token = CancelToken::new();
        let listener = Arc::new(CancellaAlPrimoProgress {
            token: Mutex::new(Some(token.clone())),
        });

        let r = encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: out.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            Some(listener),
            Some(token),
        );

        assert!(matches!(r, Err(CrypteraError::Cancelled)), "ottenuto {r:?}");
        // SPEC §11.1: nessun output parziale deve restare sul filesystem, dove
        // sembrerebbe un file valido. Il core scrive su un temporaneo e rinomina
        // atomicamente, quindi la garanzia esiste — questo test la blocca.
        assert!(
            !out.exists(),
            "un'operazione annullata non deve lasciare un .ecf parziale"
        );
    }

    #[test]
    fn cartella_inesistente_non_produce_un_archivio_vuoto() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("vuoto.ecf");
        let r = encrypt(
            EncryptRequest {
                source: InputSource::Folder {
                    path: dir.path().join("non-esiste").to_string_lossy().to_string(),
                },
                output_path: out.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: true, // scarterebbe l'errore di walkdir
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        );
        assert!(matches!(r, Err(CrypteraError::IoError)), "ottenuto {r:?}");
        assert!(!out.exists(), "non deve restare un archivio vuoto cifrato");
    }

    #[test]
    fn cancellazione_prima_dell_avvio_interrompe_subito() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("grande.bin");
        std::fs::write(&plain, vec![7u8; 4 * 1024 * 1024]).unwrap();

        let token = CancelToken::new();
        token.cancel(); // già annullato prima di partire

        let r = encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: dir.path().join("out.ecf").to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            Some(token),
        );
        assert!(matches!(r, Err(CrypteraError::Cancelled)), "ottenuto {r:?}");
    }

    #[test]
    fn keyfile_sbagliato_non_decifra() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("a.txt");
        std::fs::write(&plain, b"x").unwrap();
        let kf1 = dir.path().join("k1.bin");
        let kf2 = dir.path().join("k2.bin");
        std::fs::write(&kf1, b"chiave-uno").unwrap();
        std::fs::write(&kf2, b"chiave-due").unwrap();
        let encrypted = dir.path().join("a.ecf");

        encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: Some(kf1.to_string_lossy().to_string()),
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: true,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        )
        .unwrap();

        let r = verify(
            VerifyRequest {
                input_path: encrypted.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: Some(kf2.to_string_lossy().to_string()),
            },
            None,
            None,
        );
        assert!(matches!(r, Err(CrypteraError::HeaderAuthFailed)), "ottenuto {r:?}");
    }

    /// Cifra un file di prova e restituisce il percorso del `.ecf`.
    fn cifra_di_prova(dir: &Path, nome: &str) -> String {
        let plain = dir.join(format!("{nome}.txt"));
        std::fs::write(&plain, b"contenuto").unwrap();
        let encrypted = dir.join(format!("{nome}.ecf"));
        encrypt(
            EncryptRequest {
                source: InputSource::File {
                    path: plain.to_string_lossy().to_string(),
                },
                output_path: encrypted.to_string_lossy().to_string(),
                password: "p".into(),
                keyfile_path: None,
                payload_compression: PayloadCompression::None,
                archive_compression: ArchiveCompression::None,
                skip_special_files: false,
                enable_password_check: false,
                hide_filename: false,
                security_profile: SecurityProfile::Standard,
                integrity_profile: IntegrityProfile::Low,
            },
            None,
            None,
        )
        .unwrap();
        encrypted.to_string_lossy().to_string()
    }

    fn verifica(path: &str) -> Result<MetaInfo, CrypteraError> {
        verify(
            VerifyRequest {
                input_path: path.to_string(),
                password: "p".into(),
                keyfile_path: None,
            },
            None,
            None,
        )
    }

    /// Il formato memorizza una **seconda copia** dell'Header Body nel trailer
    /// finale (`ECCT`, SPEC §16.1), e il core la usa quando quella iniziale non
    /// supera il CRC.
    ///
    /// Corrompere un solo header quindi **non** deve produrre un errore: il file
    /// si recupera. È una proprietà voluta del formato, e va verificata — se un
    /// giorno smettesse di valere, i file danneggiati diventerebbero illeggibili
    /// senza che nulla lo segnali.
    ///
    /// Nota per M7: SPEC §13.1 punto 5 chiede di "modificare un byte
    /// dell'header e attendersi HEADER_AUTH_FAILED". Preso alla lettera è
    /// impreciso — con una sola copia corrotta il risultato corretto è il
    /// recupero, come verifica questo test.
    #[test]
    fn header_iniziale_corrotto_viene_recuperato_dal_trailer() {
        let dir = tempfile::tempdir().unwrap();
        let path = cifra_di_prova(dir.path(), "recupero");

        // Un byte dentro l'Header Body iniziale (offset 21 = nonce_base).
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[6 + 21] ^= 0xFF;
        std::fs::write(&path, &bytes).unwrap();

        let meta = verifica(&path).expect("il trailer deve permettere il recupero");
        assert_eq!(meta.version, 5);
        assert_eq!(meta.filename, "recupero.txt");
    }

    /// Manomettere il tag di autenticazione in **entrambe** le copie
    /// dell'header dà `HEADER_AUTH_FAILED`.
    ///
    /// Il tag non è coperto dal CRC (che copre magic + hdr_len + Header Body),
    /// quindi alterarlo supera il controllo di integrità e fa fallire
    /// esattamente l'autenticazione — che è il caso che SPEC §13.1 punto 5
    /// intende davvero.
    #[test]
    fn auth_tag_manomesso_in_entrambe_le_copie_da_header_auth_failed() {
        let dir = tempfile::tempdir().unwrap();
        let path = cifra_di_prova(dir.path(), "manomesso");

        let mut bytes = std::fs::read(&path).unwrap();
        let hdr_len = u16::from_be_bytes([bytes[4], bytes[5]]) as usize;

        // Copia iniziale: magic(4) + hdr_len(2) + body + hdr_crc(4) + tag(16)
        let start_tag = 6 + hdr_len + 4;
        // Copia nel trailer: ... + hdr_crc(4) + tag(16) + hdr_len(2) + "ECCT"(4)
        let trailer_tag = bytes.len() - 4 - 2 - 16;

        for off in [start_tag, trailer_tag] {
            for b in &mut bytes[off..off + 16] {
                *b ^= 0xFF;
            }
        }
        std::fs::write(&path, &bytes).unwrap();

        let r = verifica(&path);
        assert!(
            matches!(r, Err(CrypteraError::HeaderAuthFailed)),
            "una manomissione del tag non deve passare inosservata, ottenuto {r:?}"
        );
    }
}
