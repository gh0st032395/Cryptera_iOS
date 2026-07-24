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
