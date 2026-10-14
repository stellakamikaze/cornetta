#!/bin/bash
# Compila Cornetta, monta Cornetta.app, la firma ad-hoc e produce dist/Cornetta.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Cornetta.app"

echo "→ Compilo (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Cornetta"

echo "→ Icona"
mkdir -p build
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/icon.png
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

echo "→ Bundle $APP (versione $VERSION, build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cornetta"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Firma ad-hoc"
codesign --force --sign - --identifier com.stellakamikaze.cornetta "$APP"
codesign --verify --strict "$APP"

echo "→ DMG"
mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
rm -f dist/Cornetta.dmg
hdiutil create -volname "Cornetta" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov dist/Cornetta.dmg >/dev/null
echo "✓ dist/Cornetta.dmg ($(du -h dist/Cornetta.dmg | cut -f1))"
