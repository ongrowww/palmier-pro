#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/PalmierPro.app"
DMG="$ROOT/.build/PalmierPro-BYOK-Preview.dmg"
STAGING="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

"$ROOT/scripts/bundle.sh" debug --byok-preview

rm -f "$DMG"
cp -R "$APP" "$STAGING/Palmier Pro BYOK Preview.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "Palmier Pro BYOK Preview" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

echo "==> Done: $DMG"
