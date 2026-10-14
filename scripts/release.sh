#!/bin/bash
# Pubblica una versione: DMG firmato, feed degli aggiornamenti, pagina, tag e release GitHub.
#   scripts/release.sh 0.2.1 "Novità in una riga" ["Seconda riga" ...]
# Le app installate la vedono al prossimo controllo (all'avvio e ogni 4 ore).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Uso: scripts/release.sh VERSIONE \"novità\" [...]}"
shift
[ $# -gt 0 ] || { echo "Scrivi almeno una novità per la finestra di aggiornamento."; exit 1; }
BASE_URL="https://cornetta.stellakamikaze.org"
DOWNLOADS="worker/public/downloads"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

git diff --quiet && git diff --cached --quiet || { echo "Ci sono modifiche non committate: committa prima di pubblicare."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Il tag v$VERSION esiste già."; exit 1; }

scripts/test.sh >/dev/null
VERSION="$VERSION" scripts/build-dmg.sh

mkdir -p "$DOWNLOADS"
cp "dist/Cornetta-$VERSION.dmg" "$DOWNLOADS/"
{
  echo "<h2>Cornetta $VERSION</h2><ul>"
  for line in "$@"; do printf '<li>%s</li>\n' "$line"; done
  echo "</ul>"
} > "$DOWNLOADS/Cornetta-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" --account cornetta --download-url-prefix "$BASE_URL/downloads/" \
  --embed-release-notes -o worker/public/appcast.xml "$DOWNLOADS"
printf '/download /downloads/Cornetta-%s.dmg 302\n' "$VERSION" > worker/public/_redirects

(cd worker && npx -y wrangler@4 deploy)

# Verifica sul servizio vero: feed con la versione nuova e DMG identico a quello locale.
sleep 5
curl -fsS "$BASE_URL/appcast.xml" | grep -q "<sparkle:shortVersionString>$VERSION<" || { echo "Il feed pubblicato non contiene $VERSION"; exit 1; }
REMOTE=$(curl -fsSL "$BASE_URL/download" | shasum -a 256 | cut -d' ' -f1)
LOCAL=$(shasum -a 256 "dist/Cornetta-$VERSION.dmg" | cut -d' ' -f1)
[ "$REMOTE" = "$LOCAL" ] || { echo "Il DMG scaricato non coincide con quello locale"; exit 1; }

git add worker/public/appcast.xml worker/public/_redirects
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
NOTES=$(printf -- '- %s\n' "$@")
gh release create "v$VERSION" "dist/Cornetta-$VERSION.dmg" --title "Cornetta $VERSION" --notes "$NOTES" >/dev/null
echo "✓ Cornetta $VERSION pubblicata: $BASE_URL"
