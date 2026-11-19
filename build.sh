#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Kodros Orb.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -whole-module-optimization \
  -target arm64-apple-macosx14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/PiOrb"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so macOS keeps the Screen Recording, Microphone and
# Speech Recognition grants across rebuilds. Ad-hoc signing drops them every time.
# Override the name with SIGN_IDENTITY.
SIGN_IDENTITY="${SIGN_IDENTITY:-MeshVault Local Code Signing}"
# Optional: keep the identity in a dedicated keychain. A host without GUI access cannot
# mark a self-signed certificate trusted, so the identity never reads as "valid". It
# still signs. Set SIGN_KEYCHAIN to that keychain file and SIGN_KEYCHAIN_PASSWORD_FILE
# to a file holding its password; the script unlocks it and then matches without -v.
SIGN_ARG="$SIGN_IDENTITY"
if [ -n "${SIGN_KEYCHAIN:-}" ] && [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]; then
  security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
  # Sign by SHA-1, not by name: an identity of the same name may also sit in the
  # login keychain, and codesign then fails "ambiguous" rather than picking one.
  SIGN_ARG=$(security find-identity -p codesigning "$SIGN_KEYCHAIN" \
    | awk -v n="$SIGN_IDENTITY" '$0 ~ n {print $2; exit}')
fi
if ! security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "error: signing identity '$SIGN_IDENTITY' not in keychain" >&2
  echo "ad-hoc signing breaks macOS privacy grants on every rebuild; refusing to build" >&2
  exit 1
fi
codesign --force --sign "$SIGN_ARG" --identifier ai.meshvault.piorb "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
