# Cryptera iOS — Piano di implementazione

> Piano operativo derivato da [`SPEC.md`](SPEC.md), verificato contro il codice
> reale dell'upstream. Ordinato per **rischio decrescente**: M1 può invalidare
> tutto il resto.

---

## 0. Verifica preliminare della spec

Prima di pianificare ho controllato le assunzioni di `SPEC.md` contro il
repository upstream. **Tutte confermate**, con una correzione utile.

| Assunzione della spec | Esito |
|---|---|
| `crypto_core_rs` è il crate alla root (§4.2) | ✅ confermato — `Cargo.toml` root, `name = "crypto_core_rs"`, `version = "2.0.3"` |
| Profili sicurezza `(time, mem, par)` (§5.2) | ✅ esatti — `Strong (6, 256·1024, 4)`, `Paranoid (10, 512·1024, 8)`, default `(3, 64·1024, 2)` |
| Profili integrità `(k, r)` (§5.2) | ✅ esatti — `Low (28,4)`, `High (12,12)`, `Max (8,24)`, default `(24,8)` |
| Codici di errore del core (§10.1) | ✅ tutti e 9 presenti in `src/lib.rs` |
| Fixture `v4-basic.ecf`, `v4-zlib-hidden.ecf` (§13.1) | ✅ presenti, già copiate in `CrypteraTests/Fixtures/` |
| `ui/modules/i18n.js` ~485 righe (§10.3) | ✅ 485 righe esatte |
| `xz2` è dipendenza del core (§4.1) | ✅ confermato — **il rischio LZMA è reale** |
| `bzip2` è dipendenza dell'orchestrazione | ✅ ma **solo in `src-tauri`**, non nel core |

**Correzione: pinnare `v2.0.4`, non `v2.0.3`.**
`src/lib.rs` è **identico byte-per-byte** fra i due tag (SHA-256
`ed4bcbc6…f6cd93d3`). Le release 2.0.1→2.0.4 correggono esclusivamente frontend
e livello Tauri (CSP, modali, tray, i18n). Pinnare `v2.0.4` comporta quindi
**zero rischio di divergenza di formato** e in più l'orchestrazione da portare
include il pre-conteggio delle entry (`walkdir … .count()`) che rende reale il
progress di archiviazione — in 2.0.3 il `total` era emesso come `0`.

**Conseguenza operativa:** portare l'orchestrazione dalla `src-tauri/src/main.rs`
di **v2.0.4**, ignorando tutto il codice tray/updater/window (non esiste su iOS).

---

## 1. Stato dell'ambiente

| Componente | Stato |
|---|---|
| Xcode | ✅ 26.6 (build 17F113), licenza accettata |
| SDK iOS / Simulatore | ✅ iOS 26.5 + `iphonesimulator26.5` |
| Swift | ✅ 6.3.3 |
| Rust / Cargo | ✅ cargo 1.96.0, rustup 1.29.0 |
| Target iOS Rust | ✅ `aarch64-apple-ios`, `-sim`, `x86_64-apple-ios` |
| Homebrew | ✅ `/opt/homebrew/bin/brew` |
| `uniffi-bindgen` | ❌ da installare (M2) |
| XcodeGen / Tuist | ❌ da scegliere e installare (M2, decisione D2) |
| `gh` CLI | ❌ assente (git funziona, credenziali nel keychain) |
| Apple Developer Program | ❓ **da confermare** — blocca M10/M11 |

**Pronto per M2.** Tutto ciò che serviva a M1 è a posto e lo spike è verde.

---

## 2. Decisioni bloccanti

Da prendere prima o durante M1-M2; ognuna cambia il lavoro a valle.

| # | Decisione | Opzioni | Raccomandazione |
|---|---|---|---|
| D1 | Tag del core | `v2.0.3` (da spec) / `v2.0.4` | **`v2.0.4`** — core identico, orchestrazione migliore |
| D2 | Generazione progetto Xcode | XcodeGen / Tuist / `.xcodeproj` a mano | ✅ **XcodeGen 2.46** adottato in M2 |
| D3 | Deployment target | iOS 17 / iOS 16 | ✅ **iOS 17** adottato in M2 (`minos 17.0` verificato) |
| D4 | Apple Developer Program | sì / no | Necessario per test su device reale (§13.2 memoria) e M11 |
| D5 | Distribuzione | TestFlight / App Store | **TestFlight** per tutto lo sviluppo, indipendentemente dalla scelta finale |

---

## 3. Milestone

### M1 — Spike cross-compilazione ✅ COMPLETATA (2026-07-22)

**Esito: completamente positivo, nessuna limitazione funzionale.**

Verificato con Xcode 26.6 (SDK iOS 26.5) e cargo 1.96.0, core a `v2.0.4`:

| Componente | Device | Simulatore | Evidenza |
|---|---|---|---|
| `crypto_core_rs` | ✅ | ✅ arm64 + x86_64 | `otool`: `platform 2` (iOS), arm64 |
| `xz2` / `liblzma` | ✅ | ✅ | 73 oggetti liblzma, 719 simboli `lzma_*` |
| `bzip2` / `bzip2-sys` | ✅ | ✅ | 35 simboli `BZ2_*` |
| `tar`, `flate2`, `walkdir`, `tempfile` | ✅ | ✅ | |

Non è servito alcun intervento: né `CC`/`AR` espliciti né il fallback `lzma-rs`.
Il crate `cc` risolve i target iOS autonomamente.

**Conseguenze sul piano:**

1. **La matrice di parità §9 migliora** — LZMA2, archivi gz/xz e archivi bz2
   passano da ⚠️ a ✅. L'app iOS legge e scrive ogni variante di compressione
   del formato. Nessuna degradazione da progettare, nessun percorso di sola
   lettura da isolare.
2. **Il rischio più alto del progetto è rientrato**, e con esso la ramificazione
   che avrebbe complicato M5/M6.
3. ⚠️ **Deployment target** — senza variabile d'ambiente il `minos` eredita la
   versione dell'SDK (**26.5**), che escluderebbe di fatto quasi tutti i device.
   `IPHONEOS_DEPLOYMENT_TARGET=17.0` dà correttamente `minos 17.0`: va impostato
   in `scripts/build-xcframework.sh` per **tutti** i target, non solo il device.
   È un errore silenzioso — il build riesce comunque — quindi va verificato con
   `otool -l | grep minos` nello script stesso.

**Scoperta utile per M3** — l'API reale del core: le funzioni hanno suffisso
`_rs` (`read_metadata_rs`, `encrypt_file_rs`, `decrypt_file_ex_rs`,
`verify_file_integrity_rs`, `get_keyfile_hash_rs`) e ognuna ha una variante
`_controlled` che accetta `ControlFlags`. Sono queste le varianti da usare
nell'FFI. `ControlFlags` espone `cancel: Arc<AtomicBool>`, `pause`,
`request_cancel()` e `set_pause(bool)` → il `CancelToken` UniFFI mappa
`cancel()` → `request_cancel()`, `set_paused()` → `set_pause()`,
`is_cancelled()` → `cancel.load(SeqCst)`.

---

### M2 — XCFramework ✅ COMPLETATA (2026-07-22)

Realizzato: workspace Rust, crate `cryptera-ffi` (UniFFI **0.32**, non 0.28 —
la spec dice "0.28+" e conviene la corrente per il supporto Swift 6),
`bootstrap.sh`, `build-xcframework.sh`, `project.yml` XcodeGen, app minimale.

**Exit raggiunto:** l'app stampa `cryptera-ffi 0.1.0 (core v2.0.4)` sul
simulatore; 4 test XCTest verdi, di cui due leggono le fixture reali
dell'upstream attraverso l'intera catena Swift → UniFFI → Rust → core.

> Il criterio della spec dice "su device reale". Verificato su simulatore:
> il device fisico richiede la decisione **D4**. Non è un rischio per M2 —
> l'XCFramework contiene la slice `ios-arm64` con `minos 17.0` verificata —
> ma va riconfermato appena il device è disponibile.

**Superficie esposta finora** (deliberatamente minima): `core_version()`,
`read_metadata()`, `MetaInfo`, `CrypteraError`. Il resto è M3.

#### Deviazione dalla spec: `panic = "abort"` rimosso

SPEC §4.3 indica `panic = "abort"` nel profilo release, e SPEC §5.4 richiede
una panic barrier con `catch_unwind` su ogni entry point FFI. **Le due cose
sono incompatibili:** con `abort` il processo termina subito e `catch_unwind`
non cattura nulla, quindi la barriera sarebbe codice morto proprio nella build
release — l'unica che viene spedita.

Si è mantenuto l'unwind (default) e la barriera è effettiva: un panic su un
file malformato diventa un `CrypteraError::Internal` presentabile, invece di
far sparire l'app senza spiegazione. Il costo è un binario marginalmente più
grande. Motivazione registrata in `rust/Cargo.toml`.

#### Altre scelte fissate qui

- **`ENGINE`/`ControlFlags`** — confermata la mappatura per il `CancelToken` di M3
- **Fixture nel bundle di test** — entrano come folder reference, quindi la
  lookup richiede `subdirectory: "Fixtures"`. Una fixture mancante **fa fallire**
  il test, non lo skippa: uno skip trasformerebbe i test di compatibilità (M7)
  in un verde che non dimostra nulla
- **`.xcodeproj` non committato** — la fonte di verità è `project.yml`

> ⚠️ **Nota Swift 6.3 per M3.** La strict concurrency è attiva. Il
> `ProgressListener` UniFFI viene invocato da un thread Rust: il tipo generato
> va reso esplicitamente `Sendable` e la callback deve fare hop sul main actor.

---

### M3 — Superficie FFI + primo end-to-end

**Crate `cryptera-ffi`** (§5.1-5.4), portando l'orchestrazione da `main.rs` v2.0.4:

| File | Contenuto |
|---|---|
| `lib.rs` | Tipi UniFFI, `encrypt` / `decrypt` / `verify` / `read_metadata` / `core_version` |
| `orchestration.rs` | TAR, compressione, profili, pre-conteggio entry per il progress |
| `errors.rs` | `CoreError` → `CrypteraError`, codici §10.1 + §10.2 |
| `control.rs` | `CancelToken` su `Arc`, wrappa `ControlFlags` |

**Regole non negoziabili:**
- **Panic barrier** — ogni `#[uniffi::export]` avvolge il corpo in `catch_unwind` → `CrypteraError::Internal`. Un panic attraverso il confine FFI è UB
- **Password** → subito in `Zeroizing<String>` / `secrecy::Secret`. Mai loggata, nemmeno in debug
- **Thread pool** — `num_threads = min(activeProcessorCount, 4)`, passato da Swift. Saturare i core scalda il device e causa throttling
- I valori dei profili §5.2 vanno **verificati da un test**, non solo scritti

Poi `verify` da UI minimale (nessun design) su una fixture upstream — è
l'operazione ideale per il primo end-to-end perché non scrive output.

**Exit:** `verify` verde su `v4-basic.ecf` da device.

---

### M4 — Decrypt

- `FileAccess.swift`: helper `withSecurityScope` **unico e non duplicato** (§6.1). Lo scope va tenuto aperto per **tutta** la durata dell'operazione: chiuderlo prima produce `IO_ERROR` intermittenti su file grandi — è l'errore classico
- `CrypteraEngine` actor: chiamate UniFFI su task `.userInitiated`, **mai sul main actor** (sono sincrone e bloccanti)
- Progress con **throttling ~10 update/s** — senza, un file grande blocca la UI
- `DocumentTypes.swift` + `Info.plist`: UTType esportato `com.cryptera.ecf`, `CFBundleDocumentTypes` ruolo Editor, `LSSupportsOpeningDocumentsInPlace = YES`, `UISupportsDocumentBrowser = NO`
- `.onOpenURL` → instrada alla schermata Decrypt precompilata
- Output: cifratura in `temporaryDirectory` → `.fileExporter` / share sheet, con pulizia del temporaneo
- **Mai sovrascrivere silenziosamente**: collisione nomi → `OUTPUT_EXISTS`

**Exit:** `.ecf` aperto da app File, decifrato, salvato via share sheet.

---

### M5 — Encrypt file

Opzioni, progress, pausa/annulla. Punti che la UI deve rendere espliciti:

- **Profilo integrità**: mostrare overhead in % e **dimensione finale stimata**, altrimenti `Max` sorprende l'utente con un file 4× più grande
- **Profilo sicurezza**: stima tempo + avviso memoria (§11.2)
- Indicatore robustezza password — portare la logica di `ui/modules/password.js`
- Keyfile: spiegare chiaramente che **perderlo equivale a perdere la password**

---

### M6 — Encrypt cartella

TAR + compressione archivio. La cifratura di cartelle **è possibile**: un URL di
cartella dal picker è navigabile ricorsivamente con `walkdir` finché lo scope è
attivo.

**Verificare lo spazio prima di iniziare** (`volumeAvailableCapacityForImportantUsageKey`):
nel caso peggiore serve ~2× la sorgente (TAR intermedio + output) più
l'overhead di parità, fino al 300% con profilo `Max`. Fallire subito con
`INSUFFICIENT_STORAGE`, non a metà operazione.

---

### M7 — Compatibilità 🚦 gate di rilascio

**Nessun rilascio, nemmeno a se stessi, prima che questa milestone sia verde.**

1. **Lettura** — decifrare ogni fixture upstream, verificare il plaintext atteso (copre v4 legacy e v5)
2. **Round-trip locale** — cifra e ridecifra su device
3. **Round-trip incrociato in CI** ⭐ — cifra col binario desktop → decifra con codice iOS, e viceversa. **È l'unico test che dimostra davvero la compatibilità**: tutti gli altri possono passare con un formato divergente. Richiede un runner macOS
4. **Recupero FEC** — corrompere uno shard → recupero ok; corromperne più di `r` → `CORRUPT_BEYOND_FEC`, mai un output silenziosamente sbagliato
5. **Manomissione header** — un byte modificato → `HEADER_AUTH_FAILED`

---

### M8 — Batch + Audit

- Batch: lista con stato per-file, password unica, esecuzione sequenziale (rif. `ui/modules/batch.js`). **Portare la logica di v2.0.4**, che ispeziona l'header di ogni file e distingue `.ecf` singolo da archivio TAR — la 2.0.3 assumeva un container e falliva con `EXTRACT_ERROR`/`OUTPUT_EXISTS` sui file singoli
- Audit log JSONL nel container app (rif. `src-tauri/src/audit.rs`), protezione file `.complete`
- Storico in memoria (100 voci)

---

### M9 — Design system

- **Non riprodurre la UI desktop.** Pattern nativi: `NavigationStack`, `Form`, `List` `.insetGrouped`, sheet per i picker. `TabView` su iPhone, `NavigationSplitView` su iPad
- Tema Dark/Light/System via `.preferredColorScheme` + `@AppStorage`; colori desktop da `ui/styles.css` come riferimento cromatico, mappati su asset catalog con varianti
- **i18n**: script una tantum che converte `ui/modules/i18n.js` (485 righe già tradotte e revisionate) in due `Localizable.strings` **mantenendo le stesse chiavi** — così il confronto col desktop resta possibile. Portarle, non ritradurle
- **Mai mostrare il campo `message` grezzo di un errore**: è diagnostico e può contenere percorsi. Mostrare la stringa localizzata mappata dal `code`
- Dynamic Type e VoiceOver obbligatori
- **Nessuna webview.** Se ci si ritrova a valutarne una, si è sbagliata strada

---

### M10 — Hardening

| Area | Intervento |
|---|---|
| Memoria (§11.2) | `os_proc_available_memory()` prima di avviare; rifiutare se il profilo supera il **50%** del disponibile. **Mai abbassare silenziosamente i parametri**: cambiare `argon2_mem` cambia la chiave derivata. Meglio un errore esplicito di un downgrade silenzioso. In decifratura i parametri vengono dall'header e non sono negoziabili → messaggio specifico, non `UNKNOWN_ERROR` |
| Background (§11.1) | `isIdleTimerDisabled` durante l'operazione; `beginBackgroundTask` (~30 s) solo per chiudere pulito. **Checkpoint puliti**: se l'app è sospesa, l'output parziale va cancellato, mai lasciato dove sembri un file valido |
| Data Protection (§11.3) | `.completeUnlessOpen` su file di lavoro e temporanei; audit log resta `.complete`; mai `.none`. Mappare su `DEVICE_LOCKED` |
| Privacy UI (§12.3) | Overlay su `scenePhase == .inactive` (lo snapshot di sistema può contenere nomi file); `SecureField`; mai percorsi in `os_log` |
| Rete (§12.4) | Test che fallisce se il binario linka simboli di rete inattesi |
| Password (§12.1) | **Documentare onestamente in `SECURITY.md`** che la `String` Swift non è azzerabile in modo affidabile. Non affermare una zeroizzazione end-to-end che non esiste |
| Test memoria | I tre profili su **device reale** sotto Instruments — il simulatore non ha i limiti jetsam e nasconde esattamente il problema |

---

### M11 — Distribuzione

- `PrivacyInfo.xcprivacy`: nessun dato raccolto
- `ITSAppUsesNonExemptEncryption` — posizione verificata e **documentata in `README.md` prima** della prima submission, non dopo
- **Non portare l'updater in-app**, né alcun controllo versione che rimandi altrove: vietato da App Store
- TestFlight (build scadono a 90 giorni)

---

## 4. Registro dei rischi

| Rischio | Impatto | Mitigazione |
|---|---|---|
| ~~`xz2`/`liblzma` non cross-compila~~ | ~~Alto~~ | ✅ **rientrato in M1** — compila senza interventi |
| Deployment target ereditato dall'SDK (26.5) | Medio — escluderebbe quasi tutti i device, e il build **riesce comunque** | `IPHONEOS_DEPLOYMENT_TARGET=17.0` su tutti i target + verifica `otool -l \| grep minos` nello script |
| Jetsam su profilo `Paranoid` (512 MiB) | **Alto** — l'app "sparisce" senza eccezione catturabile | Check memoria preventivo, profilo disabilitato sui device che non lo reggono |
| Security scope chiuso troppo presto | Medio — `IO_ERROR` intermittenti, difficili da diagnosticare | Helper unico `withSecurityScope`, mai duplicato |
| Divergenza silenziosa di formato | **Critico** — file illeggibili dal desktop | M7 come gate; nessuna primitiva reimplementata in Swift |
| Progress senza throttling | Medio — UI bloccata su file grandi | Cap ~10 update/s |
| Assenza Apple Developer Program | Medio — blocca test su device e M11 | Decisione D4 in anticipo |

---

## 5. Prossimo passo

**Eseguire M1.** Concretamente:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

poi un crate minimo che dipende da `crypto_core_rs` a `v2.0.4` e
`cargo build --release --target aarch64-apple-ios`, isolando l'esito di `xz2`.

L'esito determina la matrice di parità funzionale (§9) e va scritto in
`README.md` **prima** di procedere a M2.

---

## Nota finale

Se emerge la tentazione di reimplementare una primitiva crittografica in Swift
per aggirare un problema di build — fermarsi e risolvere il problema di build.
Un'app iOS che produce file che il desktop non sa aprire non è una versione di
Cryptera, è un'app diversa con lo stesso nome.
