# Cryptera iOS — Specifica di implementazione

> **Documento di lavoro per la costruzione di `Cryptera-iOS`, app SwiftUI nativa.**
> Destinatario: una sessione Claude Cowork che parte da repo vuoto.
> Versione spec: 1.0 — allineata a Cryptera desktop **2.0.3**, formato **ECF1 header v5**.

---

## Indice

1. [Contesto e obiettivo](#1-contesto-e-obiettivo)
2. [Decisione architetturale](#2-decisione-architetturale)
3. [Struttura del repository](#3-struttura-del-repository)
4. [Fase 1 — XCFramework dal core Rust](#4-fase-1--xcframework-dal-core-rust)
5. [Fase 2 — Il crate FFI e la superficie API](#5-fase-2--il-crate-ffi-e-la-superficie-api)
6. [Fase 3 — Modello di accesso ai file su iOS](#6-fase-3--modello-di-accesso-ai-file-su-ios)
7. [Fase 4 — Livello Swift sopra l'FFI](#7-fase-4--livello-swift-sopra-lffi)
8. [Fase 5 — Interfaccia SwiftUI](#8-fase-5--interfaccia-swiftui)
9. [Matrice di parità funzionale](#9-matrice-di-parità-funzionale)
10. [Codici di errore e localizzazione](#10-codici-di-errore-e-localizzazione)
11. [Vincoli iOS specifici](#11-vincoli-ios-specifici)
12. [Sicurezza](#12-sicurezza)
13. [Testing](#13-testing)
14. [Distribuzione](#14-distribuzione)
15. [Milestone](#15-milestone)
16. [Appendice — riferimento formato ECF1](#16-appendice--riferimento-formato-ecf1)

---

## 1. Contesto e obiettivo

**Cryptera** è un'applicazione desktop open source (MIT OR Apache-2.0) per la
cifratura locale di file e cartelle. Repo: `https://github.com/gh0st032395/Cryptera`.

Stack attuale:

| Livello | Tecnologia |
|---|---|
| Crypto core | Rust — crate `crypto_core_rs` (`src/lib.rs`, ~1900 righe) |
| Backend app | Rust — Tauri v2.5 (`src-tauri/`) |
| Frontend | HTML + CSS + ES Modules, nessun bundler (`ui/`) |

Primitive: **AES-256-GCM** (AEAD), **Argon2id** (KDF), **Reed-Solomon su GF(256)**
(forward error correction), compressione **zlib / LZMA2** pre-cifratura,
container **TAR** per le cartelle.

**Obiettivo di questo progetto:** un'app iOS nativa in SwiftUI che legge e scrive
lo stesso formato `.ecf`, con parità funzionale rispetto al desktop nei limiti
imposti dalla sandbox iOS.

**Requisito non negoziabile:** i file prodotti su iOS devono essere decifrabili
dal desktop e viceversa, byte-per-byte compatibili. Nessuna deroga.

---

## 2. Decisione architetturale

### 2.1 Cosa NON fare

**Non reimplementare la crittografia in Swift.** Questa decisione è già stata
presa e va rispettata. Motivazione, per evitare che venga rimessa in
discussione a metà progetto:

- **Reed-Solomon GF(256), polinomio primitivo 0x11D, sistematico.** Nessuna
  libreria Apple lo fornisce. Reimplementarlo significa replicare esattamente
  la matrice generatrice e l'aritmetica di campo. Una divergenza sottile non
  produce un crash: produce file che si cifrano correttamente ma la cui parità
  non recupera nulla in caso di corruzione. Il bug si manifesta solo il giorno
  in cui il recupero serve davvero.
- **Argon2id.** Assente da CryptoKit.
- **LZMA2.** Assente dai framework Apple (Compression framework copre zlib,
  LZFSE, LZ4, LZMA solo in una variante non compatibile con xz).
- **Superficie di audit.** Duplicare il core significa duplicare la superficie
  di revisione crittografica su due linguaggi.

Solo **AES-256-GCM**, **HMAC-SHA256** e **SHA-256** avrebbero un equivalente
diretto in CryptoKit — cioè la parte facile.

### 2.2 Cosa fare

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI  —  100% nativo, nessuna webview               │
│  Views · ViewModels · Navigation · Localizable.strings  │
├─────────────────────────────────────────────────────────┤
│  CrypteraKit  (Swift)                                   │
│  Wrapper idiomatico: async/await, URL, security scopes  │
├─────────────────────────────────────────────────────────┤
│  UniFFI bindings  (generati)                            │
├─────────────────────────────────────────────────────────┤
│  cryptera-ffi  (Rust)  — crate wrapper                  │
│  Orchestrazione: tar, compressione, progress, cancel    │
├─────────────────────────────────────────────────────────┤
│  crypto_core_rs  (Rust, invariato, da git tag)          │
│  AES-256-GCM · Argon2id · Reed-Solomon · Header v5      │
└─────────────────────────────────────────────────────────┘
     ↑ tutto sotto SwiftUI è compilato in CrypteraCore.xcframework
```

**Regole:**

1. `crypto_core_rs` è consumato **come dipendenza git con tag pinnato**, mai
   copiato, mai forkato. Se serve una modifica al core, va fatta upstream nel
   repo Cryptera e il tag va bumpato qui.
2. Tutta la logica di orchestrazione che oggi vive in `src-tauri/src/main.rs`
   (creazione TAR, scelta compressione, mapping errori, profili di sicurezza)
   va **riscritta in `cryptera-ffi`**, non in Swift. Motivo: è logica che
   determina il contenuto del file, quindi deve stare accanto al core e essere
   testabile con gli stessi test.
3. Swift si occupa **solo** di: UI, accesso file iOS (security-scoped URL),
   ciclo di vita, presentazione errori. Nessuna logica di formato in Swift.

### 2.3 Perché UniFFI e non FFI C manuale

`crypto_core_rs` espone signature come:

```rust
progress: Option<&mut dyn FnMut(&str, u64, u64)>
```

che non sono esprimibili in C. UniFFI risolve tre cose che altrimenti scriveresti
a mano e con bug:

- **Result → `throws` Swift**, con enum di errore tipizzato.
- **Callback interfaces** per il progress (Swift implementa un protocollo, Rust
  lo chiama).
- **Oggetti con `Arc`** per il token di cancellazione condiviso tra thread.

Versione: UniFFI **0.28+** (procmacro mode, senza file `.udl`).

---

## 3. Struttura del repository

```
Cryptera-iOS/
├── README.md
├── SPEC.md                          ← questo documento
├── LICENSE-MIT
├── LICENSE-APACHE                   ← stessa doppia licenza dell'upstream
├── .gitignore
├── .github/
│   └── workflows/
│       ├── rust.yml                 ← test + build xcframework
│       └── ios.yml                  ← build app + test UI
│
├── rust/
│   ├── Cargo.toml                   ← [workspace]
│   ├── Cargo.lock                   ← committato
│   └── cryptera-ffi/
│       ├── Cargo.toml
│       ├── build.rs
│       └── src/
│           ├── lib.rs               ← superficie UniFFI
│           ├── orchestration.rs     ← tar, compressione, profili
│           ├── errors.rs            ← mapping CoreError → CrypteraError
│           └── control.rs           ← CancelToken
│
├── scripts/
│   ├── build-xcframework.sh         ← build release per device+sim
│   └── bootstrap.sh                 ← rustup targets, uniffi-bindgen
│
├── Frameworks/
│   └── .gitkeep                     ← XCFramework generato, NON committato
│
├── Cryptera/                        ← target app
│   ├── CrypteraApp.swift
│   ├── Info.plist
│   ├── Cryptera.entitlements
│   ├── Core/
│   │   ├── CrypteraEngine.swift     ← facciata async/await su UniFFI
│   │   ├── FileAccess.swift         ← security-scoped URL, bookmarks
│   │   ├── DocumentTypes.swift      ← UTType .ecf
│   │   └── Generated/               ← output uniffi-bindgen, NON committato
│   ├── Features/
│   │   ├── Encrypt/
│   │   ├── Decrypt/
│   │   ├── Verify/
│   │   ├── Batch/
│   │   ├── Audit/
│   │   └── Settings/
│   ├── DesignSystem/
│   │   ├── Theme.swift
│   │   └── Components/
│   └── Resources/
│       ├── Assets.xcassets
│       ├── en.lproj/Localizable.strings
│       └── it.lproj/Localizable.strings
│
└── CrypteraTests/
    ├── FormatCompatTests.swift      ← contro fixtures dell'upstream
    ├── Fixtures/                    ← copiati da Cryptera/tests/fixtures/
    └── EngineTests.swift
```

### 3.1 Note sulla struttura

- **`Frameworks/` e `Core/Generated/` non vanno committati.** Sono artefatti di
  build. Vanno in `.gitignore` e generati da `scripts/build-xcframework.sh`.
  Committarli sembra comodo e diventa la fonte di ogni divergenza silenziosa
  fra quello che gira e quello che è nel repo.
- **`rust/Cargo.lock` va committato** (è un binario finale, non una libreria).
- **Progetto Xcode:** valutare **XcodeGen** o **Tuist** con un `project.yml`
  committato al posto del `.xcodeproj`. I file `.pbxproj` producono conflitti
  di merge illeggibili. Se si preferisce il `.xcodeproj` classico, aggiungere
  `*.xcuserdatad/` e `xcuserdata/` al `.gitignore`.

### 3.2 `.gitignore` minimo

```gitignore
# macOS
.DS_Store

# Xcode
build/
DerivedData/
*.xcuserstate
xcuserdata/
*.xcscmblueprint
*.moved-aside

# Rust
rust/target/

# Artefatti generati — MAI committare
Frameworks/*.xcframework
Cryptera/Core/Generated/

# Secrets
*.p12
*.mobileprovision
ExportOptions.plist
```

> Nota per chi implementa: il repo Cryptera upstream ha un `.gitignore` che è
> un template Python (contiene `__pycache__`, Django, Flask). Non copiarlo.

---

## 4. Fase 1 — XCFramework dal core Rust

**Questa è la fase a rischio più alto. Va completata e verificata prima di
scrivere una singola view SwiftUI.**

### 4.1 Spike iniziale — bloccante

Prima di qualunque altra cosa, verificare che il core compili per iOS:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --release --target aarch64-apple-ios
```

**Rischio noto:** `crypto_core_rs` dipende da **`xz2`**, che è un binding a
`liblzma` (C) via `lzma-sys`. Il crate `cc` gestisce i target iOS, ma questa è
la rottura classica nelle cross-compilazioni verso iOS. Analogamente `bzip2`
(usato dall'orchestrazione TAR) è un binding C.

**Esiti possibili e come procedere:**

| Esito | Azione |
|---|---|
| Compila | Procedere. Nessuna limitazione funzionale. |
| `xz2` non compila | **Non rinunciare a LZMA senza valutare l'impatto.** Il flag `HDR_FLAG_COMPRESS_LZMA` (0x08) è parte del formato: senza LZMA l'app iOS non può decifrare file compressi LZMA creati su desktop. Prima tentare: `CC`/`AR` espliciti verso l'SDK iOS, `IPHONEOS_DEPLOYMENT_TARGET`. In ultima istanza valutare un crate LZMA in Rust puro (`lzma-rs`) per il solo percorso di **decompressione**, che è quello necessario alla compatibilità in lettura. |
| `bzip2` non compila | Impatto minore: bzip2 è solo una delle opzioni di compressione TAR in scrittura. Si può degradare a gzip/xz su iOS senza rompere la compatibilità. |

**Documentare l'esito di questo spike in `README.md` prima di proseguire.**

### 4.2 Configurazione del crate

`rust/cryptera-ffi/Cargo.toml`:

```toml
[package]
name = "cryptera-ffi"
version = "0.1.0"
edition = "2021"
license = "MIT OR Apache-2.0"

[lib]
crate-type = ["staticlib", "cdylib", "lib"]
name = "cryptera_ffi"

[dependencies]
crypto_core_rs = { git = "https://github.com/gh0st032395/Cryptera", tag = "v2.0.3" }
uniffi = { version = "0.28", features = ["cli"] }
tar = "0.4"
flate2 = "1.0"
xz2 = "0.1"
tempfile = "3.10"
walkdir = "2.5"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
thiserror = "2"

[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

> **Attenzione al path della dipendenza git.** Nel repo Cryptera, `crypto_core_rs`
> è il crate alla **root** del repository (non in una sottocartella), quindi
> `git = "..."` funziona direttamente. È in valutazione upstream un refactor a
> Cargo workspace che sposterebbe il crate in `crates/core/`: se accade, andrà
> aggiunto `package = "crypto_core_rs"` e il tag andrà aggiornato.

### 4.3 Script di build

`scripts/build-xcframework.sh` deve:

1. Buildare `--release` per `aarch64-apple-ios` (device).
2. Buildare `--release` per `aarch64-apple-ios-sim` e `x86_64-apple-ios`.
3. `lipo -create` le due librerie simulatore in una fat lib.
4. Generare i binding: `cargo run --bin uniffi-bindgen generate --library <path> --language swift --out-dir ...`
5. Riorganizzare l'output: `cryptera_ffiFFI.h` + `module.modulemap` in una
   cartella headers; `cryptera_ffi.swift` copiato in `Cryptera/Core/Generated/`.
6. `xcodebuild -create-xcframework -library ... -headers ... -output Frameworks/CrypteraCore.xcframework`

Lo script deve essere **idempotente** e fallire rumorosamente (`set -euo pipefail`).

**Ottimizzazioni release** in `rust/Cargo.toml`:

```toml
[profile.release]
opt-level = 3
lto = true
codegen-units = 1
panic = "abort"
strip = "symbols"
```

> `panic = "abort"` è corretto qui: un panic attraverso il confine FFI è
> comunque undefined behaviour. Ma vedi §5.4 — ogni entry point FFI deve
> comunque catturare i panic prima che arrivino al confine.

---

## 5. Fase 2 — Il crate FFI e la superficie API

### 5.1 Tipi esposti

```rust
// ─── Input ───────────────────────────────────────────────

#[derive(uniffi::Enum)]
pub enum InputSource {
    File   { path: String },
    Folder { path: String },
}

#[derive(uniffi::Enum)]
pub enum PayloadCompression { None, Zlib, Lzma }

#[derive(uniffi::Enum)]
pub enum ArchiveCompression { None, Gzip, Bzip2, Xz }

#[derive(uniffi::Enum)]
pub enum SecurityProfile { Standard, Strong, Paranoid }

#[derive(uniffi::Enum)]
pub enum IntegrityProfile { Low, Standard, High, Max }

#[derive(uniffi::Record)]
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

#[derive(uniffi::Record)]
pub struct DecryptRequest {
    pub input_path: String,
    pub output_path: String,
    pub password: String,
    pub keyfile_path: Option<String>,
    pub extract_archive: bool,
    pub keep_archive: bool,
}

#[derive(uniffi::Record)]
pub struct VerifyRequest {
    pub input_path: String,
    pub password: String,
    pub keyfile_path: Option<String>,
}

// ─── Output ──────────────────────────────────────────────

#[derive(uniffi::Record)]
pub struct MetaInfo {
    pub filename: String,       // vuoto se v5 con nome cifrato e senza password
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
```

`MetaInfo` rispecchia esattamente `crypto_core_rs::MetaInfo` e il DTO Tauri
`MetaInfoDto`. **Non aggiungere né rimuovere campi** senza allineare l'upstream.

### 5.2 Profili — valori esatti

Trascritti da `src-tauri/src/main.rs`. Devono restare identici o i file avranno
parametri diversi fra desktop e mobile.

**Profilo di sicurezza** → `(argon2_time, argon2_mem_kib, argon2_par)`:

| Profilo | time | mem (KiB) | par | mem effettiva |
|---|---|---|---|---|
| `Standard` (default) | 3 | 65 536 | 2 | 64 MiB |
| `Strong` | 6 | 262 144 | 4 | 256 MiB |
| `Paranoid` | 10 | 524 288 | 8 | **512 MiB** |

> ⚠️ **Vedi §11.2.** `Paranoid` a 512 MiB è a rischio jetsam su iOS. Va gestito,
> non copiato ciecamente.

**Profilo di integrità** → `(k, r)`:

| Profilo | k | r | Overhead parità |
|---|---|---|---|
| `Low` | 28 | 4 | ~14% |
| `Standard` (default) | 24 | 8 | ~33% |
| `High` | 12 | 12 | 100% |
| `Max` | 8 | 24 | 300% |

`shard_size` resta al default **16384**.

### 5.3 Funzioni

```rust
#[uniffi::export(callback_interface)]
pub trait ProgressListener: Send + Sync {
    fn on_progress(&self, stage: String, done: u64, total: u64);
}

#[derive(uniffi::Object)]
pub struct CancelToken { /* wrappa crypto_core_rs::ControlFlags */ }

#[uniffi::export]
impl CancelToken {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self>;
    pub fn cancel(&self);
    pub fn set_paused(&self, paused: bool);
    pub fn is_cancelled(&self) -> bool;
}

#[uniffi::export]
pub fn encrypt(
    request: EncryptRequest,
    listener: Option<Box<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError>;

#[uniffi::export]
pub fn decrypt(
    request: DecryptRequest,
    listener: Option<Box<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError>;

#[uniffi::export]
pub fn verify(
    request: VerifyRequest,
    listener: Option<Box<dyn ProgressListener>>,
    token: Option<Arc<CancelToken>>,
) -> Result<MetaInfo, CrypteraError>;

/// Legge l'header senza password. Non deriva chiavi, non autentica.
/// Su file v5 con nome cifrato, `filename` torna vuoto: è atteso.
#[uniffi::export]
pub fn read_metadata(path: String) -> Result<MetaInfo, CrypteraError>;

#[uniffi::export]
pub fn core_version() -> String;
```

Le `stage` string emesse dal progress dell'upstream vanno mappate a un enum
tipizzato lato Swift, non mostrate grezze all'utente.

### 5.4 Regole di implementazione

- **Panic barrier.** Ogni funzione `#[uniffi::export]` deve avvolgere il corpo
  in `std::panic::catch_unwind` e convertire un panic in
  `CrypteraError::Internal`. Un panic che attraversa il confine FFI è UB.
- **Password.** Il parametro arriva come `String` da Swift. Nel crate FFI va
  immediatamente spostato in `secrecy::Secret<String>` o `Zeroizing<String>`.
  Non loggarlo mai, nemmeno in debug. Vedi §12.1 per i limiti di questa
  garanzia.
- **Thread pool.** `crypto_core_rs` usa `rayon`. All'inizializzazione del
  modulo, limitare il pool: `ThreadPoolBuilder::new().num_threads(n)` con
  `n = min(activeProcessorCount, 4)`, passato da Swift. Su iPhone saturare
  tutti i core scalda il device e fa throttling termico, peggiorando i tempi.
- **File temporanei.** L'orchestrazione TAR usa `NamedTempFile`. Su iOS
  `TMPDIR` è nel container dell'app: il TAR intermedio di una cartella grande
  può occupare parecchio spazio. Verificare lo spazio disponibile **prima** di
  iniziare (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`) e
  fallire con un errore chiaro invece che a metà operazione.

---

## 6. Fase 3 — Modello di accesso ai file su iOS

**Questa sezione è la differenza concettuale principale rispetto al desktop.
Va letta prima di progettare le schermate.**

Sul desktop Cryptera assume un filesystem libero: si sceglie un percorso, si
scrive l'output accanto all'input. Su iOS questo non esiste. Ogni accesso fuori
dal container dell'app passa da un picker e da un **security-scoped URL**.

### 6.1 Regola fondamentale

Il core Rust accetta **percorsi come stringa**. Quindi Swift deve:

1. Ottenere l'URL dal picker.
2. Chiamare `url.startAccessingSecurityScopedResource()`.
3. Passare `url.path` a Rust.
4. **Mantenere lo scope aperto per tutta la durata dell'operazione.**
5. `url.stopAccessingSecurityScopedResource()` in un `defer`.

Il punto 4 è quello che si sbaglia: se lo scope si chiude mentre Rust sta
ancora leggendo, si ottengono `IO_ERROR` intermittenti e apparentemente casuali
su file grandi. Incapsulare il pattern in un unico helper e non duplicarlo:

```swift
func withSecurityScope<T>(_ url: URL, _ body: (String) async throws -> T) async throws -> T {
    guard url.startAccessingSecurityScopedResource() else {
        throw CrypteraError.accessDenied(url.lastPathComponent)
    }
    defer { url.stopAccessingSecurityScopedResource() }
    return try await body(url.path)
}
```

### 6.2 Selezione input

| Caso | API |
|---|---|
| File singolo | `.fileImporter(allowedContentTypes: [.item])` |
| Più file (batch) | `.fileImporter(..., allowsMultipleSelection: true)` |
| Cartella | `.fileImporter(allowedContentTypes: [.folder])` |
| Keyfile | `.fileImporter(allowedContentTypes: [.item])` |
| File `.ecf` | `.fileImporter(allowedContentTypes: [.crypteraECF])` |

**La cifratura di cartelle è possibile** — è il dubbio più comune. Un URL di
cartella ottenuto dal picker è navigabile ricorsivamente da Rust (`walkdir`)
finché lo scope è attivo. Il limite è che l'utente deve concedere esplicitamente
quella cartella: non si può scansionare il device.

### 6.3 Scrittura output

Due strategie, entrambe necessarie:

**A — Salvataggio guidato dall'utente (default).**
Cifra in `FileManager.default.temporaryDirectory`, poi presenta
`.fileExporter` o un `UIActivityViewController` per far scegliere la
destinazione. Pulire il temporaneo dopo.

**B — Scrittura in una cartella già autorizzata.**
Se l'utente ha selezionato una cartella di destinazione (con bookmark
persistente, §6.4), scrivere direttamente lì. Più fluido per l'uso ripetuto.

In entrambi i casi: **verificare la collisione di nomi prima di scrivere** e
non sovrascrivere mai silenziosamente. L'errore `OUTPUT_EXISTS` esiste già nel
set di errori del desktop, riusarlo.

### 6.4 Bookmark persistenti

Per ricordare la cartella di destinazione fra sessioni:

```swift
let data = try url.bookmarkData(
    options: .minimalBookmark,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
// salvare in UserDefaults; alla risoluzione gestire isStale
```

Applicare lo stesso meccanismo al keyfile, se l'utente ne usa uno abitualmente.
**I bookmark non sono segreti** ma rivelano percorsi: non esporli e non
sincronizzarli su iCloud.

### 6.5 Integrazione con l'app File e apertura `.ecf`

Dichiarare un **UTType esportato**:

```
Identifier:            com.cryptera.ecf
Conforms to:           public.data
Extension:             ecf
MIME:                  application/x-cryptera-ecf
Description:           Cryptera Encrypted File
```

In `Info.plist`:

- `UTExportedTypeDeclarations` — la dichiarazione sopra.
- `CFBundleDocumentTypes` — associa `com.cryptera.ecf` al ruolo `Editor`.
- `LSSupportsOpeningDocumentsInPlace` = `YES` — permette di aprire un `.ecf`
  dall'app File senza copiarlo nel container.
- `UISupportsDocumentBrowser` = `NO` (a meno che non si voglia un document
  browser come UI primaria — non è il caso qui).

Gestire l'apertura con `.onOpenURL` in `CrypteraApp`, che deve instradare alla
schermata Decrypt precompilata. Questo replica il comportamento desktop
"doppio click su `.ecf` apre il pannello Decrypt".

**Non implementare una Share Extension nella prima versione.** Aggiunge un
target, un app group e complessità di memoria (le estensioni hanno limiti di
RAM molto più stretti — Argon2 a 256 MiB in una extension viene uccisa).
Valutarla dopo, solo per la decifratura.

---

## 7. Fase 4 — Livello Swift sopra l'FFI

`CrypteraEngine` è l'unico punto di contatto con i binding generati.

```swift
actor CrypteraEngine {
    func encrypt(
        _ request: EncryptRequest,
        onProgress: @escaping @Sendable (OperationProgress) -> Void
    ) async throws -> MetaInfo
    // idem decrypt, verify
    func readMetadata(at path: String) throws -> MetaInfo
}
```

**Requisiti:**

- Le chiamate UniFFI sono **sincrone e bloccanti**. Vanno eseguite su un task
  con priorità `.userInitiated`, mai sul main actor.
- Il `ProgressListener` viene chiamato da un thread Rust. L'implementazione
  Swift deve fare hop sul main actor prima di toccare lo stato osservabile, e
  fare **throttling** (max ~10 aggiornamenti/secondo). Senza throttling, un
  file grande genera migliaia di update al secondo e la UI si blocca.
- `CancelToken` va conservato nel ViewModel per tutta la durata
  dell'operazione, e invalidato al termine.

---

## 8. Fase 5 — Interfaccia SwiftUI

### 8.1 Struttura di navigazione

`TabView` su iPhone, `NavigationSplitView` su iPad:

| Tab | Contenuto |
|---|---|
| **Encrypt** | Selezione input, opzioni, esecuzione |
| **Decrypt** | Selezione `.ecf`, password, output |
| **Verify** | Verifica integrità senza scrivere output |
| **Batch** | Decifratura multipla con password unica |
| **Settings** | Tema, lingua, audit log, about |

### 8.2 Schermata Encrypt

**Sezione input**
- Due pulsanti: *Scegli file* / *Scegli cartella*
- Card del file selezionato: nome, dimensione, icona per tipo
- Su iPad: supporto drop (`.dropDestination`)

**Sezione password**
- `SecureField` con toggle di visibilità
- **Indicatore di robustezza** — replicare la logica di `ui/modules/password.js`
- Campo di conferma con validazione immediata
- Keyfile opzionale: picker + indicatore, con spiegazione chiara che
  *perdere il keyfile equivale a perdere la password*

**Sezione opzioni** (collassabile, default chiusa)
- Compressione payload: None / Zlib / LZMA
- Compressione archivio (solo se input = cartella): None / Gzip / Bzip2 / Xz
- Profilo sicurezza: Standard / Strong / Paranoid — **con stima del tempo e
  avviso memoria** (§11.2)
- Profilo integrità: Low / Standard / High / Max — **mostrare l'overhead in %
  e la dimensione finale stimata**, altrimenti Max sorprende l'utente con un
  file 4× più grande
- Toggle: password check record, nascondi nome file, salta file speciali

**Sezione esecuzione**
- `ProgressView` determinato con stage corrente
- Pulsanti Pausa / Annulla
- Al termine: riepilogo + azione di salvataggio/condivisione

### 8.3 Decrypt / Verify / Batch

**Decrypt:** input `.ecf` → mostra metadata leggibili senza password (versione,
dimensione, k/r, flag compressione/archivio) → password → output. Se il flag
`FLAG_TAR_CONTAINER` (0x20) è presente, offrire "estrai archivio".

**Verify:** identico ma senza output. Utile e veloce da implementare: è
l'operazione ideale per il primo end-to-end funzionante.

**Batch:** lista di file con stato per-file (in attesa / in corso / ok /
errore), password unica, esecuzione sequenziale. Riferimento:
`ui/modules/batch.js`.

### 8.4 Design system

- **Non riprodurre la UI desktop.** Il desktop ha una finestra 1120×740 con
  titlebar custom e `decorations: false`. Su iOS si usano i pattern nativi:
  `NavigationStack`, `Form`, `List` con `.insetGrouped`, sheet per i picker.
- **Tema:** Dark / Light / System. Su SwiftUI si ottiene con
  `.preferredColorScheme` legato a un `@AppStorage`. I colori del desktop sono
  CSS custom properties in `ui/styles.css`: usarli come riferimento cromatico,
  ma mappandoli su un `Color` asset catalog con varianti chiaro/scuro.
- **Dynamic Type e VoiceOver** obbligatori. Un'app di sicurezza con testo non
  scalabile è un'app che la gente usa male.
- **Nessuna webview.** Se ci si ritrova a valutarne una, si è sbagliata strada.

---

## 9. Matrice di parità funzionale

| Funzionalità desktop | Stato iOS | Note |
|---|---|---|
| Cifratura file singolo | ✅ | Via document picker |
| Cifratura cartella (TAR) | ✅ | Solo cartelle autorizzate dal picker |
| AES-256-GCM | ✅ | Dal core |
| Argon2id | ✅ | Vedi §11.2 per il limite di memoria |
| Reed-Solomon FEC | ✅ | Dal core |
| Compressione zlib | ✅ | |
| Compressione LZMA2 | ⚠️ | Dipende dallo spike §4.1 |
| Archivi gz / xz | ⚠️ | Dipende dallo spike §4.1 |
| Archivi bz2 | ⚠️ | Degradabile senza perdita di compatibilità |
| Verifica integrità | ✅ | |
| Batch decrypt | ✅ | Multi-selezione picker |
| Audit log JSONL | ✅ | Nel container app, non esportabile fuori sandbox |
| Storico in memoria (100) | ✅ | |
| Tema Dark/Light/System | ✅ | Nativo |
| i18n IT / EN | ✅ | Da portare in `Localizable.strings` |
| Keyfile | ✅ | Con bookmark persistente |
| Pausa / Annulla | ✅ | Via `CancelToken` |
| Profili sicurezza/integrità | ✅ | Con cap memoria |
| Nascondi nome file | ✅ | |
| Password check record | ✅ | |
| Apertura file `.ecf` | ✅ | Via UTI + `LSSupportsOpeningDocumentsInPlace` |
| Drag & drop | ⚠️ | Solo iPadOS |
| System tray | ❌ | Non esiste su iOS |
| Updater in-app firmato | ❌ | Vietato da App Store; update via Apple |
| Scrittura output arbitraria | ❌ | Sostituito da picker/share |
| Telemetria | ❌ | **Resta assente. Non introdurla.** |

---

## 10. Codici di errore e localizzazione

### 10.1 Codici dal core

Definiti in `src/lib.rs` (righe 91-99). **Sono stabili: non rinominarli.**

| Codice | Significato |
|---|---|
| `PASSWORD_INVALID` | Password (o keyfile) errata — fallisce PWCHK o header auth |
| `HEADER_AUTH_FAILED` | Tag HMAC dell'header non valido — file manomesso |
| `HEADER_INVALID` | Header malformato o magic errato |
| `PARAMS_OUT_OF_LIMITS` | Parametri fuori dai vincoli §12 della spec formato |
| `TRUNCATED` | File incompleto |
| `CORRUPT_BEYOND_FEC` | Corruzione oltre la capacità di recupero Reed-Solomon |
| `IO_ERROR` | Errore di lettura/scrittura |
| `CANCELLED` | Annullato dall'utente |
| `UNKNOWN_ERROR` | Fallback |

### 10.2 Codici dal livello applicativo

Dal desktop, da replicare: `PASSWORD_REQUIRED`, `INPUT_REQUIRED`,
`OUTPUT_REQUIRED`, `OUTPUT_EXISTS`, `TAR_ERROR`, `EXTRACT_ERROR`.

Aggiungere per iOS: `ACCESS_DENIED` (security scope negato),
`INSUFFICIENT_STORAGE`, `DEVICE_LOCKED` (§11.3).

### 10.3 Localizzazione

`ui/modules/i18n.js` contiene ~485 righe di stringhe EN/IT già tradotte e
revisionate. **Portarle, non ritradurle.** Conviene uno script una tantum che
converta il dizionario JS in due `Localizable.strings`, mantenendo le stesse
chiavi (`nav_encrypt`, `err_password_invalid`, …) così che il confronto con il
desktop resti possibile.

**Mai mostrare all'utente il campo `message` grezzo di un errore.** È
diagnostico e può contenere percorsi. Mostrare la stringa localizzata mappata
dal `code`, esattamente come fa `ui/modules/errors.js`.

---

## 11. Vincoli iOS specifici

Questa sezione raccoglie i problemi che non esistono sul desktop e che, se non
affrontati in fase di design, si manifestano come bug intermittenti in
produzione.

### 11.1 Esecuzione in background

Cifrare un file grande richiede minuti. Se l'utente cambia app o blocca lo
schermo, iOS sospende il processo.

- `UIApplication.shared.beginBackgroundTask` concede circa **30 secondi** di
  grazia. Non basta per un file grande, ma basta per chiudere in modo pulito.
- `BGProcessingTask` non è adatto: è schedulato dal sistema a sua discrezione,
  non è un modo per continuare un'operazione avviata dall'utente.

**Approccio consigliato:** `isIdleTimerDisabled = true` durante l'operazione,
avviso esplicito all'utente di tenere l'app in primo piano, e — importante —
**checkpoint puliti**: se l'app viene sospesa, l'output parziale va cancellato,
mai lasciato sul filesystem dove potrebbe sembrare un file valido.

### 11.2 Limiti di memoria — Argon2

Il profilo `Paranoid` richiede **512 MiB** di allocazione contigua per Argon2.
Su iOS il limite jetsam per app in foreground varia col dispositivo (indicativamente
2 GB su un device da 6 GB, molto meno su hardware più vecchio). 512 MiB non è
garantito e il fallimento è una terminazione immediata del processo senza
eccezione catturabile — dal punto di vista dell'utente, l'app "sparisce".

**Da implementare:**

1. Leggere `os_proc_available_memory()` prima di avviare.
2. Se il profilo richiesto supera una soglia prudenziale (suggerito: **50%**
   del disponibile), rifiutare con un errore chiaro invece di tentare.
3. Nella UI, marcare `Paranoid` come non disponibile sui device che non lo
   reggono, spiegando il perché.
4. **Non abbassare silenziosamente i parametri.** Cambiare `argon2_mem` cambia
   la chiave derivata: un file cifrato con parametri diversi da quelli
   richiesti è un file diverso. I parametri vanno scritti nell'header e
   rispettati. Meglio un errore esplicito che un downgrade silenzioso della
   sicurezza.

**Decifratura:** i parametri arrivano dall'header, non sono negoziabili. Un
file creato su desktop con `Paranoid` potrebbe non essere decifrabile su un
iPhone vecchio. Va comunicato con un messaggio specifico, non con un
`UNKNOWN_ERROR`.

### 11.3 Data Protection

Per default iOS applica `NSFileProtectionComplete`: a device bloccato, i file
non sono leggibili. Un'operazione lunga che prosegue mentre il device si blocca
fallisce con errori di I/O apparentemente inspiegabili.

- Impostare `.completeUnlessOpen` sui file di lavoro e sui temporanei, così un
  handle già aperto resta valido dopo il blocco.
- Non abbassare a `.none`.
- L'audit log deve restare `.complete`.
- Mappare questo caso su `DEVICE_LOCKED`, con un messaggio comprensibile.

### 11.4 Spazio su disco

La cifratura di una cartella crea un TAR intermedio, poi il file cifrato: nel
caso peggiore serve **~2× la dimensione della sorgente**, più l'overhead di
parità (fino a 300% con profilo `Max`). Verificare lo spazio prima di iniziare
e mostrare la stima all'utente.

### 11.5 Termica

`rayon` su tutti i core di un iPhone porta a throttling in pochi minuti.
Limitare il pool (§5.4) e usare QoS `.userInitiated`, non `.userInteractive`.

---

## 12. Sicurezza

Il repo upstream ha un `SECURITY.md` esteso. Le garanzie del formato non
cambiano su iOS; cambia il contorno.

### 12.1 Password in memoria

Su Swift, `String` è immutabile e non azzerabile in modo affidabile: il runtime
può copiarla. La password **transita** da `SecureField` a Rust attraverso una
`String` Swift, e su quella copia non c'è garanzia di zeroizzazione.

**Da fare:**
- Minimizzare la vita della `String` Swift: leggerla, passarla, azzerare il
  binding della view.
- Nel crate FFI, spostarla subito in `Zeroizing<String>`.
- **Documentare onestamente questo limite nel `SECURITY.md` del nuovo repo.**
  Non affermare una zeroizzazione end-to-end che non esiste.

### 12.2 Nessuna persistenza di password

- Le password **non** vanno mai salvate, né in Keychain né altrove.
- Face ID / Touch ID può opzionalmente proteggere l'**accesso all'app**, non
  sostituire la password di un file. Non confondere le due cose nella UI: il
  desktop è chiaro sul fatto che senza password i dati sono irrecuperabili, e
  l'app iOS non deve suggerire il contrario.

### 12.3 Privacy dell'interfaccia

- **App switcher:** oscurare la UI in `scenePhase == .inactive` con un overlay,
  altrimenti lo snapshot di sistema può contenere nomi file e metadata.
- `SecureField` per le password (impedisce anche lo screenshot del contenuto).
- Non inserire mai percorsi o nomi file nei log di sistema (`os_log` è
  leggibile da Console.app collegando il device).

### 12.4 Rete

L'app **non deve fare alcuna richiesta di rete**. È una proprietà verificabile
e va verificata: aggiungere un test che fallisce se il binario linka simboli di
rete inattesi, e non aggiungere SDK di terze parti. Nessuna analytics, nessun
crash reporter di terze parti.

---

## 13. Testing

### 13.1 Compatibilità di formato — il test che conta

Il repo upstream ha `tests/fixtures/` con file `.ecf` di riferimento
(`v4-basic.ecf`, `v4-zlib-hidden.ecf`) e `tests/format_compat.rs`.

**Da implementare in `CrypteraTests/FormatCompatTests.swift`:**

1. **Lettura:** decifrare ogni fixture upstream e verificare il plaintext atteso.
   Copre v4 legacy e v5.
2. **Scrittura + round-trip locale:** cifrare e ridecifrare su device.
3. **Round-trip incrociato — obbligatorio in CI:** un job che cifra un file con
   il binario desktop, lo decifra con il codice iOS, e viceversa. È l'unico
   test che dimostra davvero la compatibilità; tutti gli altri possono passare
   con un formato divergente.
4. **Recupero FEC:** corrompere deliberatamente uno shard e verificare che il
   recupero funzioni; corromperne più di `r` e verificare che si ottenga
   `CORRUPT_BEYOND_FEC` e non un output silenziosamente sbagliato.
5. **Manomissione header:** modificare un byte dell'header e attendersi
   `HEADER_AUTH_FAILED`.

### 13.2 Altri test

- **Unit** sul mapping errori e sui profili (i valori di §5.2 devono essere
  verificati da un test, non solo scritti).
- **Memoria:** eseguire i tre profili di sicurezza su device reale sotto
  Instruments, non solo su simulatore — il simulatore non ha i limiti jetsam
  e nasconde esattamente il problema di §11.2.
- **UI test** sui flussi principali.
- **CI:** `cargo test` sul crate FFI, build dell'XCFramework, build dell'app,
  test unitari. Il round-trip incrociato richiede un runner macOS.

---

## 14. Distribuzione

*La scelta fra App Store pubblico e TestFlight non è ancora stata fatta.
Quanto segue copre entrambi.*

### 14.1 Comune a entrambi

- **Apple Developer Program obbligatorio, 99 $/anno.** Su iOS non esiste
  l'equivalente del "apri comunque" di Gatekeeper: senza firma non si installa
  oltre i 7 giorni di un profilo free.
- **Export compliance.** Cryptera usa AES-256 e Argon2id. In `Info.plist` va
  dichiarato `ITSAppUsesNonExemptEncryption`. L'app rientra molto
  probabilmente nell'esenzione prevista per la crittografia standard usata a
  protezione dei dati dell'utente, ma **la posizione va verificata e
  documentata prima della prima submission**, non dopo. Se applicabile
  l'esenzione, `ITSAppUsesNonExemptEncryption = false` con la motivazione
  registrata in `README.md`.
- **Deployment target consigliato: iOS 17.0.** Dà `.fileImporter` maturo,
  Observation, e `ContentUnavailableView`. Scendere a iOS 16 è possibile ma
  costa workaround.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`) obbligatorio. Per Cryptera è
  semplice: nessun dato raccolto. Dichiararlo esplicitamente è un punto di
  forza, non un adempimento.

### 14.2 App Store pubblico

- Review Apple. Le app di crittografia passano regolarmente, ma serve una
  descrizione chiara del funzionamento offline.
- Necessari screenshot, descrizione, privacy policy (anche se dice "non
  raccogliamo nulla", deve esistere ed essere raggiungibile).
- Update gestiti da Apple: **l'updater in-app del desktop non va portato**, e
  neppure un controllo versione che rimandi altrove.

### 14.3 TestFlight / uso personale

- Nessuna review pubblica per i tester interni (fino a 100).
- I build TestFlight scadono dopo 90 giorni.
- Iterazione molto più rapida: consigliato per tutta la fase di sviluppo,
  indipendentemente dalla decisione finale.

---

## 15. Milestone

Ordinate per rischio decrescente. **Non invertirle:** M1 può invalidare tutto
il resto, e va risolta prima di investire in UI.

| # | Obiettivo | Criterio di completamento |
|---|---|---|
| **M1** | Spike cross-compilazione | `crypto_core_rs` compila per `aarch64-apple-ios`. Esito di `xz2`/`bzip2` documentato. |
| **M2** | XCFramework | `build-xcframework.sh` produce un framework linkabile; un'app vuota chiama `core_version()` e stampa la versione. |
| **M3** | Primo end-to-end | `verify` funzionante su una fixture upstream, da UI minimale. Nessun design. |
| **M4** | Decrypt | File picker + password + output + share sheet. `.onOpenURL` per i `.ecf`. |
| **M5** | Encrypt file | Con opzioni, progress, cancel. |
| **M6** | Encrypt cartella | TAR + compressione archivio. |
| **M7** | Compatibilità | Round-trip incrociato desktop↔iOS verde in CI. **Gate: nessun rilascio prima di questo.** |
| **M8** | Batch + Audit | |
| **M9** | Design system | Tema, i18n, Dynamic Type, VoiceOver. |
| **M10** | Hardening | §11 e §12 completi, test su device reale. |
| **M11** | Distribuzione | TestFlight. |

---

## 16. Appendice — riferimento formato ECF1

La specifica normativa completa è in **`FORMAT_SPEC.md`** del repo upstream.
**Copiarla nel nuovo repo e tenerla allineata al tag di `crypto_core_rs`.**
Quanto segue è il riassunto operativo.

### 16.1 Layout

```
START HEADER    magic "ECF1" · hdr_len(u16) · Header Body · hdr_crc(u32)
                · header auth tag (16 B, v4+)
PWCHK RECORD    60 B — solo se FLAG_PWCHK
BLOCKS          num_blocks × (k + r) shard
                shard: crc32×2 (8 B) · ciphertext (shard_size) · gcm_tag (16 B)
                dentro ogni blocco: k data shard, poi r parity shard
END TRAILER     Header Body · hdr_crc · auth tag · hdr_len · magic "ECCT"
```

Tutti gli interi multi-byte sono **big-endian**.

### 16.2 Header Body (v5)

| Off | Size | Campo |
|---|---|---|
| 0 | 1 | `version` = 5 |
| 1 | 1 | `alg` = 1 (AES-256-GCM) |
| 2 | 1 | `kdf` = 1 (Argon2id) |
| 3 | 1 | `crc_type` = 1 (CRC32) |
| 4 | 1 | `salt_len` = 16 |
| 5 | 16 | `salt` |
| 21 | 4 | `nonce_base` (u32) |
| 25 | 8 | `plain_size` (u64) |
| 33 | 8 | `stored_size` (u64) |
| 41 | 4 | `shard_size` (u32) |
| 45 | 2 | `k` (u16) |
| 47 | 2 | `r` (u16) |
| 49 | 4 | `argon2_time` (u32) |
| 53 | 4 | `argon2_mem` KiB (u32) |
| 57 | 2 | `argon2_par` (u16) |
| 59 | 1 | `tag_len` = 16 |
| 60 | 1 | `flags` |
| 61 | 2+ | record nome file cifrato, se `FLAG_ENC_FILENAME` |

Minimo 61 byte, massimo 8192.

### 16.3 Flag

| Bit | Mask | Nome |
|---|---|---|
| 0 | 0x01 | `FLAG_PWCHK` |
| 1 | 0x02 | `FLAG_COMPRESS_ZLIB` |
| 3 | 0x08 | `FLAG_COMPRESS_LZMA` |
| 4 | 0x10 | `FLAG_HAS_FILENAME` (legacy v2-v4, plaintext) |
| 5 | 0x20 | `FLAG_TAR_CONTAINER` |
| 6 | 0x40 | `FLAG_ENC_FILENAME` (v5) |

ZLIB e LZMA sono mutuamente esclusivi. Il writer v5 non imposta mai
`FLAG_HAS_FILENAME`.

### 16.4 Nonce

```
nonce[0..4]  = nonce_base   (u32 BE)
nonce[4..8]  = block_index  (u32 BE)
nonce[8..12] = shard_index  (u32 BE)
```

Coordinate riservate: PWCHK `0xFFFFFFFF/0xFFFFFFFF`, filename
`0xFFFFFFFE/0xFFFFFFFE`.

### 16.5 Derivazione chiave

```
se keyfile:  secret = HMAC-SHA256(key = SHA-256(keyfile), msg = password)
altrimenti:  secret = password

master_key = Argon2id(secret, salt, t, m, p, len = 32)
auth_key   = HMAC-SHA256(master_key, "ECF1-HEADER-AUTH-V1")[..32]
auth_tag   = HMAC-SHA256(auth_key, header_prefix || hdr_crc_be)[..16]
```

I parametri dell'header vanno **validati prima** di eseguire Argon2, così un
header malevolo non può richiedere un costo KDF illimitato.

### 16.6 Vincoli

| Parametro | Min | Max | Default |
|---|---|---|---|
| `k` | 1 | 64 | 24 |
| `r` | 1 | 64 | 8 |
| `k + r` | — | 255 | 32 |
| `shard_size` | 1 024 | 1 048 576 | 16 384 |
| `argon2_time` | 1 | 10 | 3 |
| `argon2_mem` (KiB) | 8 192 | 524 288 | 65 536 |
| `argon2_par` | 1 | 8 | 2 |

Valori fuori range → `PARAMS_OUT_OF_LIMITS`, senza tentare la decifratura.

### 16.7 AAD degli shard

```
aad = header_prefix || block_index_be(u32) || shard_index_be(u32)
```

dove `header_prefix` = byte `[0 .. 6+hdr_len)` (magic + hdr_len + Header Body,
**senza** `hdr_crc`). Questo lega ogni shard al suo file e alla sua posizione.

---

## Riferimenti

| Risorsa | Percorso |
|---|---|
| Repo upstream | `https://github.com/gh0st032395/Cryptera` |
| Spec formato | `FORMAT_SPEC.md` |
| Modello di sicurezza | `SECURITY.md` |
| Core crittografico | `src/lib.rs` |
| Orchestrazione da portare | `src-tauri/src/main.rs` |
| Audit log | `src-tauri/src/audit.rs` |
| Stringhe i18n | `ui/modules/i18n.js` |
| Mapping errori | `ui/modules/errors.js` |
| Logica batch | `ui/modules/batch.js` |
| Robustezza password | `ui/modules/password.js` |
| Fixture di test | `tests/fixtures/` |
| Test compatibilità | `tests/format_compat.rs` |

---

## Nota finale per chi implementa

Se durante il lavoro emerge la tentazione di **reimplementare una primitiva
crittografica in Swift** per aggirare un problema di build — fermarsi e
risolvere il problema di build. La compatibilità di formato è il requisito
centrale del progetto: un'app iOS che produce file che il desktop non sa
aprire non è una versione di Cryptera, è un'app diversa con lo stesso nome.

Analogamente, se la milestone **M7** (round-trip incrociato) non è verde, il
progetto non è pronto per essere distribuito a nessuno, nemmeno a se stessi:
i file cifrati con una build non verificata potrebbero diventare illeggibili.
