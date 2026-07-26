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

### M3 — Superficie FFI + primo end-to-end ✅ COMPLETATA (2026-07-22)

**Exit raggiunto:** `verify` funzionante dalla schermata minimale, con progress
e cancellazione. **40 test verdi** — 27 Rust nel crate FFI, 11 XCTest, 2 UI test
che guidano davvero la schermata.

Realizzato: superficie UniFFI completa (`encrypt` / `decrypt` / `verify` /
`read_metadata`, `ProgressListener`, `CancelToken`), orchestrazione portata da
`main.rs` v2.0.4 (TAR con protezione Zip Slip, profili, pre-conteggio entry),
`CrypteraEngine`, `ErrorPresenter`, `VerifyView`, e `FormatCompatTests` — che
copre già i punti 1 e 2 di SPEC §13.1.

#### Tre scoperte con conseguenze

**1. Su header v5 una password errata dà `HEADER_AUTH_FAILED`, non
`PASSWORD_INVALID`.** Il tag di autenticazione dell'header deriva dalla master
key, quindi una password sbagliata lo invalida, e quel controllo precede il
record PWCHK. Su v4 (fixture upstream) si ottiene invece `PASSWORD_INVALID`,
perché il PWCHK risponde prima.

Il desktop mappa `HEADER_AUTH_FAILED` su *"Il file potrebbe essere stato
manomesso"* — un messaggio allarmante e quasi sempre falso, dato che la causa
normale è un refuso. **È un bug di UX ereditabile:** portare le stringhe
dell'upstream senza pensarci lo replicherebbe. `ErrorPresenter` usa un messaggio
che copre onestamente entrambe le cause. Il codice **non** va rimappato su
`PasswordInvalid`: nasconderebbe le manomissioni vere.

**2. L'header è ridondante: corromperne una copia non è un errore.** Il formato
scrive una seconda copia dell'Header Body nel trailer `ECCT` (§16.1) e il core
la usa quando la prima non passa il CRC. Quindi SPEC §13.1 punto 5 — *"modificare
un byte dell'header e attendersi HEADER_AUTH_FAILED"* — preso alla lettera è
impreciso: con una sola copia corrotta il risultato **corretto** è il recupero.
Per far fallire davvero l'autenticazione va manomesso il tag in entrambe le
copie (il tag non è coperto dal CRC). Entrambi i comportamenti sono ora testati.

**3. UniFFI non esporta i metodi degli enum.** `memory_bytes()` e
`parity_overhead_percent()` erano invisibili a Swift; riscriverli in Swift
avrebbe fatto divergere i valori di §5.2 da quelli scritti nell'header. Sono
esposti come funzioni libere, così Rust resta l'unica fonte.

#### Scelte di implementazione

- **Throttling del progress in Rust, non in Swift.** SPEC §7 lo colloca in
  Swift; farlo nel crate FFI è strettamente migliore perché ogni notifica è un
  attraversamento del confine. La notifica finale (`done == total`) e i cambi
  di stage passano sempre, altrimenti la barra resta ferma sotto il 100%
- **Coda dedicata, non il pool cooperativo.** Le chiamate UniFFI sono bloccanti:
  girano su una `DispatchQueue` con QoS `.userInitiated`. Bloccare il pool di
  Swift Concurrency rischierebbe di affamarlo
- **I binding sono nel modulo dell'app**, quindi i metodi dell'engine ne
  oscurano i nomi: le chiamate vanno qualificate `Cryptera.verify(...)`
- **Aggiunto un target UI test.** Gli XCTest esercitano il motore, non la
  schermata: un errore di cablaggio fra vista e motore sarebbe passato
  inosservato. Un test verifica anche che nessun codice grezzo o percorso
  raggiunga la UI (§10.3)

#### Revisione post-M3 (2026-07-22)

Passaggio di ricontrollo su tutto il codice. **Tre difetti trovati e corretti**,
tutti nel percorso di estrazione, tutti della stessa classe: dati provenienti da
*dentro* il file cifrato usati come percorso.

**1. Path traversal tramite il nome nell'header (grave).** `meta.filename` è
scelto da chi crea l'archivio e il core **non lo sanifica** (valida solo UTF-8 e
lunghezza). Veniva passato a `Path::join` per costruire il file di staging e,
con `keep_archive`, il percorso di destinazione. In Rust `join` con un percorso
**assoluto scarta la base**: un `.ecf` con `filename = "/percorso/scelto"`
faceva scrivere il payload decifrato esattamente lì.

Corretto: il nome non diventa mai un percorso. La compressione si deduce dal
suffisso con sola ispezione di stringa e viaggia come parametro esplicito; per
`keep_archive` il nome passa da `safe_archive_basename`, che tiene solo il
componente finale. Il desktop non ha questo difetto: usa un `NamedTempFile` e
il letterale `"decrypted.tar"`, mai `meta.filename`.

Il test di regressione costruisce un `.ecf` realmente ostile chiamando il core
con un `original_filename` assoluto, ed è stato **verificato fallire** sul
codice vulnerabile — una prima versione del test usava una risalita relativa e
sarebbe passata comunque, perché la scrittura sarebbe finita in una cartella di
sistema anziché nel percorso asserito.

**2. Symlink con target esterno (medio).** Il controllo sui `..` guardava il
*nome* dell'entry, non il target di un link. Un archivio con un symlink verso
l'esterno, seguito da un file "dentro" quel link, aggirava il controllo: il nome
resta pulito e la scrittura segue il link. Ora i link con target assoluto o con
risalite sono rifiutati; quelli relativi interni restano ammessi. **Presente
anche nell'upstream.**

**3. Cifratura silenziosa di una cartella inesistente (medio).** Con
`skip_special_files` attivo, `walkdir` su un percorso inesistente produce una
sola entry di errore che veniva scartata: il risultato era un archivio **vuoto**
cifrato con successo — una perdita di dati silenziosa. Su iOS è uno scenario
concreto, perché un bookmark scaduto restituisce un percorso non più valido.
Ora input file e cartella sono validati prima di iniziare.

#### Altro emerso dalla revisione

- **Il desktop non riesce a estrarre archivi compressi.** Decifra in un
  `NamedTempFile` (senza estensione) e passa quel percorso a `safe_extract_tar`,
  che deduce la compressione dal suffisso: un `.tar.gz` finisce nel decoder "tar
  semplice" e l'estrazione fallisce. Da noi non accade perché la compressione è
  esplicita; un test blocca il comportamento. **Da segnalare upstream.**
- **Copertura degli stage estesa** a `decrypt` e `verify`: prima solo `encrypt`
  era coperto, e un mismatch sulle altre due sarebbe passato inosservato
- **Cancellazione durante l'operazione** ora testata (prima solo prima
  dell'avvio), insieme all'assenza di output parziale richiesta da §11.1. Il
  test verifica anche che il token condiviso con Swift agisca davvero
  sull'operazione in corso
- **Clippy pulito**, nessun warning

#### Comportamento noto, non modificato

L'estrazione **sovrascrive** i file già presenti nella destinazione, mentre
§6.3 vieta di sovrascrivere in silenzio. La regola è pensata per l'output a file
singolo, dove infatti si torna `OutputExists`. Per una cartella servirebbe
scegliere fra rifiutare, rinominare o chiedere conferma: è una decisione di
prodotto e va presa nella UI di M4/M8, non cambiata di nascosto divergendo dal
desktop.

#### Fixture nel bundle dell'app — risolto (2026-07-22)

Era annotato come debito da saldare in M4. Ispezionando una build **Release** si
è confermato che le fixture ci finivano davvero, non solo in Debug.

Sono state **mantenute in Debug ed escluse da Release**
(`EXCLUDED_SOURCE_FILE_NAMES` in `project.yml`), perché restano genuinamente
utili: da M4 l'input arriva da `.fileImporter`, che è UI di sistema e fuori
processo, quindi avere file di prova dentro l'app è il modo più pratico per
pilotare un UI test. In Release non servono a nulla e non devono esserci.

La verifica non è esprimibile come XCTest — la suite non compila in Release
perché `@testable import` richiede `ENABLE_TESTABILITY`, che in una build
distribuibile va lasciata spenta. Vive quindi in
`scripts/check-release-bundle.sh`, che ispeziona il `.app` prodotto e controlla
assenza di dati di test, bundle di test e framework di rete (§12.4). Lo script è
stato verificato in entrambe le direzioni: esce 1 rimuovendo l'esclusione, 0 con
essa attiva.

**Resta da rimuovere in M4:** `VerifyView` e il suo scaffolding, sostituiti dal
document picker.

---

### M3 — dettaglio originale del piano

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

### M4 — Decrypt ✅ COMPLETATA (2026-07-24)

**Exit raggiunto:** un `.ecf` aperto dall'esterno arriva nella schermata Decrypt
già compilata, viene decifrato e salvato in File. Verificato sul simulatore: il
file consegnato a *On My iPhone* è di 3000 byte, esattamente il `plain_size`
dichiarato nell'header. **79 test verdi** — 38 Rust, 37 XCTest, 4 UI test.

Realizzato: `FileAccess` (helper unico per lo scope), `TemporaryWorkspace`,
UTType esportato `com.cryptera.ecf` con apertura in place, `.onOpenURL` →
Decrypt, `DecryptView`/`DecryptModel`, `VerifyView` riscritta sul document
picker, e la rimozione dello scaffolding a fixture di M3.

#### Quattro scoperte con conseguenze

**1. Il picker di sistema non si presenta dentro uno `.sheet` (grave, e muto).**
`UIDocumentPickerViewController` è un servizio **fuori processo**: annidato in
uno `.sheet` SwiftUI non compare affatto. Il pulsante "Salva in File"
sembrava a posto e non faceva nulla — un difetto che **nessun test fermo
all'esistenza del pulsante avrebbe visto**, ed è stato trovato solo ispezionando
la schermata sul simulatore.

Si usa `.fileMover`, che è il wrapper nativo dello stesso picker. **Non**
`.fileExporter`: quello vuole un `FileDocument` o un `Transferable`, cioè il
contenuto **in memoria** — un file decifrato di qualche gigabyte farebbe
terminare il processo prima di riuscire a esportarlo. `.fileMover` lavora su URL
e non legge nulla; in più **sposta**, quindi dell'output in chiaro resta un solo
esemplare. Un UI test blocca ora la regressione.

**2. Lo snippet di SPEC §6.1 rifiuta i percorsi interni all'app.**
`startAccessingSecurityScopedResource()` torna `false` in due casi **opposti**:
permesso negato, e URL che non ha bisogno di alcun permesso (container, bundle,
cartella temporanea). Lo snippet della spec solleva `accessDenied` in entrambi —
il che farebbe fallire proprio l'output di M4, che vive nella cartella di lavoro
dell'app. Il discriminante è duplice: posizione dentro il container (copre i
percorsi non ancora esistenti) o leggibilità effettiva (copre le cartelle
concesse che stanno fuori).

Il ramo di rifiuto **non è verificabile end-to-end sul simulatore**, dove
`start` riesce anche su percorsi arbitrari: il test agisce quindi direttamente
sul discriminante, che è la parte che contiene la decisione.

**3. `FLAG_ENC_FILENAME` non è acceso quando il nome è nascosto.** Nasconderlo
non significa cifrarlo: significa non memorizzarne alcuno. La distinzione conta
per la UI — `filename` vuoto **con** flag acceso vuol dire "serve la password",
**senza** flag vuol dire "questo file non ha un nome da mostrare". Emerso da
un'asserzione sbagliata in un test, ed è ora fissato in entrambe le direzioni.

**4. UniFFI non esporta i metodi dei record** (già visto sugli enum in M3):
`is_tar_container` era invisibile a Swift. Riscrivere le maschere di §16.3 in
Swift le avrebbe fatte divergere in silenzio — una maschera sbagliata non è un
errore di compilazione, è una schermata che descrive il file in modo errato.
Esposte come `describe_header`.

Stessa ragione per `safe_output_name`: il nome dell'header diventa un percorso
**anche in Swift**, quando nomina il file decifrato, e
`URL.appendingPathComponent` non neutralizza né le risalite né i percorsi
assoluti. È la stessa classe di difetto della revisione post-M3, sull'altro lato
del confine. Una sola sanificazione, in Rust.

#### Scelte di implementazione

- **Una cartella di lavoro per operazione**, rimossa appena l'utente ha salvato,
  annullato, o cambiato file; `purgeStale()` all'avvio elimina i residui di una
  sessione interrotta. L'output è in chiaro: non deve sopravvivere alla schermata
- **Il nome definitivo si conosce solo dopo la decifratura** — su v5 il nome
  originale è cifrato nell'header — quindi si lavora su un segnaposto e si
  rinomina alla fine
- **Archivio estratto**: se contiene una sola voce di primo livello si consegna
  quella, altrimenti l'utente riceverebbe una cartella dentro una cartella
- **`ShareLink` solo sui file**: una cartella non è un contenuto che le
  destinazioni della share sheet trattino in modo prevedibile. "Salva in File"
  gestisce entrambi
- **Aggancio `-apri-fixture` per i UI test.** Il `.fileImporter` è interfaccia di
  sistema fuori processo e non è pilotabile; l'argomento inietta una fixture
  attraverso lo **stesso** percorso di `.onOpenURL`, che è anche il flusso da
  verificare. È il motivo per cui le fixture restano nel bundle in Debug
- **Copertura di Verify spostata sul modello**: i suoi due UI test dipendevano
  dal picker di fixture, ora rimosso

#### Sovrascrittura: dove sta davvero la garanzia

Con la strategia A di §6.3 la destinazione la sceglie il sistema, che **chiede**
in caso di collisione — osservato salvando due volte lo stesso nome. `OUTPUT_EXISTS`
resta la garanzia del livello Rust e ha un test, ma diventa centrale con la
strategia B (scrittura diretta in una cartella autorizzata) e i bookmark
persistenti di §6.4: **nessuno dei due è di M4**, perché il criterio di uscita
non li richiede. Vanno affrontati quando si vorrà l'uso ripetuto fluido.

#### Rinviato, deliberatamente

| Cosa | Dove |
|---|---|
| Pausa dell'operazione (`CancelToken.set_paused`, esposto ma inutilizzato) | M5, con la sezione esecuzione |
| Preflight memoria in decifratura — i parametri vengono dall'header e non sono negoziabili | M10, come da piano |
| Verifica dello spazio prima di iniziare | M6 |
| Bookmark persistenti, cartella di destinazione ricordata | dopo M8 |
| Prova su device reale | bloccata da **D4** |

---

### M4 — dettaglio originale del piano

- **Pulizia del debito di M3** (vedi sopra): rimuovere `VerifyView`, le fixture dal bundle dell'app e la relativa voce in `project.yml`
- `FileAccess.swift`: helper `withSecurityScope` **unico e non duplicato** (§6.1). Lo scope va tenuto aperto per **tutta** la durata dell'operazione: chiuderlo prima produce `IO_ERROR` intermittenti su file grandi — è l'errore classico
- `CrypteraEngine` actor: chiamate UniFFI su task `.userInitiated`, **mai sul main actor** (sono sincrone e bloccanti)
- Progress con **throttling ~10 update/s** — senza, un file grande blocca la UI
- `DocumentTypes.swift` + `Info.plist`: UTType esportato `com.cryptera.ecf`, `CFBundleDocumentTypes` ruolo Editor, `LSSupportsOpeningDocumentsInPlace = YES`, `UISupportsDocumentBrowser = NO`
- `.onOpenURL` → instrada alla schermata Decrypt precompilata
- Output: cifratura in `temporaryDirectory` → `.fileExporter` / share sheet, con pulizia del temporaneo
- **Mai sovrascrivere silenziosamente**: collisione nomi → `OUTPUT_EXISTS`

**Exit:** `.ecf` aperto da app File, decifrato, salvato via share sheet.

---

### M5 — Encrypt file ✅ COMPLETATA (2026-07-24)

**Exit raggiunto:** si sceglie un file, si cifra e si salva. **99 test verdi** —
39 Rust, 53 XCTest, 7 UI test. Il round-trip fra le due schermate (cifra con
Encrypt, ridecifra con Decrypt, confronta il contenuto) è un test.

Realizzato: `PasswordStrength` portato dall'upstream, `EncryptModel`,
`EncryptView`, pausa dell'operazione, avviso di irreversibilità, e un **design
system** applicato a tutte e tre le schermate.

#### Anticipato da M9: il design

Richiesto esplicitamente in corso d'opera. Non è M9 completa — mancano tema
selezionabile, i18n, verifica Dynamic Type e VoiceOver — ma la base c'è e le
schermate future la ereditano invece di doverla retrofittare.

- **Dal desktop si prendono i colori, non la forma.** Il verde `--accent`
  (`#1AAB82` chiaro, `#35D0A1` scuro) resta l'identità di Cryptera; la finestra
  con titlebar custom e pannelli in vetro no — è pensata per un mouse su uno
  schermo grande
- **Card al posto di `Form`.** SPEC §8.4 indica `Form`/`insetGrouped`, che però
  danno a ogni schermata l'aria di un pannello di Impostazioni. La struttura
  resta nativa — contenuto scorrevole, superfici e colori semantici, che
  seguono da soli chiaro/scuro e contrasto elevato — con spaziature e gerarchia
  decise da noi
- Componenti condivisi in `UI/Components.swift`: card, riga file, campo password
  con visibilità, barra di robustezza, riga metadato, avviso, pulsante
  principale, pannello di esecuzione

**Tre difetti trovati guardando l'app, non i test:**

1. **Sotto il contenuto restava un'area bianca.** Lo sfondo era applicato alla
   `ScrollView`, che copre solo l'area del contenuto: appena si scorreva oltre
   la fine compariva il bianco della finestra. Ora sta dietro, e ignora le safe
   area
2. **Il tint grigio dell'intestazione "Opzioni" si propagava ai controlli
   interni**, spegnendo interruttori e segmenti — un toggle attivo appariva
   grigio, cioè sembrava spento
3. Pulsante disattivato troppo pesante e icona dell'occhio in verde, che
   competeva con l'azione principale

> Nota utile: nelle catture il contenuto dei `SecureField` **non compare**. Non
> è un difetto — è la protezione dalla cattura schermo di SPEC §12.3, vista
> funzionare.

#### Due comportamenti del desktop che vanno replicati, non ammorbiditi

**1. La policy password blocca, non avvisa.** `operations.js` esce da
`handleEncrypt` senza cifrare se la password non ha almeno 10 caratteri e
livello ≥ 2. Qui fa lo stesso: il pulsante resta spento e il motivo è scritto
accanto. Un limite che si può ignorare non è un limite, e la differenza fra le
due piattaforme sarebbe silenziosa.

**2. L'avviso di irreversibilità si mostra una volta sola.** Come il flag in
`localStorage` del desktop. Ripeterlo a ogni cifratura lo trasformerebbe in un
ostacolo da chiudere senza leggere.

#### Il port della robustezza password ha due trappole

Sembra una funzione da ricopiare, e non lo è del tutto:

- **Le classi di caratteri delle regex sono solo ASCII.** `isUppercase` di Swift
  è vera per "À" e `isNumber` per le cifre arabo-indiane, che il desktop non
  conta. Usare le proprietà Unicode darebbe un giudizio diverso sulla stessa
  password
- **La lunghezza è quella di JavaScript, in unità UTF-16.** Con `String.count`
  un'emoji varrebbe 1 invece di 2 — e siccome la lunghezza **blocca** la
  cifratura, una password accettata dal desktop verrebbe rifiutata qui

Vive in Swift e non in Rust perché non determina il *contenuto* del file: la
regola di SPEC §2.2 riguarda ciò che finisce nel formato.

#### La "stima del tempo" di §8.2 non è scrivibile in secondi

Un tempo in secondi dipende dal dispositivo e nessuna misura è disponibile prima
di eseguire l'operazione: sarebbe un numero inventato. Si espone invece
`security_profile_params` da Rust e si mostra ciò che è **derivato e
verificabile** — memoria esatta, numero di passaggi, e il rapporto di lavoro
rispetto al profilo Standard (`t·m`). L'avviso memoria di §11.2 resta esatto e
blocca l'operazione.

La dimensione finale stimata usa l'overhead di parità di Rust. È dichiarata
approssimata: ignora header e trailer e **non può tenere conto della
compressione**, il cui effetto dipende dal contenuto — con la compressione
attiva il file reale è più piccolo, mai più grande.

#### Altre scelte

- **`k`/`r` non si mostrano più grezzi** in Decrypt e Verify: "2 blocchi ogni 4"
  invece di "k 4 / r 2". Il rapporto è il vocabolario del formato, non quello di
  chi sta guardando se il suo file è a posto
- **Pausa** finalmente collegata (`CancelToken.set_paused`, esposto da M3 e mai
  usato) su tutte e tre le operazioni — era il debito rinviato da M4
- **Aggancio `-cifra-fixture`** simmetrico a quello di M4, per la stessa ragione:
  il `.fileImporter` è fuori processo e non è pilotabile
- **Le password vengono azzerate a operazione conclusa.** Non è la zeroizzazione
  che SPEC §12.1 dichiara onestamente impossibile in Swift: è ridurne la vita,
  che è quanto si può fare
- I UI test cercano per identificatore **senza vincolare il tipo**: lo stesso
  elemento diventa `staticText` o `otherElement` a seconda che contenga un
  pulsante, e legarli al tipo li farebbe fallire a ogni ritocco della vista

#### Revisione post-M5 (2026-07-24) — il difetto che la suite non poteva vedere

**Segnalato usando l'app, non trovato da un test: nessun pulsante di scelta del
file apriva niente.** Su tutte e tre le schermate.

Causa: **due `.fileImporter` applicati alla stessa view**. Due modificatori di
presentazione dello stesso tipo sullo stesso punto della gerarchia entrano in
conflitto — SwiftUI ne onora uno solo e l'altro non apre nulla, senza errori né
avvisi in console. Ogni schermata ne aveva due, uno per l'input e uno per il
keyfile: funzionava il secondo.

Corretto attaccando ciascun importer alla card che lo apre, quindi a due view
distinte.

**Perché 99 test non l'hanno visto.** Tutti iniettano il file dall'argomento di
lancio — la scorciatoia introdotta in M4 perché il `.fileImporter` è interfaccia
di sistema, fuori processo e non pilotabile. Quella scorciatoia **salta
esattamente il pezzo che si era rotto**, e sembrava un dettaglio di comodità
quando è stata introdotta.

`FilePickerUITests` copre ora il tratto scoperto: verifica che il selettore di
sistema compaia davvero, su tutte e tre le schermate, e che sulla schermata
Cifra funzionino **entrambi** — perché con uno solo per schermata il difetto
sarebbe passato lo stesso.

**Lezione, valida per M6 in avanti:** una scorciatoia introdotta per rendere
testabile qualcosa crea una zona che i test non attraversano più, e va coperta
di proposito. Il difetto era visibile in due secondi aprendo l'app.

#### Rifinitura post-M5 (2026-07-24) — parte di M9 anticipata

Tre richieste in corso d'opera, tutte partite dall'uso reale dell'app.

**1. La barra della password e il pulsante dicevano cose opposte.** Una password
di **nove** caratteri con tipi misti arriva a 4 punti, quindi livello 3: la
schermata mostrava "Good password" mentre il pulsante restava spento, perché la
policy chiede *anche* dieci caratteri.

L'upstream lega l'incoraggiamento al solo livello, e nella sua interfaccia
funziona — mostra la violazione della policy solo al momento di cifrare. Qui i
due messaggi stanno sotto gli occhi insieme. **La policy non è cambiata** (è
parità, e la stessa password deve essere accettata o rifiutata su entrambe le
piattaforme): è cambiato quale messaggio si mostra, e il motivo del blocco ora
distingue "servono dieci caratteri" da "mescola più tipi" invece di dire
genericamente "troppo debole".

**2. Inglese predefinito, italiano come traduzione.**

**Deviazione deliberata dal piano.** M9 prevedeva di conservare le chiavi
dell'upstream (`nav_encrypt`, `err_password_invalid`) per poter confrontare le
due interfacce. Ma le stringhe di iOS non corrispondono più a quelle del
desktop — le schermate sono altre — quindi il confronto sarebbe stato formale e
non reale. **La chiave è la stringa inglese**: esiste un solo file da mantenere
(`it.lproj`), e una chiave senza traduzione ricade sull'inglese invece di
mostrare un identificatore all'utente, che è il modo in cui le localizzazioni a
chiavi simboliche si rompono in produzione. Dove la corrispondenza è reale — i
messaggi d'errore — la chiave dell'upstream resta annotata in `ErrorPresenter`.

Le traduzioni di errori e robustezza password sono **portate** da `i18n.js`, non
riscritte.

Non si usa `Text("literal")` di SwiftUI: risolve sempre nella lingua di
**sistema** e ignorerebbe la scelta fatta nelle impostazioni. Tutto passa da
`L.t(...)`, e `scripts/check-localization.sh` verifica che ogni chiave usata nel
codice abbia una traduzione — una chiave mancante non fallisce da sola, perché
il fallback è una frase sensata.

**3. Schermata Impostazioni**: lingua, tema, predefiniti di cifratura,
ripristino dell'avviso di irreversibilità, versioni. Il tag del core viene dal
binario, non da una costante riscritta a mano.

#### Altri tre difetti, tutti visti guardando l'app

- **I `Picker` non mostravano la propria etichetta.** Fuori da un `Form` SwiftUI
  rende il solo valore corrente: la schermata Impostazioni era un elenco di
  parole senza sapere cosa regolassero. Risolto con `ChoiceRow`, che l'etichetta
  la disegna
- **Un predefinito cambiato non raggiungeva la schermata Cifra**, perché la
  `TabView` costruisce il modello una volta sola: l'impostazione era salvata e
  inerte. Ora si rileggono **a schermata ferma** — rileggerli sempre
  sovrascriverebbe scelte fatte apposta per il file in corso
- **Un identificatore su un contenitore si propaga ai discendenti**, e la
  ricerca ne trovava più d'uno: va sul controllo vero

#### Segnalazioni dall'uso su iPhone (2026-07-24)

**1. Cambiando tema la barra delle schede restava indietro** finché non la si
toccava: l'app appariva metà chiara e metà scura. `.preferredColorScheme` agisce
sull'albero SwiftUI, ma la barra è **UIKit** e non si ridisegna finché qualcosa
non la costringe. Si scrive quindi `overrideUserInterfaceStyle` sulla finestra,
che aggiorna subito tutto ciò che vi è contenuto, chrome di sistema compresa.

Ricostruire l'albero come si fa per la lingua avrebbe funzionato, ma cambiare
tema avrebbe buttato via il file scelto e la password digitata: una preferenza
di aspetto non deve costare il lavoro in corso.

**2. Aggiunto il ripristino** su Cifra, Decifra e Verifica — nella barra di
navigazione, perché agisce sulla schermata intera. Su Decifra scarta anche la
**copia in chiaro**, che è la ragione principale per cui serve: dopo aver
finito non si vuole lasciare in giro un file decifrato solo perché si è cambiato
schermata. Chiede conferma **solo** quando c'è davvero un file non ancora
salvato da perdere; chiederla sempre la renderebbe un riflesso.

Resta visibile ma spento quando non c'è nulla da azzerare: un pulsante che
appare e sparisce è più difficile da ritrovare di uno sempre nello stesso posto.

#### Due trappole nei test, che valgono per il seguito

- **La lingua del simulatore rendeva i test non deterministici**: verdi su una
  macchina italiana, rossi altrove. Ora la lingua si fissa dall'argomento di
  lancio. Il pulsante del **selettore di sistema** resta però nella lingua del
  dispositivo, e si accettano le due lingue dell'upstream
- **Il dominio degli argomenti ha la precedenza su `UserDefaults`**: con
  `-appLanguage` impostato, una lingua scelta dentro l'app verrebbe letta
  comunque come quella dell'argomento. Il test che cambia lingua è l'unico a non
  usarlo, e raggiunge le schede per posizione
- Le impostazioni **sopravvivono fra un'esecuzione e l'altra** nel contenitore
  dell'app: un test che ne legge una deve prima azzerarla, o diventa verde o
  rosso a seconda di cosa è girato prima. È già successo due volte — sui
  predefiniti di cifratura e sul tema — e la seconda ha fatto sembrare rotta una
  correzione che funzionava. Quando la preferenza è anche quella che il test
  cambia, l'argomento di lancio **non** è la soluzione: ha la precedenza sulle
  scritture, quindi lo stato noto va stabilito passando dalla UI

#### Rinviato

| Cosa | Dove |
|---|---|
| Cifratura di cartelle, TAR, verifica dello spazio | M6 |
| Tema selezionabile, i18n, Dynamic Type e VoiceOver verificati | M9 |
| Preflight memoria in **decifratura** (parametri dall'header) | M10 |
| Prova su device reale | bloccata da **D4** |

---

### M5 — dettaglio originale del piano

Opzioni, progress, pausa/annulla. Punti che la UI deve rendere espliciti:

- **Profilo integrità**: mostrare overhead in % e **dimensione finale stimata**, altrimenti `Max` sorprende l'utente con un file 4× più grande
- **Profilo sicurezza**: stima tempo + avviso memoria (§11.2)
- Indicatore robustezza password — portare la logica di `ui/modules/password.js`
- Keyfile: spiegare chiaramente che **perderlo equivale a perdere la password**

---

### M6 — Encrypt cartella ✅ COMPLETATA (2026-07-24)

**Exit raggiunto:** si sceglie una cartella, si cifra in un unico `.ecf`, e la
si riestrae dalla schermata Decifra con struttura e contenuti intatti — il
round-trip è un test. **134 test verdi** (39 Rust, 74 XCTest, 21 UI test).

Il grosso del lavoro era già in piedi: `InputSource::Folder`, `create_tar` e il
pre-conteggio delle entry vengono da M3. M6 ha aggiunto il lato iOS.

#### Il pezzo che è davvero di M6: lo spazio

Una cartella passa da un **archivio TAR intermedio**, quindi serve circa il
doppio della sorgente, più la parità: con il profilo massimo si superano le
**cinque volte** la cartella di partenza. Scoprirlo a metà operazione significa
aver già speso minuti di CPU e riempito il disco.

`StorageCheck` verifica prima di iniziare, con
`volumeAvailableCapacityForImportantUsage` — il valore che tiene conto di quanto
iOS è disposto a liberare, non la capacità grezza. La stima è **volutamente per
eccesso**: ignora la compressione, il cui effetto dipende dal contenuto. Un
preflight che sbaglia per eccesso rifiuta qualche caso che sarebbe passato; uno
che sbaglia per difetto lascia l'utente a metà strada.

Quando il sistema non espone la capacità non si blocca nulla: rifiutare per un
dato mancante sarebbe peggio che provarci.

#### Scelte

- **Compressione archivio al posto di quella del payload.** Per una cartella il
  payload *è* il TAR, già compresso secondo `archiveCompression`: comprimerlo
  due volta lo farebbe solo crescere. La UI mostra l'una o l'altra, mai
  entrambe, e un test verifica che il flag di compressione del payload resti
  spento nell'header anche se l'impostazione dice altro
- **Predefiniti dell'upstream**: archivio `none` (`ui/index.html`,
  `encFolderComp`) e "salta file speciali" attivo. Non cambiano la compatibilità
  del formato, ma partire da valori diversi darebbe output di dimensione diversa
  a parità di scelte
- **Un solo `.fileImporter` per due pulsanti**, con il tipo che cambia: due
  sulla stessa view sarebbero entrati in conflitto, ed è già successo
- **Il tipo si rilegge dall'URL**, non da cosa si stava scegliendo: il selettore
  di sistema può sempre restituire altro
- **La misura della cartella avviene fuori dal main actor** e con lo scope
  aperto — su una cartella grande l'attraversamento non è istantaneo — e la si
  scarta se nel frattempo l'utente ha cambiato scelta

#### Due difetti trovati dai test appena scritti

- **`requiredBytes` andava in trap** su dimensioni assurde: `Double` → `UInt64`
  con overflow termina il processo. Un preflight non può essere il punto in cui
  l'app muore, tanto più che il dato arriva dal filesystem. Ora satura, e il
  valore saturato viene comunque rifiutato dal confronto — che è l'esito giusto
- **Un identificatore sul `DisclosureGroup` sovrascriveva quelli dei figli**:
  tutti e tre gli interruttori delle opzioni si chiamavano `encrypt.options`.
  Stessa classe del difetto già visto su `ChoiceRow`, e vale la regola generale:
  **gli identificatori vanno sulle foglie**

---

### M6 — dettaglio originale del piano

TAR + compressione archivio. La cifratura di cartelle **è possibile**: un URL di
cartella dal picker è navigabile ricorsivamente con `walkdir` finché lo scope è
attivo.

**Verificare lo spazio prima di iniziare** (`volumeAvailableCapacityForImportantUsageKey`):
nel caso peggiore serve ~2× la sorgente (TAR intermedio + output) più
l'overhead di parità, fino al 300% con profilo `Max`. Fallire subito con
`INSUFFICIENT_STORAGE`, non a metà operazione.

---

### Prova su device reale e round-trip col desktop (2026-07-24)

**Riuscite entrambe, riferite dall'utente.** L'app gira su iPhone fisico, e un
file cifrato dal telefono è stato **decifrato dall'applicazione desktop**.

Conseguenze sul piano:

1. **La riserva di M2 è sciolta.** Il criterio della spec diceva "su device
   reale" e fino a qui era verificato solo su simulatore.
2. **La decisione D4 è di fatto risolta**: l'installazione su device è avvenuta,
   quindi M10 (test memoria sotto Instruments) e M11 non sono più bloccate.
3. **M7 punto 3 ha una prima conferma manuale.** È il punto che il piano indica
   come *l'unico test che dimostra davvero la compatibilità*. Resta però da
   fare come **test automatico in CI**, nelle due direzioni: una prova manuale
   riuscita non impedisce a una modifica futura di rompere il formato senza che
   nessuno se ne accorga. M7 resta il gate di rilascio.

---

### M7 — stato punto per punto (2026-07-24)

| | Punto | Stato |
|---|---|---|
| 1 | Lettura delle fixture upstream col plaintext atteso | ✅ confronto byte per byte, con la stessa formula di `tests/format_compat.rs` dell'upstream |
| 2 | Round-trip locale | ✅ nei test; su device verificato a mano |
| 3 | **Round-trip incrociato** ⭐ | ✅ **desktop → iOS automatizzato**; iOS → desktop resta manuale, vedi sotto |
| 4 | Recupero FEC | ✅ **fatto** |
| 5 | Manomissione header | ✅ fatto in M3, in entrambe le direzioni |

#### Punto 4 — recupero FEC

Il piano chiedeva "uno shard corrotto → recupero; più di `r` → `CORRUPT_BEYOND_FEC`".
Si verifica invece il **confine**: esattamente `r` shard si recuperano, `r + 1`
no. Con un solo shard corrotto un errore nel conteggio delle cancellature
passerebbe inosservato. L'approccio è portato da `tests/control_and_fec.rs`
dell'upstream sulla nostra superficie, così a essere verificata è anche la
mappatura dell'errore che arriva a Swift.

Dal lato applicazione si copre l'altra metà della frase — *«mai un output
silenziosamente sbagliato»* — con tre asserzioni: un file distrutto non produce
alcun output, il messaggio che arriva all'utente è presentabile, e **un danno
contenuto si recupera restituendo i byte originali**. Senza quest'ultima, le
prime due sarebbero soddisfatte anche da un core che rifiuta qualunque file
toccato: dimostrerebbero che l'app non sbaglia, non che il recupero funziona.

#### Punto 3 — cosa può davvero essere automatizzato

**L'applicazione desktop non è pilotabile da uno script.** È un'app Tauri il cui
`tauri.conf.json` dichiara solo i plugin `dialog` e `updater` — niente `cli` — e
il core `crypto_core_rs` è una libreria senza `[[bin]]`. Non esiste un comando
da invocare.

Questo rende le due direzioni **asimmetriche**, ed è la cosa che il piano non
aveva previsto:

- **Desktop → iOS** si automatizza congelando gli output: si producono una volta
  con l'app vera, si committano, e ogni esecuzione successiva li ridecifra
  confrontando i byte. Sono artefatti del binario reale e restano validi per
  sempre. È lo stesso motivo per cui l'upstream committa `tests/fixtures/`.
  Sorgenti deterministiche e istruzioni sono in `CrypteraTests/CrossFixtures/`.
- **iOS → desktop** si automatizza **molto meno di quanto sembri**: il percorso
  di lettura del desktop è `crypto_core_rs`, la stessa libreria allo stesso tag
  che usiamo noi. Un test che "verifica" i nostri file con quel core
  confronterebbe il codice con sé stesso. L'unico controllo indipendente è
  aprire il file con il binario spedito, e resta un **passo manuale della
  checklist di rilascio** — già eseguito con successo una volta.

Va detto così nel piano invece di simulare una copertura che non esiste.

#### Punto 3 — esito

**Otto file prodotti dall'applicazione desktop 2.0.4 e congelati**, letti dal
codice iOS con confronto byte per byte: 11 test verdi al primo colpo. Coprono
tutti e tre i profili Argon2, i due estremi di `k`/`r`, entrambe le compressioni
del payload — LZMA2 compresa, che dipende da `liblzma` — il nome nascosto, il
keyfile, e i tre decoder d'archivio.

Tre asserzioni valgono più delle altre:

- **I parametri dei profili coincidono.** Se una tabella di §5.2 divergesse, i
  file resterebbero leggibili ma non sarebbero più gli stessi file, e nessun
  altro test se ne accorgerebbe. I valori attesi sono scritti a mano nel test:
  leggerli da Rust lo renderebbe d'accordo con un eventuale errore in Rust
- **Il file con keyfile non si apre senza keyfile.** Senza questa, la prima
  proverebbe solo che la password funziona
- **Le tre compressioni d'archivio hanno prodotto payload di dimensione
  diversa** (575, 532, 903 byte). Se il desktop avesse ignorato la scelta, i tre
  test d'estrazione sarebbero passati comunque

**Conferma indipendente di una scoperta di M5:** `desktop-nome-nascosto.ecf` ha
`FLAG_ENC_FILENAME` **spento**. Nascondere il nome non significa cifrarlo,
significa non memorizzarne alcuno — dedotto dal nostro writer in M5, ora
confermato dai byte del desktop.

---

### M7 — Compatibilità 🚦 gate di rilascio

**Nessun rilascio, nemmeno a se stessi, prima che questa milestone sia verde.**

1. **Lettura** — decifrare ogni fixture upstream, verificare il plaintext atteso (copre v4 legacy e v5)
2. **Round-trip locale** — cifra e ridecifra su device
3. **Round-trip incrociato in CI** ⭐ — cifra col binario desktop → decifra con codice iOS, e viceversa. **È l'unico test che dimostra davvero la compatibilità**: tutti gli altri possono passare con un formato divergente. Richiede un runner macOS
4. **Recupero FEC** — corrompere uno shard → recupero ok; corromperne più di `r` → `CORRUPT_BEYOND_FEC`, mai un output silenziosamente sbagliato
5. **Manomissione header** — un byte modificato → `HEADER_AUTH_FAILED`

---

### M8 — Batch + Audit ✅ COMPLETATA (2026-07-24)

**Exit raggiunto:** coda di `.ecf` con password unica ed esecuzione sequenziale,
registro operazioni JSONL persistente. **171 test verdi** (40 Rust, 106 XCTest,
25 UI test).

#### Batch: il difetto della 2.0.3 non c'era da riportare

Il piano avverte di portare la logica della 2.0.4, che ispeziona l'header di
ogni file per distinguere un `.ecf` singolo da un archivio TAR — la 2.0.3
assumeva un container e falliva con `EXTRACT_ERROR` oppure `OUTPUT_EXISTS`.

**Da noi quella distinzione è già dentro `decrypt` dal M4**: il crate controlla
`FLAG_TAR_CONTAINER` e sceglie da sé se estrarre o spostare. Riscriverla in
Swift sarebbe stata una seconda copia della stessa decisione, libera di
divergere dalla prima.

#### Scelte

- **Sequenziale, non parallelo.** Ogni file deriva la propria chiave con Argon2,
  che alloca fino a 512 MiB: due derivazioni insieme raddoppierebbero il picco, e
  su iOS il superamento del limite jetsam non è un'eccezione ma la morte del
  processo (SPEC §11.2)
- **Un solo export alla fine.** I risultati finiscono in una cartella unica: su
  iOS ogni salvataggio passa da un selettore di sistema, e presentarne uno per
  file trasformerebbe un batch di venti file in venti interruzioni
- **Un file rotto non ferma la coda** — se bastasse, tanto varrebbe farli uno
  per uno
- **Nomi uguali non si sovrascrivono** (SPEC §6.3): due `.ecf` diversi possono
  contenere file con lo stesso nome

#### Registro: due differenze rispetto all'upstream

**1. Si registra il nome, non il percorso.** Su iOS un percorso contiene
identificatori del container e punti di mount dei file provider: non dice nulla
a chi legge e lascia un'impronta di dove l'utente tiene le sue cose. È anche lo
spirito di SPEC §12.3. Un test verifica che nessun percorso finisca nel file.

**2. C'è un interruttore, acceso di serie.** L'upstream registra sempre, senza
opzione. Un telefono però si perde, e un registro persistente di cosa si è
cifrato è un dato sensibile a sé. Il comportamento predefinito resta quello del
desktop.

Il file nasce **già** con Data Protection `.complete`, come chiede il piano:
applicarla dopo la creazione lascerebbe una finestra in cui esiste senza. A
dispositivo bloccato il registro non è scrivibile, il che non è un limite —
a dispositivo bloccato non ci sono operazioni da registrare.

**Uno storico volatile separato non esiste.** L'upstream ne tiene uno da 100
voci in memoria *oltre* al registro su file; qui la schermata Attività legge il
registro. Due elenchi della stessa cosa sarebbero due posti dove cercare la
stessa risposta — e con l'interruttore spento lo storico volatile registrerebbe
comunque, vanificando l'interruttore.

Nel registro va il **codice** stabile dell'errore, mai il messaggio: i codici di
§10.1 non cambiano e non sono localizzati, quindi un registro vecchio resta
leggibile e confrontabile con quello del desktop. Il messaggio localizzato resta
nelle schermate operative (§10.3).

#### Tre difetti trovati dai test

- **Il rinomino del batch aggiungeva " 2" al nome** quando il nome originale
  coincideva con quello di lavoro: `uniqueURL` trovava occupato **il file
  stesso**. Ogni file il cui nome interno coincide col nome del `.ecf` ne era
  colpito, cioè il caso normale
- **Un test raggiungeva le impostazioni per indice di scheda**, e la scheda
  Batch ha spostato tutto. Ora si lega all'**ultima** scheda, che è una
  proprietà stabile del layout
- **Lo script di localizzazione non vedeva le chiamate su più righe**, e
  segnalava come inutilizzata una chiave che era in uso. Corretto lo script, non
  il codice

---

### Allineamento col desktop 2.1.1 (2026-07-25)

Il desktop è passato 2.0.4 → 2.1.0 → 2.1.1 mentre iOS era su M4–M8. Verifica di
cosa andava portato, e di cosa no.

**Il core non è cambiato.** `git diff v2.0.4..v2.1.1 -- src/` è vuoto: fra il
pin di `cryptera-ffi` e l'ultima release del desktop è cambiato solo il numero
di versione in `Cargo.toml`. Il formato `.ecf` è identico e il gate M7 non è
toccato. Tutto il lavoro 2.1.x sta in `cli/`, `ops/`, `src-tauri/`, `ui/`.

È il controllo da rifare a ogni allineamento: **il numero di versione non dice
niente**: va guardato il diff di `src/`.

| Novità del desktop | Esito |
|---|---|
| CLI `cryptera` (2.1.0) | Non applicabile — su iOS non c'è una CLI |
| Crate condiviso `ops/` (2.1.0) | Non adottato — vedi sotto |
| UI: nascondere i controlli del modo non attivo (2.1.0) | Già così: la UI nativa è guidata dal modo |
| Sanificazione dei nomi container (2.1.0) | Già presente — `safe_basename` |
| Nomi di device riservati Windows (2.1.1) | Non applicabile |
| Bump `crossbeam-epoch` RUSTSEC-2026-0204 (2.1.1) | Già a 0.9.20 |
| **Estrazione per magic bytes (2.1.1)** | **Portato** — vedi sotto |

#### Il difetto: cartella compressa + nome nascosto

`safe_extract_tar` prendeva la compressione come parametro esplicito, e il
chiamante la deduceva dal **nome memorizzato nell'header**. Era già una
correzione rispetto all'upstream, che la deduceva dal *percorso* e per questo
non estraeva nulla dal temporaneo senza estensione — il difetto che il desktop
ha poi corretto nella 2.1.1.

Ma con `hide_filename` il nome nell'header è vuoto, quindi la deduzione dava
`None` e un archivio gzip finiva nel decoder "tar semplice":

```
None  hide=false → ok        Gzip  hide=true → ExtractError
None  hide=true  → ok        Bzip2 hide=true → ExtractError
Gzip  hide=false → ok        Xz    hide=true → ExtractError
```

Entrambe le opzioni sono esposte nella schermata Encrypt, quindi **l'app
produceva file che non sapeva riaprire**: cifratura senza errori, decifratura
mai. Cancellato l'originale, su iOS i dati erano persi — mentre il desktop
2.1.1 quegli stessi file li apre. Esattamente la divergenza che M7 esiste per
impedire, con l'asimmetria dalla parte sbagliata.

Portato il fix upstream: la compressione si deduce dai **magic bytes**
(`1f8b` / `BZh` / `fd 37 7a 58 5a 00`), che ci sono sempre, e
`archive_compression_from_name` è stata **rimossa** invece che lasciata
inutilizzata — finché esiste, qualcuno la ricollega.

Con `keep_archive` e nome nascosto il fallback era `decrypted.tar` anche su un
gzip: ora il suffisso viene dalla compressione reale (`decrypted.tar.gz`), come
nella 2.1.1. Un nome che mente su un archivio è un problema di chi dovrà
aprirlo.

Il test di regressione è il **prodotto cartesiano** compressione × nome
nascosto, non il caso singolo: il difetto stava solo sulla diagonale, e ogni
altra combinazione passava già.

#### Perché `ops/` non è stato adottato

Condividere il crate col desktop eliminerebbe la deriva, ma la versione iOS
diverge deliberatamente — errori `CrypteraError` invece di `OpError`, e nessuna
dipendenza dal filesystem del desktop. Il costo dell'adattamento supera il
beneficio; si riallineano le singole funzioni quando serve, come qui.

---

### M8 — dettaglio originale del piano

- Batch: lista con stato per-file, password unica, esecuzione sequenziale (rif. `ui/modules/batch.js`). **Portare la logica di v2.0.4**, che ispeziona l'header di ogni file e distingue `.ecf` singolo da archivio TAR — la 2.0.3 assumeva un container e falliva con `EXTRACT_ERROR`/`OUTPUT_EXISTS` sui file singoli
- Audit log JSONL nel container app (rif. `src-tauri/src/audit.rs`), protezione file `.complete`
- Storico in memoria (100 voci)

---

### M9 — Design system ✅ COMPLETATA (2026-07-25)

**Exit raggiunto:** Dynamic Type e VoiceOver verificati da un test su tutte le
schermate, contrasto del design system misurato invece che valutato a occhio,
barra laterale su iPad, icona con le tre apparenze di iOS 18.

La base era già stata anticipata in M5 (colori dal desktop, card native,
componenti condivisi) e la rifinitura post-M5 aveva chiuso tema selezionabile,
i18n e schermata Impostazioni. Restava la parte dichiarata «obbligatoria» dal
piano e mai verificata: Dynamic Type e VoiceOver.

#### Il metodo: `performAccessibilityAudit()`, in tre configurazioni

`CrypteraUITests/AccessibilityUITests` percorre tutte le schede e chiede a
XCTest il controllo automatico di accessibilità. Gira in **inglese a corpo
normale, inglese ad AX5 e italiano ad AX5**: le tre combinazioni non sono
decorative — il rilievo «Text clipped» comparve una volta in inglese e **due in
italiano**, perché le stesse schermate con stringhe più lunghe si tagliano
prima. Provare solo la lingua sorgente avrebbe nascosto la seconda.

#### Quattro difetti, nessuno visibile a corpo normale

1. **Le righe di scelta troncavano l'etichetta.** `ChoiceRow` affiancava
   etichetta e menu in un `HStack`, e l'etichetta cedeva lo spazio: ai corpi
   accessibili spariva proprio per chi aveva ingrandito il testo per leggerla.
   Ora il layout diventa verticale (`AnyLayout`) oltre la soglia accessibile, e
   l'etichetta manda a capo invece di troncare — serviva **anche a corpo
   normale**, con un valore lungo nel menu.

2. **«Vedi il registro» era alto 18 punti**, contro i 44 delle HIG. Non è un
   problema che si veda guardando l'app: si vede provando a toccarlo, o
   chiedendolo all'audit. Aggiunto `minimumHitTarget()` al design system, con il
   `contentShape` che serve perché l'area cresciuta riceva davvero i tocchi.

3. **L'accento verde non era leggibile come testo su fondo chiaro.** `.tint`
   lo rende il colore di ogni link e pulsante di testo dell'app, e il valore
   dell'upstream faceva 2,9:1 sulle card e 2,6:1 sulla pagina — sotto il 4,5:1
   di WCAG AA. Scurito a `#0D7A5C` (4,8:1) restando lo stesso verde. Il desktop
   la correzione la fa già (`#35D0A1` → `#1AAB82`), solo non abbastanza per un
   fondo chiaro: là l'accento vive quasi sempre su pannelli scuri.

4. **Nel tema scuro l'etichetta bianca del pulsante principale faceva 1,96:1**,
   cioè spariva. È il difetto che guardare il solo tema chiaro non fa vedere —
   lì l'accento è scuro e il bianco funziona; nel tema scuro l'accento è chiaro
   e brillante. Introdotto `Design.onAccent`, che sopra un riempimento accento
   è bianco nel tema chiaro e quasi nero in quello scuro.

#### Il contrasto si misura, non si valuta

`DesignSystemContrastTests` calcola il rapporto WCAG 2.1 alla sorgente, in
entrambi i temi, componendo l'alfa (i colori semantici di sistema non sono tinte
piene: `secondaryLabel` è un nero al 60%, e ignorarne l'alfa dà un numero
sbagliato e ottimista). È il posto dove i numeri esistono: l'audit dei UI test
dice «fallisce» senza dire di quanto, e solo dove quel colore compare.

**Le soglie seguono l'uso reale, non il tipo di colore.** In `Notice` i colori
info/avviso/errore tingono l'icona e un fondo al 10%, mentre il testo resta
primario: la soglia applicabile è quella degli elementi grafici (3:1). Averli
misurati come testo avrebbe fatto scurire tre colori per un problema
inesistente — la prima versione del test lo faceva, ed era il test a sbagliare.

**`secondaryLabel` non è stato sostituito.** A contrasto normale sta sotto il
4,5:1 (3,4:1 su card): è la gerarchia scelta da Apple per il testo di supporto,
identica in ogni app di sistema. Il punto è che l'utente può alzarla: con
"Aumenta contrasto" attivo i colori semantici si scuriscono da soli e superano
la soglia — verificato dal test. Un grigio fisso nostro non reagirebbe, e
darebbe un'app che *ignora* quell'impostazione invece di rispettarla.

#### Due esclusioni nell'audit, ricavate sperimentalmente

L'audit segnalava tre «Contrast failed» nelle Impostazioni, tutti sotto y≈960 —
**fuori dallo schermo**, che è alto 874 punti. Portandoli in vista con uno
scorrimento, due diventavano «nearly passed» e uno spariva: dentro una
`ScrollView` il contenuto oltre il bordo esiste nell'albero ma non è disegnato,
e il controllo del contrasto campiona i pixel. Il test ignora quindi gli
elementi che non intersecano lo schermo, e «nearly passed», che è la gerarchia
di sistema di cui sopra. Ogni altro rilievo lo fa fallire.

L'esperimento è servito: aveva **smentito in parte** l'ipotesi iniziale.
«Vedi il registro» falliva il contrasto anche una volta in vista — era un
difetto vero — ed è emerso il rilievo sull'area toccabile, che da fuori schermo
non compariva.

#### iPad e icona

- **Barra laterale.** `.tabViewStyle(.sidebarAdaptable)` invece del
  `NavigationSplitView` previsto: stesso esito visivo — barra in basso su
  iPhone, colonna laterale su iPad — senza ricostruire l'instradamento attorno
  a selezione e dettaglio. Richiede iOS 18 mentre il minimo è 17; sotto resta la
  barra delle schede, che su iPad funziona: si perde la colonna, non una
  funzione.
- **Larghezza leggibile.** Su iPad le card si stiravano per tutta la finestra:
  una riga con un'icona e due parole larga 1200 punti. Limitate a 700, allineate
  **a sinistra e non centrate** — centrandole non si allineavano più al titolo
  grande della barra di navigazione, che resta al bordo, e due assi diversi si
  leggono come un difetto.
- **Icona in tre apparenze** (iOS 18): standard, scura e colorata. Nella
  colorata il rapporto chiaro/scuro si **inverte**, perché il sistema schiarisce
  l'immagine per applicare la tinta e uno scudo scuro sparirebbe.

#### Rinviato

| Cosa | Dove |
|---|---|
| Prova con VoiceOver realmente acceso, su device | M10 — l'audit automatico non la sostituisce |
| Preflight memoria in decifratura | M10 |

---

### Prima esecuzione su device reale (2026-07-26)

Suite completa su **iPhone 14 Pro, iOS 26.5.2**, non in simulatore. Il profilo
di firma era già presente (team `QLGKZY3S8Q`), quindi non è servito toccare
`project.yml`: team e stile di firma si passano da riga di comando.

```bash
xcodebuild test -project Cryptera.xcodeproj -scheme Cryptera \
  -destination 'platform=iOS,id=<udid>' \
  DEVELOPMENT_TEAM=QLGKZY3S8Q CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates
```

**Primo giro: 15 test unitari e 1 UI rossi**, tutti verdi in simulatore. Cinque
cause distinte, e vale la pena distinguerle perché una sola è un difetto
dell'app.

#### 1. Un difetto vero, invisibile per costruzione in simulatore

`FileAccess.isInsideAppSandbox` confrontava i percorsi per prefisso di stringa.
Su device il confronto falliva **sui percorsi non ancora creati** — cioè su ogni
percorso di output — e si ricadeva su `isReadableFile`, falso per un file
inesistente: un percorso dentro il container veniva giudicato fuori.

La prima diagnosi era sbagliata. Avevo concluso che `NSHomeDirectory()` e
`temporaryDirectory` rispondessero con prefissi diversi; misurato sul telefono,
si normalizzano entrambi a `/var`. Il meccanismo vero è un altro:

```
tmp/                → /var/mobile/.../tmp            (esiste: /private tolto)
tmp/non-ancora.bin  → /private/var/mobile/.../tmp/…  (non esiste: /private resta)
```

`resolvingSymlinksInPath()` toglie il prefisso `/private` **solo se il percorso
corrisponde a un file esistente**. Da qui `canonicalPath`, che lo toglie in modo
esplicito e uniforme. È il motivo per cui la prima correzione — risolvere i
symlink su entrambi i lati — non aveva funzionato: su un percorso inesistente
quella chiamata non fa nulla.

**Impatto verificato: latente, non attivo.** Oggi gli output non passano da
`withSecurityScope` e gli input sono security-scoped, quindi la guardia non
viene attraversata. Ma era sbagliata, e in simulatore non lo sarebbe mai
sembrata: lì i container non stanno sotto `/private`.

#### 2. Il gate M7 falliva per un difetto del test

`CrossCompatTests` ricavava il percorso relativo sottraendo stringhe, e con il
`/private` di mezzo produceva `"/privatesotto/due.txt"`. L'app aveva decifrato
correttamente. Ora si contano i componenti del percorso.

Da annotare: **fino a questo giro il gate di rilascio non era mai stato
eseguito su hardware reale.**

#### 3, 4, 5. Ambiente, non codice

- **Le impostazioni reali dell'utente** facevano fallire il test che verifica il
  fallback di una preferenza *non impostata*: sul telefono quella preferenza
  esiste. Ora il test l'azzera e la **ripristina** in teardown — è una scelta di
  chi usa il telefono, non del test. Trappola già annotata dopo M5, ricomparsa
  dove era più facile scordarsela.
- **`Documents/Inbox` su device è del sistema**: l'app ci legge e ci cancella
  (tutto ciò che fa il codice di produzione) ma non può crearla. Era il test ad
  allestire lo scenario creandola: ora salta con una ragione esplicita.
- **L'audit di accessibilità dava esiti diversi**: gli stessi colori risultano
  "nearly passed" in simulatore e "Contrast failed" su iPhone, perché cambia lo
  spazio colore della cattura. Il contrasto è stato tolto dall'audit — un test
  che dipende dall'hardware non dice niente sul codice — ed è già misurato con
  numeri esatti in `DesignSystemContrastTests`, che copre gli stessi casi.

#### Un rilievo escluso con le prove, non per comodità

Su device compare `Potentially inaccessible text` nelle Impostazioni. Nasce
dall'analisi dell'immagine: `element` è `nil`, niente frame, niente testo —
l'API non dice *cosa* segnala. Il dump completo dell'albero di quella schermata
sull'iPhone mostra che ogni testo visibile **ha** il suo elemento, i menu
compresi (`'Language, English'`, non solo il valore). Non esiste il testo non
rappresentato che il rilievo descrive.

È escluso perché non azionabile: un test che fallisce senza indicare su cosa
intervenire insegna solo a ignorare i fallimenti. La domanda che pone resta
aperta e si chiude con VoiceOver acceso, in M10.

Dal dump è emerso anche che due icone della barra schede hanno per etichetta il
nome grezzo del simbolo (`checkmark.shield.fill`, `gearshape.fill`) invece di una
descrizione localizzata. Non è un difetto attivo — VoiceOver legge l'etichetta
del pulsante che le contiene — ma è da controllare nella prova VoiceOver.

**Esito finale: 110 unitari (1 saltato) e 26 UI verdi su device**, oltre ai 42
Rust e alla suite in simulatore.

#### Cosa questo giro *non* copre

Il device serve soprattutto per ciò che qui non è stato ancora misurato, e che
resta a M10: Data Protection sui file di lavoro, checkpoint puliti alla
sospensione, e VoiceOver realmente acceso.

---

### M10 punto 1 — memoria e jetsam, misurati su device (2026-07-26)

`CrypteraTests/MemoriaSuDeviceTests` misura invece di supporre. **I test
stampano numeri e asseriscono solo ciò che non dipende dallo stato del
telefono**: una soglia assoluta fallirebbe perché era aperta un'altra app, e
non direbbe niente sul codice.

Misure su **iPhone 14 Pro, iOS 26.5.2**, file da 4 KiB (così il tempo è tutto
Argon2 e non I/O):

| Profilo | Tempo | Crescita del picco | Richiesta dichiarata |
|---|---|---|---|
| Standard | 0,10 s | +64 MiB | 64 MiB |
| Strong | 0,77 s | +258 MiB | 256 MiB |
| Paranoid | 2,54 s | +512 MiB | 512 MiB |

**Il modello di memoria è esatto.** `securityProfileMemoryBytes` predice la
crescita reale del picco al MiB: il preflight non poggia su una stima
prudenziale ma sul valore vero. Con 3049 MiB disponibili al processo, `Paranoid`
ne usa il 16,8% — molto sotto la soglia del 50% — e **nessun profilo ha fatto
scattare jetsam**.

Misurare il picco ha richiesto un campionatore. Leggere l'impronta prima e dopo
**non basta**: Argon2 libera il blocco prima che l'operazione ritorni, e la
lettura finale può risultare *più bassa* di quella iniziale — con `Paranoid`
scendeva da 347 a 280 MiB e il picco non compariva da nessuna parte.

#### Il batch non accumula

Domanda che riguarda M8: le operazioni girano in sequenza nello stesso processo,
e fra un profilo e l'altro l'impronta di base non torna al valore iniziale
(23 → 89 → 347 MiB). Se quel residuo si sommasse a ogni file, una coda lunga
finirebbe per superare il limite — e jetsam non è un errore mostrabile, è
l'app che sparisce a metà lavoro.

Ripetendo `Paranoid` cinque volte il picco è **piatto**: 538, 539, 539, 538,
538 MiB, crescita zero. L'allocatore riusa le pagine liberate invece di
chiederne altre. Il test asserisce questo — che il picco non cresca di
iterazione in iterazione — e non un valore assoluto.

#### In simulatore la domanda non è ponibile

`os_proc_available_memory()` in **simulatore risponde 0**: non è implementata.
Non è un difetto da correggere — è la conferma che questi test hanno senso solo
su device. `fitsInAvailableMemory` tratta già lo zero come "stima non
disponibile" e **non blocca**, che è la scelta giusta: rifiutare tutto per
mancanza di una stima renderebbe l'app inutilizzabile proprio dove quella
chiamata non risponde.

Il test salta con quella ragione invece di asserire su un numero inesistente. È
emerso solo eseguendolo anche in simulatore dopo averlo scritto per il device —
la prima versione asseriva `richiesta ≤ disponibile / 2` e falliva contro uno
zero.

#### Cosa **non** è dimostrato (memoria)

Le misure vengono da un device con 6 GB di RAM, non sotto pressione di memoria.
Dicono che il **meccanismo** è corretto — il modello predice il consumo, la
soglia è rispettata, non c'è accumulo — non che `Paranoid` sia sicuro ovunque.
Su un device più piccolo o sotto pressione, `os_proc_available_memory()`
risponde meno e il preflight rifiuta: è il comportamento voluto, ma non è stato
osservato accadere. Serve un device che non lo regga, e non ne abbiamo uno.

---

### M10 — prove manuali, eseguite (2026-07-26)

Le due verifiche che nessun test automatico può sostituire, **eseguite da
Simone su iPhone 14 Pro e riferite come superate**. Sono annotate come tali, non
come osservate da chi scrive: chi rileggerà deve poter distinguere ciò che un
test dimostra a ogni esecuzione da ciò che una persona ha visto una volta.

**VoiceOver acceso** — percorse le cinque schermate. Ordine di lettura sensato;
la robustezza della password e il motivo del blocco vengono annunciati; il
progresso di un'operazione lunga è udibile; gli errori sono annunciati. Nessuna
lettura dei nomi grezzi dei simboli (`checkmark.shield.fill`,
`gearshape.fill`): VoiceOver legge l'etichetta del pulsante che li contiene, e
il sospetto sollevato dal dump dell'albero in M9 non si è confermato.

**App in secondo piano durante un'operazione lunga** (cartella, profilo
Paranoid) — la miniatura nel selettore mostra la copertura privacy, senza nomi
di file. Al ritorno l'operazione non resta in uno stato ambiguo, e non viene
lasciato alcun output parziale salvabile.

Con queste, tutto ciò che in M10 era verificabile è verificato. **Resta aperta
una sola voce, e non è un test**: `ITSAppUsesNonExemptEncryption` (§14.1), che è
una dichiarazione di export compliance e non una scelta di implementazione.
Finché non è presa, nell'`Info.plist` resta il commento — che è la cosa corretta,
perché una chiave sbagliata lì è peggio di una chiave assente.

---

### M12 — Nota cifrata (proposta, 2026-07-26)

Scrivere una nota testuale dentro l'app, cifrarla, e rileggerla decifrandola.
**Decisa la direzione, non ancora pianificata in dettaglio.**

#### Non tocca il formato

Una nota è un file di testo: cifrarla produce un `.ecf` ordinario, che il
desktop apre restituendo un `.txt`. Nessuna modifica al formato, nessun rischio
di divergenza.

Il formato ha due bit di flag riservati (`0x04`, `0x80`) e sarebbe stato
possibile marcare le note con uno di quelli. **Scartato**: marcare significa
toccare `crypto_core_rs`, quindi il desktop, per una funzione che il desktop non
ha — cioè esattamente la divergenza silenziosa che il progetto teme.

#### L'app non riconosce le note: le offre

Scelta fra tre possibilità (bit nel formato, convenzione sul nome, offerta in
base al contenuto), vince la terza: all'apertura, se il payload è piccolo e
UTF-8 valido, la schermata propone «mostra come testo» **accanto a** «salva
file».

Non richiede nulla, non rompe nulla, e funziona meglio delle alternative: una
nota scritta come `.txt` sul desktop diventa leggibile come nota su iPhone
senza che nessuno l'abbia progettato. Il file resta un file; è l'app che sa
presentarlo in due modi.

Nell'interfaccia, «Nota» diventa la **terza sorgente** del selettore
File/Cartella già presente in Cifra: nessuna sesta scheda, e password, profili
e output restano quelli.

#### Il vincolo di sicurezza, e cosa è davvero ottenibile

Il requisito posto è che nulla resti in chiaro e che le stringhe siano
azzerabili — password comprese. Va diviso in due parti, perché una è
raggiungibile e l'altra no.

**Raggiungibile, e da fare:**

- **Nessuna bozza in chiaro, mai.** Il testo in scrittura vive solo in memoria.
  Nessun salvataggio automatico, nessun ripristino dopo un riavvio: sarebbe una
  nota in chiaro su disco, cioè precisamente ciò che l'app esiste per evitare.
  Va scritto come **divieto**, non lasciato al buon senso di chi tocca il codice
  dopo.
- Il file temporaneo che diventa payload va in `TemporaryWorkspace`, che ha già
  `.completeUnlessOpen` e viene ripulito.
- Tastiera senza correzione automatica né testo predittivo: il sistema impara
  da ciò che si digita, e una nota cifrata non deve finire nel dizionario
  personale.
- Ridurre **durata e numero di copie**: non tenere il segreto in una proprietà
  del modello per tutta la sessione, convertirlo in un buffer azzerabile il
  prima possibile e azzerare quello.

**Non raggiungibile, e va detto invece di prometterlo:** una `String` Swift
**non è azzerabile**, e non esiste modo di aggirarlo restando su SwiftUI. Il
testo digitato attraversa il campo di input, la tastiera di sistema e il
runtime prima di arrivare al nostro codice, e in tutti quei passaggi è una
`String`/`NSString` la cui memoria non è nostra da sovrascrivere. Un campo di
testo "sicuro" scritto da noi non cambierebbe nulla: la tastiera consegna
comunque testo in quella forma.

Quindi: si può **ridurre molto l'esposizione**, non eliminarla. È lo stesso
limite già documentato in `SECURITY.md` per le password — con la differenza che
lì il segreto è la chiave, qui è il contenuto.

Se l'azzeramento garantito è un requisito irrinunciabile, la conseguenza non è
"scrivere più codice": è che il modello di minaccia della funzione va ristretto
(nessuna protezione contro chi esegue codice nel processo o preleva un dump di
memoria), oppure la funzione non va fatta. **È una decisione di prodotto e va
presa prima di implementare.**

#### Altre cose emerse, da non dimenticare

- Una nota mostrata **è catturabile con uno screenshot**: `SecureField` protegge
  le password, una vista di testo no. La copertura privacy protegge la miniatura
  di sistema, non uno screenshot volontario.
- Vale la pena chiedersi se la funzione debba esistere anche sul desktop. I
  formati resterebbero allineati comunque, ma le due app divergerebbero come
  capacità — e finora la direzione è sempre stata l'opposta.

---

### M10 punto 4 — preflight memoria in decifratura (2026-07-26)

In cifratura il profilo lo sceglie l'utente, e un rifiuto è un invito a
sceglierne un altro. **In decifratura non c'è nulla da scegliere**: i parametri
di Argon2 arrivano dall'header, li ha decisi chi ha cifrato, e non sono
abbassabili — cambiarli cambierebbe la chiave derivata, cioè non aprirebbe il
file, lo renderebbe illeggibile.

Il messaggio lo dice in quei termini, e un test verifica che **non** contenga
la parola "profilo": è il consiglio giusto in cifratura e inutile qui.

La regola aritmetica è la stessa, e ora sta in un punto solo
(`MemoryPreflight`). Se `SecurityProfile` e `MetaInfo` avessero due soglie
proprie, un file cifrato con un profilo *accettato* potrebbe risultare
rifiutato all'apertura sullo stesso telefono: l'app produrrebbe file che poi si
rifiuta di aprire. C'è un test che confronta le due risposte.

#### Il controllo sta nel motore, non nella schermata

La prima versione lo metteva in `DecryptModel`, dove l'header è già letto e il
messaggio può comparire **prima** della password. Ma **Verify e Batch non
leggono l'header prima di partire**: il processo sarebbe rimasto uccidibile da
quelle due strade, con il difetto che si manifesta come "l'app sparisce" e
nessun messaggio.

`CrypteraEngine` fa quindi il preflight per decrypt e verify — un'apertura di
file e nessuna derivazione — e il batch è coperto perché passa di lì. La
schermata Decrypt mantiene in più l'avviso anticipato, che è UX, non sicurezza.

Se l'header non è leggibile il preflight **non decide**: l'errore vero (file
corrotto, troncato, non un `.ecf`) lo produce l'operazione ed è più preciso.

#### Non è un `CrypteraError`

`InsufficientMemory` è un errore Swift: il core non c'entra e non è mai stato
chiamato. Aggiungere un caso all'enum FFI significherebbe toccare il confine
con Rust — e quindi il desktop — per una condizione che esiste solo su iOS.

Serviva però che i tre `catch` generici smettessero di rispondere "qualcosa è
andato storto", che è esattamente ciò che SPEC §11.2 chiede di non fare davanti
a un limite del dispositivo. `ErrorPresenter` ha ora una variante per gli errori
che non vengono dal core.

#### I test si completano fra i due ambienti

In simulatore ne saltano 3 (`os_proc_available_memory()` risponde 0, quindi il
preflight per scelta non blocca), su device 1 (quello che verifica proprio il
comportamento senza stima). Nessuno dei due ambienti li esegue tutti, e insieme
coprono entrambi i rami.

---

### M10 punto 3 — Data Protection e copertura privacy (2026-07-26)

#### La protezione va sulla cartella, non sui file

`TemporaryWorkspace` crea la sua cartella con `.completeUnlessOpen`.

**Non `.complete`**: il contenuto è in chiaro e va protetto a dispositivo
bloccato, ma un'operazione lunga può essere in corso proprio mentre lo schermo
si spegne — con `.complete` la scrittura già aperta fallirebbe a metà.

**E non sui singoli file**, perché l'output lo crea il codice Rust attraverso
`std::fs`, che di iOS non sa nulla e non può chiedere una classe di protezione.
Impostarla dopo, a operazione conclusa, lascerebbe scoperto tutto il tempo in
cui il file in chiaro esiste — che è esattamente la finestra da chiudere. È lo
stesso principio già applicato al registro: *la protezione si applica alla
creazione*.

Il test che conta non è che l'attributo sia sulla cartella, ma che **un file
creato dentro lo erediti** — scritto con `FileManager` e senza specificare
alcuna protezione, cioè come fa Rust. Se non ereditasse, la protezione sarebbe
scritta nel codice e assente dal disco.

**Verificato su device**: cartella `.completeUnlessOpen`, file creato dentro
`.completeUnlessOpen`, registro `.complete`. In simulatore i tre test
**saltano**: il filesystem non riporta affatto la classe di protezione, quindi
lì la verifica non è possibile — un altro caso in cui il device non è un lusso.

#### La copertura si mette in `.inactive`, non in `.background`

La miniatura che iOS conserva per il selettore delle app viene scattata mentre
la scena è **`.inactive`**, cioè *prima* di `.background`. Coprire solo in
background fotograferebbe la schermata scoperta, e non ce ne accorgeremmo mai:
a quel punto l'app è già sparita dallo schermo.

Non protegge un segreto crittografico — protegge i **nomi dei file**. Quella
miniatura resta su disco e finisce nei backup, e una schermata di Cryptera
mostra come si chiama ciò che l'utente sta cifrando, che per chi cifra è già
l'informazione di troppo.

Il glifo è una **cartella, non un lucchetto**: stessa ragione dell'icona: il
lucchetto sposta la percezione verso i gestori di password.

#### Cosa **non** è verificato

Che iOS scatti davvero la miniatura mentre la copertura è su **non è
osservabile da un test**: in quell'istante l'app non è più interrogabile. Il
test unitario verifica la regola (*quando* si copre), quello UI il modo di
fallire che rovinerebbe l'app a chiunque — una copertura che resta incastrata
al ritorno in primo piano — e la resa visiva è stata guardata forzando la
copertura e fotografando la schermata. Manca la prova d'insieme: mandare l'app
in secondo piano e guardare la miniatura nel selettore, a mano.

---

### M10 punto 2 — sospensione e checkpoint puliti (2026-07-26)

`Cryptera/Core/OperationLifetime.swift` tiene l'app sveglia e viva per la
durata di un'operazione. Due problemi con la stessa causa — iOS sospende ciò
che non sta visibilmente lavorando:

- **Lo schermo si spegne durante l'operazione.** Cifrare una cartella grande
  richiede minuti in cui l'utente non tocca nulla: senza `isIdleTimerDisabled`
  il telefono si blocca da solo e sospende l'app a metà lavoro, per
  un'inattività che inattività non è.
- **L'app va in secondo piano.** Senza background task iOS concede pochi
  secondi e poi sospende il processo *dove si trova*, cioè potenzialmente a
  metà di una scrittura.

**Il valore del background task non sono i secondi in più, è l'avviso di
scadenza.** Alla scadenza si **annulla** l'operazione invece di lasciarla
sospendere: la cancellazione ha già un percorso di pulizia che rimuove l'output
parziale (coperto da test dai tempi di M5), mentre una sospensione a metà
scrittura lascerebbe un `.ecf` troncato — un archivio che sembra esserci e non
si apre.

Sta in `CrypteraEngine.run`, il punto da cui passano **tutte** le operazioni.
Più in alto andrebbe scritto tre volte (Cifra, Decifra, Batch), e la copia
dimenticata sarebbe quella che lascia il telefono bloccarsi a metà cifratura.

È un **contatore**, non un booleano: il batch esegue in sequenza, e con un
booleano la fine del primo file spegnerebbe il blocco schermo mentre gli altri
stanno ancora lavorando. Il contatore non scende sotto zero — uno
sbilanciamento lascerebbe un background task mai chiuso, che iOS punisce
terminando l'app, con il sintomo lontano dalla causa.

#### Cosa era già a posto

L'output parziale **non era a rischio**: tutti e tre i flussi scrivono in
`TemporaryWorkspace`, sotto `tmp/cryptera-work/`, che `purgeStale()` rimuove
all'avvio successivo. Il punto 2 non era quindi "i dati sono in pericolo" ma
"l'operazione viene troncata invece che chiusa".

#### Cosa **non** è verificato

La scadenza del background task **non è provocabile in un test**: iOS la
concede quando vuole. Il test la simula chiamando lo stesso percorso che iOS
invocherebbe, quindi verifica la nostra reazione — l'annullamento — non che
iOS ci avvisi davvero. Quello si vede solo mettendo l'app in background durante
un'operazione lunga, a mano.

---

### M9 — dettaglio originale del piano

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
| ~~Jetsam su profilo `Paranoid` (512 MiB)~~ | ~~**Alto**~~ | ✅ **misurato su device (2026-07-26)** — vedi sotto. Il meccanismo regge; resta il caso dei device più piccoli |
| Security scope chiuso troppo presto | Medio — `IO_ERROR` intermittenti, difficili da diagnosticare | Helper unico `withSecurityScope`, mai duplicato |
| Divergenza silenziosa di formato | **Critico** — file illeggibili dal desktop | M7 come gate; nessuna primitiva reimplementata in Swift |
| Progress senza throttling | Medio — UI bloccata su file grandi | Cap ~10 update/s |
| Assenza Apple Developer Program | Medio — blocca test su device e M11 | Decisione D4 in anticipo |

---

## 5. Prossimo passo

M1–M9 sono completate; M7 resta il gate di rilascio.

**Eseguire M10 — hardening.** La tabella della milestone è il piano; due voci
arrivano da M9 e vanno tenute insieme al resto:

- **VoiceOver acceso davvero, su device.** L'audit automatico di M9 copre
  etichette, contrasto, testo tagliato e aree toccabili, ma non dice se
  l'*ordine* di lettura ha senso, né se un'operazione lunga è seguibile senza
  vedere lo schermo. Non è verificabile in simulatore.
- **Preflight memoria in decifratura**, dove i parametri arrivano dall'header e
  non sono negoziabili.

Il resto di M10 — jetsam, Data Protection, background, privacy UI — richiede un
**device reale**: il simulatore non ha i limiti di memoria e nasconde
esattamente il problema del profilo Paranoid. Dipende quindi da **D4**
(Apple Developer Program), che conviene sciogliere prima di iniziare, non a
metà.

---

## Nota finale

Se emerge la tentazione di reimplementare una primitiva crittografica in Swift
per aggirare un problema di build — fermarsi e risolvere il problema di build.
Un'app iOS che produce file che il desktop non sa aprire non è una versione di
Cryptera, è un'app diversa con lo stesso nome.
