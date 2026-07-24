#!/usr/bin/env bash
#
# Verifica che ogni stringa passata a L.t(...) abbia una traduzione italiana.
#
# Serve perché una chiave mancante **non è un errore**: `L.t` ricade
# sull'inglese, che è la scelta giusta in produzione — meglio una frase in
# inglese che un identificatore grezzo — ma in fase di sviluppo nasconde le
# dimenticanze. Nessun test può accorgersene: la stringa mostrata resta sensata.
#
# Da eseguire in CI insieme alla suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRINGS="$ROOT/Cryptera/Resources/it.lproj/Localizable.strings"

cd "$ROOT"

[[ -f "$STRINGS" ]] || { echo "ERRORE: $STRINGS assente" >&2; exit 1; }

# Chiavi usate nel codice: primo argomento di L.t("...").
#
# Le sorgenti si appiattiscono su una riga sola prima di cercare: una chiamata
# con argomenti su più righe — `L.t(\n  "chiave", …)` — è comune quando la
# stringa è lunga, e cercandola riga per riga risulterebbe "non usata" pur
# essendo nel codice.
USED=$(cat $(find Cryptera -name '*.swift') \
  | tr '\n' ' ' \
  | grep -oE 'L\.t\( *"([^"\\]|\\.)*"' \
  | sed -E 's/^L\.t\( *"//; s/"$//' | sort -u)

# Chiavi tradotte: la parte a sinistra dell'uguale.
TRANSLATED=$(grep -E '^"' "$STRINGS" | sed -E 's/^"((\\.|[^"\\])*)".*/\1/' | sort -u)

MISSING=$(comm -23 <(echo "$USED") <(echo "$TRANSLATED") || true)
UNUSED=$(comm -13 <(echo "$USED") <(echo "$TRANSLATED") || true)

FAIL=0

echo "==> Chiavi usate nel codice: $(echo "$USED" | grep -c . || true)"
echo "==> Chiavi tradotte:         $(echo "$TRANSLATED" | grep -c . || true)"

if [[ -n "$MISSING" ]]; then
  echo "   FALLITO: senza traduzione italiana:" >&2
  echo "$MISSING" | sed 's/^/     /' >&2
  FAIL=1
else
  echo "==> Tutte le chiavi sono tradotte"
fi

# Una traduzione che non serve più non rompe nulla, ma è peso morto che col
# tempo rende impossibile capire cosa sia ancora in uso.
if [[ -n "$UNUSED" ]]; then
  echo "==> Traduzioni non più usate nel codice:"
  echo "$UNUSED" | sed 's/^/     /'
fi

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
echo "==> Localizzazione coerente"
