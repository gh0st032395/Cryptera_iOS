#!/usr/bin/env bash
#
# Prepara la toolchain per buildare Cryptera iOS.
# Idempotente: rieseguirlo su una macchina già pronta non fa nulla.
set -euo pipefail

echo "==> Target Rust per iOS"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

echo "==> Verifica Xcode"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERRORE: Xcode non configurato. Esegui: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

# Xcode 26 non installa l'SDK iOS di default: le piattaforme si scaricano a
# parte. Senza questo controllo il primo errore utile arriva molto più tardi,
# dentro cargo, in una forma poco leggibile.
if ! xcodebuild -showsdks 2>/dev/null | grep -q 'iphoneos'; then
  echo "ERRORE: SDK iOS assente. Aprilo in Xcode > Settings > Components," >&2
  echo "        oppure: xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi

echo "==> Verifica XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERRORE: xcodegen assente. Installa con: brew install xcodegen" >&2
  exit 1
fi

echo "==> Toolchain pronta"
xcodebuild -version | head -1
cargo --version
xcodegen --version
