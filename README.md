# Cryptera iOS

App iOS nativa in SwiftUI per il formato **ECF1**, con parità funzionale rispetto
a [Cryptera desktop](https://github.com/gh0st032395/Cryptera) nei limiti imposti
dalla sandbox iOS.

Licenza: **MIT OR Apache-2.0** (stessa doppia licenza dell'upstream).

---

## Stato

🚧 **Pre-M1** — repository inizializzato, nessun codice implementato.

La roadmap completa è in [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
La specifica di riferimento è in [`SPEC.md`](SPEC.md).

| Milestone | Stato |
|---|---|
| M1 — Spike cross-compilazione | ⬜ non avviata |
| M2 — XCFramework | ⬜ |
| M3 — Primo end-to-end (`verify`) | ⬜ |
| M4 — Decrypt | ⬜ |
| M5 — Encrypt file | ⬜ |
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

> ⏳ **Non ancora eseguito.** Questa sezione va compilata al completamento di M1,
> prima di scrivere qualunque view SwiftUI.

| Componente | Target `aarch64-apple-ios` | Note |
|---|---|---|
| `crypto_core_rs` | ⬜ da verificare | |
| `xz2` / `liblzma` (LZMA2) | ⬜ da verificare | Blocca `HDR_FLAG_COMPRESS_LZMA` (0x08) in lettura |
| `bzip2` | ⬜ da verificare | Solo archivi TAR in scrittura; degradabile |

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
./scripts/bootstrap.sh          # rustup targets + uniffi-bindgen
./scripts/build-xcframework.sh  # → Frameworks/CrypteraCore.xcframework
```

`Frameworks/*.xcframework` e `Cryptera/Core/Generated/` sono artefatti di build:
**non sono committati**, vanno rigenerati. Vedi SPEC §3.1.

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
