# Cryptera iOS

App iOS nativa in SwiftUI per il formato **ECF1**, con parità funzionale rispetto
a [Cryptera desktop](https://github.com/gh0st032395/Cryptera) nei limiti imposti
dalla sandbox iOS.

Licenza: **MIT OR Apache-2.0** (stessa doppia licenza dell'upstream).

---

## Stato

🚧 **M5 completata** — l'app cifra e decifra file singoli, con un'interfaccia
propria. La cifratura di cartelle arriva in M6.

La roadmap completa è in [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
La specifica di riferimento è in [`SPEC.md`](SPEC.md).

| Milestone | Stato |
|---|---|
| M1 — Spike cross-compilazione | ✅ **verde, senza limitazioni** |
| M2 — XCFramework | ✅ **app verde su simulatore** |
| M3 — Primo end-to-end (`verify`) | ✅ **48 test verdi, revisionata** |
| M4 — Decrypt | ✅ **79 test verdi, verificata sul simulatore** |
| M5 — Encrypt file | ✅ **103 test verdi, con design system anticipato da M9** |
| M6 — Encrypt cartella | ⬜ |
| M7 — Round-trip incrociato (**gate di rilascio**) | ⬜ |
| M8 — Batch + Audit | ⬜ |
| M9 — Design system | ⬜ |
| M10 — Hardening | ⬜ |
| M11 — Distribuzione TestFlight | ⬜ |

---

## Requisito centrale

I file prodotti su iOS devono essere decifrabili dal desktop e viceversa,
**byte-per-byte compatibili**. Nessuna deroga. Nessuna primitiva crittografica
viene reimplementata in Swift: il core Rust `crypto_core_rs` è consumato come
dipendenza git con tag pinnato.

---

## Esito dello spike di cross-compilazione (SPEC §4.1)

> ✅ **M1 chiusa — esito completamente positivo. Nessuna limitazione funzionale.**
> Verificato il 2026-07-22 con Xcode 26.6 (SDK iOS 26.5), cargo 1.96.0,
> `crypto_core_rs` a `v2.0.4`.

| Componente | `aarch64-apple-ios` | Simulatore | Note |
|---|---|---|---|
| `crypto_core_rs` | ✅ | ✅ arm64 + x86_64 | Compila pulito, nessun flag speciale |
| `xz2` / `liblzma` (LZMA2) | ✅ | ✅ | **73 file oggetto liblzma, 719 simboli `lzma_*`** — realmente compilato, non stubbato |
| `bzip2` / `bzip2-sys` | ✅ | ✅ | 35 simboli `BZ2_*` |
| `tar`, `flate2`, `walkdir`, `tempfile` | ✅ | ✅ | |

**Nessun intervento richiesto.** Non sono serviti né `CC`/`AR` espliciti verso
l'SDK iOS né il fallback a `lzma-rs`: il crate `cc` risolve i target iOS da solo.
Le tre voci ⚠️ della matrice di parità (SPEC §9 — LZMA2, archivi gz/xz, archivi
bz2) **diventano ✅**: l'app iOS può leggere e scrivere ogni variante di
compressione del formato.

Artefatto verificato con `otool`: `platform 2` (iOS), architettura arm64.

**Nota sul deployment target.** Senza variabile d'ambiente il `minos` eredita la
versione dell'SDK (26.5), che escluderebbe ogni device non aggiornatissimo.
`IPHONEOS_DEPLOYMENT_TARGET=17.0` produce correttamente `minos 17.0` e va
impostato in `scripts/build-xcframework.sh` per **tutti** i target.

---

## Pin dell'upstream

| Voce | Valore |
|---|---|
| Repo core | `https://github.com/gh0st032395/Cryptera` |
| Tag pinnato | `v2.0.4` |
| Formato | ECF1 header **v5** |

**Nota sul tag.** `SPEC.md` indica `v2.0.3`. Il file `src/lib.rs` del core è
**identico byte-per-byte fra v2.0.3 e v2.0.4** (SHA-256
`ed4bcbc60d2d5666922b1b2fc44a44fa58bd936983c0ca1c3c67ca70f6cd93d3`): le release
2.0.4 contengono solo correzioni a frontend e livello Tauri. Si pinna quindi
`v2.0.4` — zero rischio di divergenza di formato — e si porta l'orchestrazione
dalla sua `src-tauri/src/main.rs`, che include il pre-conteggio delle entry per
il progress di archiviazione (assente in 2.0.3).

---

## Build

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

./scripts/check-release-bundle.sh   # cosa finisce davvero in una build Release
```

`check-release-bundle.sh` verifica sul `.app` prodotto che non contenga dati di
test, bundle di test, né framework di rete (SPEC §12.4). Non è un XCTest perché
la suite non compila in Release: `@testable import` richiede
`ENABLE_TESTABILITY`, che in una build distribuibile va lasciata spenta.

> Le fixture dell'upstream sono nel bundle dell'app **solo in Debug**, dove
> servono a pilotare i UI test: l'input arriva da `.fileImporter`, che è UI di
> sistema e fuori processo. I UI test iniettano quindi una fixture con
> l'argomento di lancio `-apri-fixture`, che percorre lo stesso codice di
> `.onOpenURL`. In Release le fixture sono escluse e quel codice non viene
> nemmeno compilato.

**Tre cose sono artefatti di build e non sono committate** (SPEC §3.1) —
vanno rigenerate con i comandi qui sopra:

| Artefatto | Generato da |
|---|---|
| `Frameworks/CrypteraCore.xcframework` | `build-xcframework.sh` |
| `Cryptera/Core/Generated/cryptera_ffi.swift` | `build-xcframework.sh` (uniffi-bindgen) |
| `Cryptera.xcodeproj` | `xcodegen generate` da `project.yml` |

La fonte di verità del progetto Xcode è [`project.yml`](project.yml): il
`.pbxproj` produce conflitti di merge illeggibili, quindi non entra nel repo.
Aggiungendo un file al progetto va rieseguito `xcodegen generate`.

Toolchain richiesta: Xcode con SDK iOS, Rust, e `brew install xcodegen`.

---

## Privacy ed export compliance

- L'app **non effettua alcuna richiesta di rete**. Nessuna telemetria, nessun
  crash reporter di terze parti, nessun SDK esterno.
- `PrivacyInfo.xcprivacy`: nessun dato raccolto.
- `ITSAppUsesNonExemptEncryption`: posizione da verificare e documentare qui
  **prima** della prima submission (SPEC §14.1).

---

## Documenti

| File | Contenuto |
|---|---|
| [`SPEC.md`](SPEC.md) | Specifica di implementazione |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | Piano operativo per milestone |
| [`FORMAT_SPEC.md`](FORMAT_SPEC.md) | Specifica normativa del formato ECF1 (da upstream) |
