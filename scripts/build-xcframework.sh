#!/usr/bin/env bash
#
# Costruisce Frameworks/CrypteraCore.xcframework dal crate cryptera-ffi e
# genera i binding Swift in Cryptera/Core/Generated/.
#
# Entrambi gli output sono artefatti di build e NON sono committati
# (SPEC §3.1): questo script è l'unico modo di ottenerli.
#
# Idempotente e rumoroso in caso di errore.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT/rust"
BUILD_DIR="$RUST_DIR/target"
GENERATED_DIR="$ROOT/Cryptera/Core/Generated"
FRAMEWORKS_DIR="$ROOT/Frameworks"
XCFRAMEWORK="$FRAMEWORKS_DIR/CrypteraCore.xcframework"

LIB_NAME="libcryptera_ffi.a"
MODULE_NAME="cryptera_ffi"

# Senza questa variabile il minos eredita la versione dell'SDK (es. 26.5), il
# build riesce comunque e il framework risulta installabile solo su device
# aggiornatissimi. È un errore silenzioso: viene riverificato in fondo.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

echo "==> Deployment target: iOS $IPHONEOS_DEPLOYMENT_TARGET"

# ─── 1-2. Build release per device e simulatore ────────────────────
cd "$RUST_DIR"
for TARGET in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  echo "==> cargo build --release --target $TARGET"
  cargo build --release --target "$TARGET"
done

# ─── 3. Fat lib per il simulatore (arm64 + x86_64) ─────────────────
SIM_DIR="$BUILD_DIR/sim-universal/release"
mkdir -p "$SIM_DIR"
echo "==> lipo: fat lib simulatore"
lipo -create \
  "$BUILD_DIR/aarch64-apple-ios-sim/release/$LIB_NAME" \
  "$BUILD_DIR/x86_64-apple-ios/release/$LIB_NAME" \
  -output "$SIM_DIR/$LIB_NAME"

# ─── 4. Binding Swift ──────────────────────────────────────────────
# In modalità --library il generatore legge i metadati dalla libreria già
# compilata, quindi non serve alcun file .udl.
BINDINGS_TMP="$BUILD_DIR/uniffi-bindings"
rm -rf "$BINDINGS_TMP"
mkdir -p "$BINDINGS_TMP"

echo "==> uniffi-bindgen generate"
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME" \
  --language swift \
  --out-dir "$BINDINGS_TMP"

# ─── 5. Riorganizzazione degli output ──────────────────────────────
# xcodebuild vuole gli header in una cartella con un module.modulemap; uniffi
# genera invece <module>FFI.modulemap, che va rinominato.
HEADERS_DIR="$BUILD_DIR/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$BINDINGS_TMP/${MODULE_NAME}FFI.h" "$HEADERS_DIR/"
cp "$BINDINGS_TMP/${MODULE_NAME}FFI.modulemap" "$HEADERS_DIR/module.modulemap"

mkdir -p "$GENERATED_DIR"
cp "$BINDINGS_TMP/${MODULE_NAME}.swift" "$GENERATED_DIR/"
echo "==> Binding Swift in Cryptera/Core/Generated/${MODULE_NAME}.swift"

# ─── 6. XCFramework ────────────────────────────────────────────────
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$XCFRAMEWORK"   # -create-xcframework rifiuta di sovrascrivere
echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME" -headers "$HEADERS_DIR" \
  -library "$SIM_DIR/$LIB_NAME" -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK" >/dev/null

# ─── 7. Verifica del deployment target ─────────────────────────────
# Il punto 6 riesce anche con un minos sbagliato, quindi va controllato qui.
ACTUAL_MINOS="$(otool -l "$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME" 2>/dev/null \
  | grep -A3 LC_BUILD_VERSION | grep minos | awk '{print $2}' | sort -u | head -1)"
if [[ "$ACTUAL_MINOS" != "$IPHONEOS_DEPLOYMENT_TARGET" ]]; then
  echo "ERRORE: minos atteso $IPHONEOS_DEPLOYMENT_TARGET, trovato ${ACTUAL_MINOS:-nessuno}." >&2
  echo "        Il framework sarebbe installabile solo su device molto recenti." >&2
  exit 1
fi

echo "==> OK — $XCFRAMEWORK (minos $ACTUAL_MINOS)"
