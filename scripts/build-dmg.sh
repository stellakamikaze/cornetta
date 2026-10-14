#!/bin/bash
# Compila Cornetta (universale arm64 + x86_64), monta Cornetta.app con Sparkle, la firma e produce il DMG.
#   VERSION=0.2.0 scripts/build-dmg.sh   →   dist/Cornetta-0.2.0.dmg
# Firma: usa l'identità «Cornetta Self-Signed» se è nel portachiavi (permessi stabili fra versioni),
# altrimenti firma ad-hoc. SIGN_IDENTITY la sovrascrive.
# Notarizzazione Apple (niente «Apri comunque» al primo avvio): serve un certificato
# «Developer ID Application» e un profilo notarytool salvato nel portachiavi:
#   SIGN_IDENTITY="Developer ID Application: Nome (TEAMID)" NOTARY_PROFILE=cornetta-notary scripts/release.sh X.Y.Z
# Con un Developer ID il runtime rinforzato è automatico. Col certificato locale no: senza Team ID
# il runtime rinforzato impedisce all'app di caricare Sparkle (verificato il 14/10/2026).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
APP="build/Cornetta.app"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-identity -p codesigning | grep -q "Cornetta Self-Signed"; then SIGN_IDENTITY="Cornetta Self-Signed"; else SIGN_IDENTITY="-"; fi
fi

echo "→ Compilo (release, arm64 + x86_64)"
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" >/dev/null
done
ARM="$(swift build -c release --arch arm64 --show-bin-path)/Cornetta"
X86="$(swift build -c release --arch x86_64 --show-bin-path)/Cornetta"

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

echo "→ Bundle $APP (versione $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/Cornetta"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$VERSION/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Firma ($SIGN_IDENTITY)"
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
RUNTIME=()
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
  RUNTIME=(--options runtime --timestamp)
fi
sign() { codesign --force --sign "$SIGN_IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$@"; }
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier com.stellakamikaze.cornetta --entitlements Resources/Cornetta.entitlements "$APP"
codesign --verify --deep --strict "$APP"

notarize() {
  echo "→ Notarizzazione di $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Prima l'app (così funziona anche offline una volta copiata), poi il DMG che la contiene.
  ZIP="$(mktemp -d)/Cornetta.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
fi

echo "→ DMG"
mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Cornetta.app"
ln -s /Applications "$STAGE/Applicazioni"
DMG="dist/Cornetta-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Cornetta" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
sign "$DMG"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
