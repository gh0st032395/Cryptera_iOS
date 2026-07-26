# Cryptera iOS

[![iOS CI](https://github.com/gh0st032395/Cryptera_iOS/actions/workflows/ios.yml/badge.svg)](https://github.com/gh0st032395/Cryptera_iOS/actions/workflows/ios.yml)

App iOS nativa in SwiftUI per il formato **ECF1**: cifratura locale di file e
cartelle con AES-256-GCM, chiave derivata con Argon2id e correzione d'errore
Reed-Solomon.

È il **porting di [Cryptera desktop](https://github.com/gh0st032395/Cryptera)**,
non un'app diversa con lo stesso nome: un file cifrato sull'iPhone si apre sul
desktop e viceversa, byte per byte. Nessuna primitiva crittografica è
reimplementata in Swift — il core Rust è consumato come dipendenza con tag
pinnato.

L'app **non fa alcuna richiesta di rete**: nessuna telemetria, nessun account,
nessun servizio. Tutto avviene sul dispositivo.

Licenza: **MIT OR Apache-2.0** (stessa doppia licenza dell'upstream).

---

## Stato

✅ **M1–M10 completate.** L'app è funzionalmente completa e verificata su
device. **Non è pubblicata, e pubblicarla è una decisione ancora da prendere**:
i requisiti dell'App Store sono raccolti in M11 e restano sospesi finché quella
decisione non arriva.

**M7 — il gate di rilascio — è verde.** Otto file prodotti dall'applicazione
desktop vengono letti dal codice iOS con confronto byte per byte a ogni
esecuzione dei test, e un file cifrato dall'iPhone è stato decifrato dal desktop.

Oggi l'app cifra e decifra file e cartelle, anche in coda, con verifica
d'integrità e registro delle operazioni, in inglese e italiano, su iPhone e iPad.

| Milestone | Stato |
|---|---|
| M1 — Spike cross-compilazione | ✅ verde, nessuna limitazione |
| M2 — XCFramework | ✅ app verde su simulatore |
| M3 — Primo end-to-end (`verify`) | ✅ superficie FFI completa |
| M4 — Decrypt | ✅ apertura dall'app File, export al sistema |
| M5 — Encrypt file | ✅ design, impostazioni e localizzazione anticipati da M9 |
| M6 — Encrypt cartella | ✅ con verifica dello spazio |
| M7 — Round-trip incrociato (**gate di rilascio**) | ✅ 8 file del desktop letti byte per byte |
| M8 — Batch + Audit | ✅ coda e registro delle operazioni |
| M9 — Design system | ✅ accessibilità verificata, iPad, icona adattiva |
| M10 — Hardening | ✅ memoria misurata su device, Data Protection, privacy, VoiceOver provato |
| M11 — Distribuzione | ⏸️ **sospesa** — solo se si decide di pubblicare |
| M12 — Nota cifrata | 📋 progettata; una decisione aperta sul modello di minaccia |

**197 test verdi**: 42 Rust, 128 XCTest, 27 UI test — su iPhone 14 Pro e in simulatore.

Roadmap completa in [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md);
specifica di implementazione in [`SPEC.md`](SPEC.md).

---

## Requisito centrale: allineamento col desktop

I file prodotti su iOS devono essere decifrabili dal desktop e viceversa,
**byte-per-byte compatibili**. Nessuna deroga.

Ne discendono due regole che non sono negoziabili:

1. **Nessuna primitiva crittografica reimplementata in Swift.** Il core
   `crypto_core_rs` è una dipendenza git con tag pinnato.
2. **Anche l'orchestrazione sta in Rust** — costruzione del TAR, suffissi,
   sanificazione dei nomi, parametri dei profili. Determina il *contenuto* del
   file, quindi non può vivere in Swift, dove divergerebbe in silenzio.

Se compilare per iOS diventasse difficile, la risposta è risolvere il problema di
build, non aggirarlo riscrivendo qualcosa in Swift.

### Verificare l'allineamento quando il desktop si aggiorna

Il numero di versione del desktop **non dice se il formato è cambiato**: le
release 2.1.x, per esempio, hanno toccato solo CLI, `ops/`, backend Tauri e
frontend. Il controllo da fare è sul core:

```bash
git -C ../Cryptera diff v2.0.4..v2.1.1 -- src/
```

Se il diff è vuoto, il formato è identico e il pin resta valido. Se non lo è,
serve aggiornare il tag e rieseguire M7 prima di ogni altra cosa.

---

## Pin dell'upstream

| Voce | Valore |
|---|---|
| Repo core | `https://github.com/gh0st032395/Cryptera` |
| Tag pinnato | `v2.0.4` |
| Formato | ECF1 header **v5** |

**Perché `v2.0.4` e non l'ultima release.** `src/lib.rs` del core è identico
byte per byte fra `v2.0.3`, `v2.0.4` e `v2.1.1`: le release successive contengono
solo lavoro su CLI, crate `ops/`, backend Tauri e interfaccia. Si pinna quindi
`v2.0.4` — zero rischio di divergenza di formato — e si porta l'orchestrazione
dalla sua `src-tauri/src/main.rs`, che include il pre-conteggio delle entry per
il progress di archiviazione (assente in 2.0.3).

Le correzioni del desktop che riguardano l'orchestrazione vengono **portate a
mano** quando servono, non ereditate: il crate `ops/` condiviso introdotto in
2.1.0 non è stato adottato perché la versione iOS diverge deliberatamente (errori
`CrypteraError`, nessuna dipendenza dal filesystem del desktop).

---

## Compatibilità di formato

| Versione header | Lettura | Scrittura |
|---|---|---|
| v1 – v4 | ✅ | — |
| v5 (nome file cifrato) | ✅ | ✅ |

Tutte le varianti di compressione del formato sono supportate in lettura e
scrittura, payload e archivio: ZLIB, LZMA2, gzip, bzip2, xz.

---

## Build

Toolchain richiesta: Xcode con SDK iOS, Rust, e `brew install xcodegen`.

```bash
./scripts/bootstrap.sh          # verifica toolchain + target rustup
./scripts/build-xcframework.sh  # → Frameworks/CrypteraCore.xcframework
xcodegen generate               # → Cryptera.xcodeproj
open Cryptera.xcodeproj
```

Da riga di comando:

```bash
xcodebuild test -project Cryptera.xcodeproj -scheme Cryptera \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

**Tre cose sono artefatti di build e non sono committate** (SPEC §3.1) — vanno
rigenerate con i comandi qui sopra:

| Artefatto | Generato da |
|---|---|
| `Frameworks/CrypteraCore.xcframework` | `build-xcframework.sh` |
| `Cryptera/Core/Generated/cryptera_ffi.swift` | `build-xcframework.sh` (uniffi-bindgen) |
| `Cryptera.xcodeproj` | `xcodegen generate` |

La fonte di verità del progetto Xcode è [`project.yml`](project.yml): il
`.pbxproj` produce conflitti di merge illeggibili, quindi non entra nel repo.
Aggiungendo un file al progetto va rieseguito `xcodegen generate`.

### Controlli automatici

Girano in CI a ogni push, e si possono eseguire a mano:

```bash
./scripts/check-localization.sh     # ogni chiave usata ha una traduzione
./scripts/check-release-bundle.sh   # cosa finisce davvero in una build Release
```

`check-localization.sh` serve perché una chiave senza traduzione **non fallisce
da sola**: ricade sull'inglese, che in produzione è il comportamento corretto ma
nasconde le dimenticanze.

`check-release-bundle.sh` verifica sul `.app` prodotto che non contenga dati di
test, bundle di test né framework di rete (SPEC §12.4). Non è un XCTest perché la
suite non compila in Release: `@testable import` richiede `ENABLE_TESTABILITY`,
che in una build distribuibile va lasciata spenta.

> Le fixture dell'upstream sono nel bundle dell'app **solo in Debug**, dove
> servono a pilotare i UI test: l'input arriva da `.fileImporter`, che è UI di
> sistema e fuori processo. I UI test iniettano una fixture con l'argomento di
> lancio `-apri-fixture`, che percorre lo stesso codice di `.onOpenURL`.

### Icona

L'icona è **disegnata da codice**, non è un binario opaco committato:

```bash
swift scripts/make-app-icon.swift Cryptera/Resources/Assets.xcassets/AppIcon.appiconset
```

Genera le tre apparenze di iOS 18 (standard, scura, colorata) a 1024×1024, senza
canale alfa e senza angoli arrotondati disegnati — la maschera la applica il
sistema, e disegnarla la applicherebbe due volte.

---

## Accessibilità

Dynamic Type e VoiceOver sono requisiti, non rifiniture, e sono verificati da
`CrypteraUITests/AccessibilityUITests` con `performAccessibilityAudit()` su tutte
le schermate — in inglese a corpo normale, in inglese ad AX5 e **in italiano ad
AX5**, perché le stringhe più lunghe si tagliano prima.

Il contrasto dei colori è misurato alla sorgente con la formula WCAG 2.1
(`CrypteraTests/DesignSystemContrastTests`), in entrambi i temi. È il motivo per
cui il verde dell'accento su fondo chiaro **è più scuro di quello del desktop**:
il valore dell'upstream faceva 2,9:1 come testo, sotto la soglia AA.

La prova con **VoiceOver realmente acceso** è stata eseguita su iPhone 14 Pro:
l'audit automatico copre etichette, contrasto e geometria, non l'ordine di
lettura, e quello si controlla solo ascoltando.

---

## Privacy ed export compliance

- Nessuna richiesta di rete, nessuna telemetria, nessun SDK di terze parti.
  Verificato automaticamente sul binario prodotto.
- Nessun aggiornamento in-app: vietato su App Store, e l'updater firmato del
  desktop non è stato portato.
- `PrivacyInfo.xcprivacy`: presente, dichiara nessun dato raccolto e nessun
  tracciamento. `check-release-bundle.sh` verifica che resti nel bundle.
- `ITSAppUsesNonExemptEncryption`: **non dichiarata, e per ora non serve.** È
  export compliance, richiesta alla prima submission: finché l'app non si
  pubblica, nell'`Info.plist` resta un commento — una chiave sbagliata lì è
  peggio di una assente. Le opzioni e la strada che si adatta al caso (sorgente
  pubblico) sono in [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md), M11.

Limiti noti e modello di sicurezza in [`SECURITY.md`](SECURITY.md), incluso il
punto in cui questo porting è più debole del desktop: la password in memoria non
è azzerabile in modo affidabile, perché in Swift è una `String`.

---

## Segnalare una vulnerabilità

Usare la **segnalazione privata** di GitHub (Security → Report a vulnerability),
non una issue pubblica. Se riguarda il formato o il core crittografico, va
aperta sul repository [Cryptera](https://github.com/gh0st032395/Cryptera):
qui c'è l'interfaccia iOS, non la crittografia.

---

## Documenti

| File | Contenuto |
|---|---|
| [`SPEC.md`](SPEC.md) | Specifica di implementazione del porting |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | Piano operativo per milestone, con il registro delle decisioni |
| [`FORMAT_SPEC.md`](FORMAT_SPEC.md) | Specifica normativa del formato ECF1 (da upstream) |
| [`SECURITY.md`](SECURITY.md) | Modello di sicurezza e limiti noti |
