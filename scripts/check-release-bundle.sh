#!/usr/bin/env bash
#
# Verifica che una build Release non contenga dati di test né bundle di test.
#
# Serve perché il controllo non è esprimibile come XCTest: `@testable import`
# richiede ENABLE_TESTABILITY, disattivata in Release — e attivarla lì sarebbe
# sbagliato. L'unico modo onesto è ispezionare il .app prodotto.
#
# Da eseguire in CI prima di ogni distribuzione.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT/build/release-check}"

cd "$ROOT"

if [[ ! -d Cryptera.xcodeproj ]]; then
  echo "==> Genero il progetto"
  xcodegen generate >/dev/null
fi

echo "==> Build Release"
xcodebuild build \
  -project Cryptera.xcodeproj \
  -scheme Cryptera \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$BUILD_DIR" \
  >/dev/null

APP="$BUILD_DIR/Build/Products/Release-iphonesimulator/Cryptera.app"
[[ -d "$APP" ]] || { echo "ERRORE: $APP non prodotto" >&2; exit 1; }

FAIL=0

echo "==> Nessuna fixture di test"
if FOUND=$(find "$APP" -name '*.ecf' -print -quit 2>/dev/null) && [[ -n "$FOUND" ]]; then
  echo "   FALLITO: dati di test nel bundle:" >&2
  find "$APP" -name '*.ecf' | sed 's/^/     /' >&2
  FAIL=1
else
  echo "   ok"
fi

echo "==> Nessun bundle di test"
if [[ -d "$APP/PlugIns" ]] && find "$APP/PlugIns" -name '*.xctest' -print -quit | grep -q .; then
  echo "   FALLITO: bundle di test in PlugIns/" >&2
  FAIL=1
else
  echo "   ok"
fi

# L'app non deve fare rete (SPEC §12.4). Un SDK aggiunto per distrazione si
# nota qui: il core Rust e SwiftUI non linkano né CFNetwork né Network.
echo "==> Nessun framework di rete linkato"
if LINKED=$(otool -L "$APP/Cryptera" 2>/dev/null | grep -E 'CFNetwork|/Network\.framework'); then
  echo "   FALLITO: framework di rete linkati:" >&2
  echo "$LINKED" | sed 's/^/     /' >&2
  FAIL=1
else
  echo "   ok"
fi

# Il manifesto di privacy deve **essere nel bundle e dichiarare zero raccolta**.
#
# È un file che si aggiunge una volta e non si guarda più: se un giorno
# smettesse di essere incluso — rinominato, spostato, escluso da una regola di
# build — non lo scoprirebbe nessuno fino al rifiuto in fase di submission, cioè
# nel momento peggiore.
echo "==> Manifesto di privacy presente e coerente"
MANIFEST="$APP/PrivacyInfo.xcprivacy"
if [[ ! -f "$MANIFEST" ]]; then
  echo "   FALLITO: PrivacyInfo.xcprivacy assente dal bundle" >&2
  FAIL=1
elif ! plutil -lint "$MANIFEST" >/dev/null 2>&1; then
  echo "   FALLITO: PrivacyInfo.xcprivacy non è un plist valido" >&2
  FAIL=1
else
  # `NSPrivacyCollectedDataTypes` vuoto è l'affermazione centrale dell'app: se
  # un giorno comparisse una voce, deve essere una decisione, non una svista.
  RACCOLTI=$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$MANIFEST" 2>/dev/null || echo "?")
  TRACKING=$(plutil -extract NSPrivacyTracking raw -o - "$MANIFEST" 2>/dev/null || echo "?")
  if [[ "$RACCOLTI" != "0" || "$TRACKING" != "false" ]]; then
    echo "   FALLITO: il manifesto dichiara raccolta dati o tracciamento" >&2
    echo "     tipi di dato raccolti: $RACCOLTI · tracking: $TRACKING" >&2
    FAIL=1
  else
    echo "   ok"
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  echo "==> Controlli falliti" >&2
  exit 1
fi
echo "==> Bundle Release pulito"
