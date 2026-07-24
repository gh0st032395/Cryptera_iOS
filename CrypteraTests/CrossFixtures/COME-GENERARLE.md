# Fixture prodotte dal desktop — istruzioni

Questi file servono a M7 punto 3, la direzione **desktop → iOS**: dimostrano che
l'app iOS legge davvero i file scritti dall'applicazione desktop.

Vanno generati **a mano, una volta sola**, e poi committati. Da lì in avanti ogni
esecuzione dei test li ridecifra automaticamente e confronta i byte.

## Perché a mano

L'applicazione desktop è un'app Tauri **senza interfaccia a riga di comando**:
`src-tauri/tauri.conf.json` non dichiara il plugin `cli`, e il core
`crypto_core_rs` è una libreria senza `[[bin]]`. Non c'è quindi alcun modo di
pilotarla da uno script.

È lo stesso motivo per cui l'upstream committa `tests/fixtures/v4-*.ecf` invece
di rigenerarle: un artefatto prodotto una volta e conservato vale più di una
procedura che nessuno può ripetere automaticamente.

## Cosa serve

- **Cryptera desktop 2.0.4** (`/Applications/Cryptera.app`)
- I file in `sorgenti/`, che hanno contenuto deterministico: i test asseriscono
  i byte esatti, quindi **non vanno modificati**
- Password: `CrossTestP@ssw0rd42` per tutti i file
- Keyfile: `sorgenti/chiave.key`, solo per il file che lo richiede

## I file da produrre

Salvali in questa cartella, con esattamente questi nomi. Le etichette fra
parentesi sono quelle dell'interfaccia italiana del desktop.

| # | Sorgente | Profilo di Sicurezza | Livello Ridondanza | Pre-compressione | Altro | Nome di uscita |
|---|---|---|---|---|---|---|
| 1 | `nota.txt` | Standard | Bilanciato | Nessuna | — | `desktop-standard.ecf` |
| 2 | `nota.txt` | Alta | Basso Overhead | Deflate (Docs) | — | `desktop-alta-zlib.ecf` |
| 3 | `dati.bin` | Massima | Resilienza Max | LZMA2 (Best) | — | `desktop-massima-lzma.ecf` |
| 4 | `nota.txt` | Standard | Bilanciato | Nessuna | **nascondi nome file** | `desktop-nome-nascosto.ecf` |
| 5 | `nota.txt` | Standard | Bilanciato | Nessuna | **keyfile** `chiave.key` | `desktop-keyfile.ecf` |
| 6 | `documenti/` | Standard | Bilanciato | — | Compressione Archivio: **Gzip (Veloce)** | `desktop-cartella-gz.ecf` |
| 7 | `documenti/` | Standard | Bilanciato | — | Compressione Archivio: **XZ (Best)** | `desktop-cartella-xz.ecf` |
| 8 | `documenti/` | Standard | Bilanciato | — | Compressione Archivio: **Bzip2 (Ratio)** | `desktop-cartella-bz2.ecf` |

Lascia attivi i valori predefiniti che non sono elencati (record di controllo
password acceso, salta file speciali acceso).

## Cosa copre questa matrice

Ogni riga esiste perché copre qualcosa che le altre non coprono:

- **1-3**: tutti e tre i profili Argon2, quindi tutti i parametri di derivazione
  che finiscono nell'header; e i due estremi di `k`/`r`
- **2-3**: le due compressioni del payload, Zlib e LZMA2 — quest'ultima è quella
  che dipende da `liblzma`, il rischio più alto rientrato in M1
- **4**: nome cifrato nell'header (v5)
- **5**: derivazione con keyfile
- **6-8**: le tre compressioni d'archivio, cioè i tre decoder TAR

Il numero 3 con Resilienza Max produce un file di circa 260 KB da 64 KB di
sorgente: è voluto, ed è anche la verifica che l'overhead del 300% sia quello
atteso.

## Dopo

Consegnali e basta. Il resto è automatico: i test in
`CrypteraTests/CrossCompatTests.swift` li leggeranno tutti, decifreranno, e
confronteranno il contenuto byte per byte con i file in `sorgenti/`.
