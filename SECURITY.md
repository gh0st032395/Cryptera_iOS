# Sicurezza — Cryptera iOS

Questo documento descrive il modello di sicurezza dell'**app iOS** e, soprattutto,
i punti in cui differisce dal desktop. Le primitive crittografiche non sono
descritte qui: sono le stesse del core, e la fonte è
[`SECURITY.md` dell'upstream](https://github.com/gh0st032395/Cryptera/blob/main/SECURITY.md)
insieme a [`FORMAT_SPEC.md`](FORMAT_SPEC.md).

---

## Segnalare una vulnerabilità

Usare la **segnalazione privata** di GitHub (Security → Report a vulnerability)
sul repository, non una issue pubblica. Se riguarda il formato o il core
crittografico, va segnalata sul repository
[Cryptera](https://github.com/gh0st032395/Cryptera): questo repository contiene
l'interfaccia iOS, non la crittografia.

---

## Nessuna primitiva è reimplementata in Swift

È la regola architetturale che tiene in piedi tutto il resto. Il core
`crypto_core_rs` è consumato come dipendenza git con **tag pinnato**, e Swift si
occupa solo di interfaccia, accesso ai file e presentazione degli errori.

Anche l'orchestrazione — costruzione del TAR, suffissi, sanificazione dei nomi,
parametri dei profili — vive in Rust (`rust/cryptera-ffi`), perché determina il
**contenuto** del file prodotto. Una differenza lì produrrebbe file che il
desktop apre in modo diverso, o non apre affatto.

La compatibilità non è affermata, è **verificata a ogni esecuzione dei test**:
file prodotti dal desktop vengono decifrati dal codice iOS e confrontati byte per
byte (milestone M7, il gate di rilascio).

---

## Cosa l'app non fa

- **Nessuna richiesta di rete.** Nessuna telemetria, nessun crash reporter di
  terze parti, nessun SDK esterno. Un controllo automatico verifica sul `.app`
  prodotto che non siano linkati framework di rete
  (`scripts/check-release-bundle.sh`).
- **Nessun aggiornamento in-app.** L'updater firmato del desktop **non è stato
  portato**, ed è una scelta: su App Store è vietato, e un controllo versione che
  rimandi altrove lo è altrettanto.
- **Nessun recupero password.** Non esiste, né lato app né altrove. Una password
  persa significa dati persi, e l'app lo dice esplicitamente prima della prima
  cifratura.
- **Nessun logging diagnostico.** Non c'è alcuna chiamata a `os_log`, `Logger` o
  `print` nel codice dell'app: non esiste un percorso per cui un nome di file
  finisca nei log di sistema, perché non si scrive nulla nei log.

---

## Limiti noti, dichiarati

### La password in memoria non è azzerabile in modo affidabile

**È il limite più importante di questo porting, e non va nascosto.**

Lato Rust la password è avvolta in `Zeroizing`, quindi viene azzerata quando esce
di scope. Ma prima di arrivare lì attraversa Swift, dove è una `String` — un tipo
a valore, con storage gestito dal runtime, copiabile implicitamente e senza alcun
modo documentato di sovrascriverne la memoria. `SecureField` protegge dalla
cattura schermo, non dalla persistenza in RAM.

In pratica: **copie della password possono restare nella memoria del processo**
finché l'allocatore non le riusa. Non si dichiara quindi una zeroizzazione
end-to-end, perché non esiste.

Cosa la mitiga: la memoria del processo non è leggibile da altre app su iOS senza
un exploit del kernel, e i campi password vengono svuotati a operazione conclusa.
Cosa non la mitiga: un attaccante con esecuzione di codice nel processo, o un
dump di memoria su un device compromesso.

### L'estrazione di una cartella sovrascrive i file già presenti

Allineato all'upstream, e in contrasto con SPEC §6.3, che vieta di sovrascrivere
in silenzio. La regola è pensata per l'output di un singolo file — dove infatti
si restituisce `OUTPUT_EXISTS` — mentre per una cartella servirebbe decidere fra
rifiutare, rinominare o chiedere conferma. È una scelta di prodotto ancora
aperta, non una svista: cambiarla solo su iOS produrrebbe una divergenza
silenziosa dal desktop.

### Il profilo Paranoid può far terminare l'app

Argon2 con profilo `Paranoid` richiede 512 MiB. Su iOS il superamento del limite
jetsam **non è un'eccezione catturabile**: il sistema termina il processo. L'app
verifica la memoria disponibile prima di avviare e rifiuta esplicitamente invece
di provarci.

**I parametri non vengono mai abbassati in silenzio.** Cambiare `argon2_mem`
cambia la chiave derivata: un downgrade silenzioso produrrebbe un file che
l'utente crede protetto da un profilo e che invece lo è da un altro. Meglio un
errore. In decifratura i parametri arrivano dall'header e non sono negoziabili.

---

## Protezione dei dati su iOS

**L'hardening (M10) è completo e verificato su device.** Questa sezione elenca
ciò che è implementato; sotto, ciò che resta fuori e perché — perché un
documento di sicurezza che descrive le intenzioni come se fossero fatti è
peggio dell'assenza del documento.

Implementato:

| Ambito | Trattamento |
|---|---|
| Registro operazioni | `.completeFileProtection` |
| Output decifrati di sessioni interrotte | Cancellati all'avvio successivo |
| Memoria prima di avviare | Verificata con `os_proc_available_memory()`; il profilo viene rifiutato se non ci sta, mai abbassato in silenzio. Misurata su device: il modello predice il consumo reale al MiB |
| Operazione interrotta da una sospensione | L'app chiede a iOS tempo aggiuntivo; alla scadenza **annulla** invece di lasciarsi sospendere a metà scrittura, così l'output parziale viene rimosso e non resta un `.ecf` troncato |
| File di lavoro e temporanei | `.completeUnlessOpen` sulla cartella, ereditata dai file che vi crea il core. Non `.complete`: un'operazione in corso mentre lo schermo si spegne fallirebbe a metà |
| Miniatura di sistema in secondo piano | Coperta da una schermata neutra a partire da `.inactive`, cioè prima che iOS la scatti: non vi compaiono nomi di file |
| Memoria in **decifratura** | Verificata sui parametri dell'header prima di derivare la chiave, per decrypt, verify e batch. Il rifiuto spiega che la quantità l'ha decisa chi ha cifrato e non è abbassabile: chi apre non ha scelto nulla |
| Manifesto di privacy | `PrivacyInfo.xcprivacy`: nessun dato raccolto, nessun tracciamento. Le API a motivazione obbligatoria dichiarate sono quelle **realmente usate** — UserDefaults, spazio disco, metadati dei file — ricavate cercandole nel codice. `check-release-bundle.sh` verifica che il manifesto sia nel bundle e continui a dichiarare zero raccolta |

**Fuori perimetro finché l'app non si pubblica** (M11 — vedi
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)):

| Ambito | Stato |
|---|---|
| `ITSAppUsesNonExemptEncryption` | **Non dichiarata, e per ora non richiesta.** È export compliance: serve alla prima submission. Finché non si pubblica, nell'`Info.plist` resta un commento — una chiave sbagliata lì è peggio di una assente |

Non è una lacuna di sicurezza: è una dichiarazione amministrativa che ha senso
solo davanti a una distribuzione.

La suite completa gira su un **iPhone 14 Pro (iOS 26.5.2)** ed è verde, e le
classi di Data Protection sono verificate lì — in simulatore quei test saltano,
perché il filesystem non riporta affatto la classe.

Le due verifiche non automatizzabili sono state **eseguite a mano** sullo stesso
device e riferite come superate: VoiceOver acceso sulle cinque schermate
(ordine di lettura, progresso udibile, errori annunciati) e app in secondo piano
durante un'operazione lunga (la miniatura di sistema mostra la copertura, senza
nomi di file). Sono annotate come prove eseguite una volta, non come garanzie
che un test ripete a ogni esecuzione.

Il codice errore `DEVICE_LOCKED` esiste ed è registrato nel log delle
operazioni, ma non ha ancora un trattamento dedicato nell'interfaccia.

---

## Interfaccia e privacy

- `SecureField` per le password; mostrare in chiaro è sempre una scelta
  esplicita dell'utente, mai lo stato iniziale. `SecureField` impedisce anche la
  cattura del contenuto negli screenshot di sistema.
- **Il campo `message` grezzo di un errore non viene mai mostrato**: è
  diagnostico e può contenere percorsi. L'utente vede la stringa localizzata
  mappata dal `code`.
- Il registro delle operazioni memorizza **solo il nome** del file, mai il suo
  percorso, e solo codici di errore stabili — mai il messaggio diagnostico.
- Resta sul dispositivo: non viene mai trasmesso, perché l'app non ha rete.

---

## Input non fidati

Il nome originale memorizzato nell'header è **scelto da chi ha creato il file** e
il core non lo sanifica oltre UTF-8 e lunghezza. Non diventa mai un percorso
senza passare da `safe_output_name`, che ne tiene solo l'ultimo componente:
`URL.appendingPathComponent` non neutralizza né le risalite né i percorsi
assoluti.

L'estrazione dei TAR rifiuta le entry con `..`, i percorsi assoluti e i link
(simbolici o hard) che puntano fuori dalla cartella di destinazione — compreso il
caso in cui il *nome* dell'entry è pulito ma il link porta altrove.

La compressione dell'archivio si deduce dai **magic bytes**, mai dal nome: il
nome può mancare del tutto (`hide_filename`), e dedurla da lì produceva file che
l'app non sapeva riaprire.

---

## Verifiche automatiche

| Controllo | Dove |
|---|---|
| Round-trip incrociato col desktop, byte per byte | `CrypteraTests/CrossCompatTests` |
| Compatibilità coi formati v1–v5 | `CrypteraTests/FormatCompatTests` |
| Recupero FEC e confine oltre il quale fallisce | `CrypteraTests/FecRecoveryTests` |
| Manomissione dell'header | `CrypteraTests/DecryptFlowTests` |
| Nessun framework di rete, nessuna fixture in Release | `scripts/check-release-bundle.sh` |
| Contrasto dei colori (WCAG 2.1) | `CrypteraTests/DesignSystemContrastTests` |

Girano tutte in CI a ogni push (`.github/workflows/ios.yml`).
