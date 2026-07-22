//! Orchestrazione portata da `src-tauri/src/main.rs` di Cryptera v2.0.4
//! (SPEC §2.2 regola 2).
//!
//! Questa logica determina il **contenuto** del file prodotto — nomi dentro il
//! TAR, suffissi, parametri dei profili — quindi deve stare accanto al core e
//! non in Swift. Ogni divergenza qui produce file che il desktop apre in modo
//! diverso, o non apre affatto.

use std::path::{Path, PathBuf};

use crypto_core_rs::ControlFlags;
use tempfile::NamedTempFile;

use crate::errors::CrypteraError;

// ─── Profili (SPEC §5.2) ───────────────────────────────────────────
//
// Valori trascritti da `sec_profile_params` / `int_profile_params`
// dell'upstream. Devono restare identici o i file avranno parametri diversi
// fra desktop e mobile. I test in fondo al modulo li verificano.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SecurityProfile {
    Standard,
    Strong,
    Paranoid,
}

impl SecurityProfile {
    /// `(argon2_time, argon2_mem_kib, argon2_par)`
    pub fn params(self) -> (u32, u32, u16) {
        match self {
            Self::Standard => (3, 64 * 1024, 2),
            Self::Strong => (6, 256 * 1024, 4),
            Self::Paranoid => (10, 512 * 1024, 8),
        }
    }

    /// Memoria richiesta da Argon2, in byte.
    ///
    /// Serve a Swift per il confronto con `os_proc_available_memory()` prima di
    /// avviare l'operazione (SPEC §11.2): su iOS il superamento del limite
    /// jetsam non è un'eccezione catturabile, è la morte del processo.
    pub fn memory_bytes(self) -> u64 {
        let (_, mem_kib, _) = self.params();
        u64::from(mem_kib) * 1024
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum IntegrityProfile {
    Low,
    Standard,
    High,
    Max,
}

impl IntegrityProfile {
    /// `(k, r)`
    pub fn params(self) -> (u16, u16) {
        match self {
            Self::Low => (28, 4),
            Self::Standard => (24, 8),
            Self::High => (12, 12),
            Self::Max => (8, 24),
        }
    }

    /// Overhead di parità in percentuale: `r / k`.
    ///
    /// La UI deve mostrarlo insieme alla dimensione finale stimata, altrimenti
    /// `Max` sorprende l'utente con un file 4× più grande (SPEC §8.2).
    pub fn parity_overhead_percent(self) -> u32 {
        let (k, r) = self.params();
        u32::from(r) * 100 / u32::from(k)
    }
}

// ─── Compressione ──────────────────────────────────────────────────

/// Compressione applicata al payload prima della cifratura.
///
/// Mutuamente esclusive nel formato: ZLIB (0x02) e LZMA (0x08) non possono
/// coesistere (SPEC §16.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PayloadCompression {
    None,
    Zlib,
    Lzma,
}

impl PayloadCompression {
    /// Stringa attesa da `crypto_core_rs`, o `None` per nessuna compressione.
    pub(crate) fn core_arg(self) -> Option<&'static str> {
        match self {
            Self::None => None,
            Self::Zlib => Some("zlib"),
            Self::Lzma => Some("lzma"),
        }
    }
}

/// Compressione dell'archivio TAR, per la cifratura di cartelle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ArchiveCompression {
    None,
    Gzip,
    Bzip2,
    Xz,
}

impl ArchiveCompression {
    /// Suffisso del nome archivio. Finisce **dentro** il file cifrato come nome
    /// originale, quindi va mantenuto identico all'upstream.
    pub(crate) fn suffix(self) -> &'static str {
        match self {
            Self::None => ".tar",
            Self::Gzip => ".tar.gz",
            Self::Bzip2 => ".tar.bz2",
            Self::Xz => ".tar.xz",
        }
    }
}

// ─── TAR ───────────────────────────────────────────────────────────

/// Nome base dell'archivio, derivato dalla cartella.
///
/// Fallback per percorsi senza componente finale (es. la root del filesystem).
pub(crate) fn tar_base_name(folder: &Path) -> String {
    let name = folder
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    if name.is_empty() {
        "archive".to_string()
    } else {
        name
    }
}

/// Costruisce un TAR temporaneo dalla cartella, restituendo il file e il nome
/// dell'archivio (base + suffisso).
///
/// Su iOS il temporaneo finisce in `TMPDIR`, dentro il container dell'app: lo
/// spazio va verificato **prima** di chiamare questa funzione (SPEC §11.4).
pub(crate) fn create_tar(
    folder: &Path,
    comp: ArchiveCompression,
    skip_special: bool,
    ctrl: &ControlFlags,
    mut progress: Option<&mut dyn FnMut(u64)>,
) -> Result<(NamedTempFile, String), CrypteraError> {
    let base_name = tar_base_name(folder);
    let tmp = NamedTempFile::new().map_err(|_| CrypteraError::IoError)?;

    let file = tmp.reopen().map_err(|_| CrypteraError::IoError)?;
    let writer: Box<dyn std::io::Write> = match comp {
        ArchiveCompression::Gzip => Box::new(flate2::write::GzEncoder::new(
            file,
            flate2::Compression::default(),
        )),
        ArchiveCompression::Bzip2 => Box::new(bzip2::write::BzEncoder::new(
            file,
            bzip2::Compression::default(),
        )),
        // Livello 6 come l'upstream: cambiarlo cambierebbe i byte prodotti.
        ArchiveCompression::Xz => Box::new(xz2::write::XzEncoder::new(file, 6)),
        ArchiveCompression::None => Box::new(file),
    };

    let mut builder = tar::Builder::new(writer);
    let base_prefix = PathBuf::from(&base_name);

    let mut count = 0u64;
    for entry in walkdir::WalkDir::new(folder).follow_links(false) {
        ctrl.wait_if_paused().map_err(CrypteraError::from)?;

        count += 1;
        if count % 10 == 0 {
            if let Some(cb) = progress.as_deref_mut() {
                cb(count);
            }
        }

        let entry = match entry {
            Ok(e) => e,
            Err(_) => {
                if skip_special {
                    continue;
                }
                return Err(CrypteraError::TarError);
            }
        };

        if skip_special && entry.file_type().is_symlink() {
            continue;
        }

        let path = entry.path();
        let rel = match path.strip_prefix(folder) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let tar_path = if rel.as_os_str().is_empty() {
            base_prefix.clone()
        } else {
            base_prefix.join(rel)
        };

        if entry.file_type().is_dir() {
            builder
                .append_dir(&tar_path, path)
                .map_err(|_| CrypteraError::TarError)?;
        } else if entry.file_type().is_file() {
            builder
                .append_path_with_name(path, &tar_path)
                .map_err(|_| CrypteraError::TarError)?;
        }
    }

    if let Some(cb) = progress.as_mut() {
        cb(count);
    }

    builder.finish().map_err(|_| CrypteraError::TarError)?;
    Ok((tmp, format!("{base_name}{}", comp.suffix())))
}

/// Estrae un TAR, rifiutando i percorsi che uscirebbero dalla cartella di
/// destinazione.
///
/// La protezione contro lo **Zip Slip** è portata dall'upstream e non va
/// rimossa: un archivio ostile con `../` scriverebbe altrove nel container.
pub(crate) fn safe_extract_tar(tar_path: &str, out_dir: &str) -> Result<(), CrypteraError> {
    let out_dir = Path::new(out_dir).to_path_buf();
    let file = std::fs::File::open(tar_path).map_err(|_| CrypteraError::IoError)?;

    // Il tipo di compressione si deduce dal suffisso, come nell'upstream.
    let lower = tar_path.to_lowercase();
    let decoder: Box<dyn std::io::Read> = if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        Box::new(flate2::read::GzDecoder::new(file))
    } else if lower.ends_with(".tar.bz2") || lower.ends_with(".tbz2") {
        Box::new(bzip2::read::BzDecoder::new(file))
    } else if lower.ends_with(".tar.xz") || lower.ends_with(".txz") {
        Box::new(xz2::read::XzDecoder::new(file))
    } else {
        Box::new(file)
    };

    let mut archive = tar::Archive::new(decoder);
    for entry in archive.entries().map_err(|_| CrypteraError::ExtractError)? {
        let mut entry = entry.map_err(|_| CrypteraError::ExtractError)?;
        let path = entry.path().map_err(|_| CrypteraError::ExtractError)?;

        if path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(CrypteraError::ExtractError);
        }
        if path.is_absolute() {
            continue;
        }

        let dest = out_dir.join(path.as_ref());
        entry
            .unpack(&dest)
            .map_err(|_| CrypteraError::ExtractError)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // I valori di SPEC §5.2 devono essere verificati da un test, non solo
    // scritti: sono gli stessi assert presenti nell'upstream.

    #[test]
    fn profili_di_sicurezza_stabili() {
        assert_eq!(SecurityProfile::Standard.params(), (3, 64 * 1024, 2));
        assert_eq!(SecurityProfile::Strong.params(), (6, 256 * 1024, 4));
        assert_eq!(SecurityProfile::Paranoid.params(), (10, 512 * 1024, 8));
    }

    #[test]
    fn profili_di_integrita_stabili() {
        assert_eq!(IntegrityProfile::Low.params(), (28, 4));
        assert_eq!(IntegrityProfile::Standard.params(), (24, 8));
        assert_eq!(IntegrityProfile::High.params(), (12, 12));
        assert_eq!(IntegrityProfile::Max.params(), (8, 24));
    }

    #[test]
    fn paranoid_richiede_512_mib() {
        // È la soglia che rende Paranoid rischioso su iOS (SPEC §11.2).
        assert_eq!(SecurityProfile::Paranoid.memory_bytes(), 512 * 1024 * 1024);
        assert_eq!(SecurityProfile::Standard.memory_bytes(), 64 * 1024 * 1024);
    }

    #[test]
    fn overhead_di_parita_come_da_spec() {
        assert_eq!(IntegrityProfile::Low.parity_overhead_percent(), 14);
        assert_eq!(IntegrityProfile::Standard.parity_overhead_percent(), 33);
        assert_eq!(IntegrityProfile::High.parity_overhead_percent(), 100);
        assert_eq!(IntegrityProfile::Max.parity_overhead_percent(), 300);
    }

    #[test]
    fn suffissi_archivio_stabili() {
        assert_eq!(ArchiveCompression::None.suffix(), ".tar");
        assert_eq!(ArchiveCompression::Gzip.suffix(), ".tar.gz");
        assert_eq!(ArchiveCompression::Bzip2.suffix(), ".tar.bz2");
        assert_eq!(ArchiveCompression::Xz.suffix(), ".tar.xz");
    }

    #[test]
    fn nome_base_con_fallback_per_la_root() {
        assert_eq!(tar_base_name(Path::new("/home/user/docs")), "docs");
        assert_eq!(tar_base_name(Path::new("/")), "archive");
    }

    #[test]
    fn stringhe_compressione_payload_come_attese_dal_core() {
        assert_eq!(PayloadCompression::None.core_arg(), None);
        assert_eq!(PayloadCompression::Zlib.core_arg(), Some("zlib"));
        assert_eq!(PayloadCompression::Lzma.core_arg(), Some("lzma"));
    }
}
