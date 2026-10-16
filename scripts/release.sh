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
git fetch -q origin
[ -z "$(git rev-list HEAD..@{u})" ] || { echo "Il repo è indietro rispetto a GitHub: git pull prima di pubblicare."; exit 1; }
# Riparte dai file pubblicati (DMG, delta, latest.json, feed Windows): wrangler deploy pubblica tutta
# worker/public, e una release da una macchina che non li ha li toglierebbe dal sito.
python3 scripts/sync-published.py

scripts/test.sh >/dev/null
VERSION="$VERSION" scripts/build-dmg.sh
# Mai pubblicare una firma ad-hoc: chi aggiorna perderebbe i permessi e Sparkle rifiuterebbe l'app.
AUTH=$(codesign -dvv build/Cornetta.app 2>&1 | grep '^Authority=' | head -1 || true)
case "$AUTH" in
  "Authority=Cornetta Self-Signed"|"Authority=Developer ID Application"*) echo "→ Firma: ${AUTH#Authority=}" ;;
  *) echo "Firma sbagliata (${AUTH:-ad-hoc}): manca il certificato «Cornetta Self-Signed» nel portachiavi."; exit 1 ;;
esac

mkdir -p "$DOWNLOADS"
cp "dist/Cornetta-$VERSION.dmg" "$DOWNLOADS/"
{
  echo "<h2>Cornetta $VERSION</h2><ul>"
  for line in "$@"; do printf '<li>%s</li>\n' "$line"; done
  echo "</ul>"
} > "$DOWNLOADS/Cornetta-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" --account cornetta --download-url-prefix "$BASE_URL/downloads/" \
  --embed-release-notes -o worker/public/appcast.xml "$DOWNLOADS"
# Cambia solo la riga del Mac: /download/windows la scrive windows/tools/publish.sh e deve restare.
{ printf '/download /downloads/Cornetta-%s.dmg 302\n' "$VERSION"; grep -v '^/download ' worker/public/_redirects 2>/dev/null || true; } > worker/public/_redirects.new
mv worker/public/_redirects.new worker/public/_redirects
# latest.json: versione, peso e SHA-256 letti dalla pagina. Conserva la voce Windows se c'è.
python3 - "$VERSION" "dist/Cornetta-$VERSION.dmg" "$BASE_URL" <<'PY'
import hashlib, json, os, sys
version, dmg, base = sys.argv[1:4]
path = "worker/public/downloads/latest.json"
latest = json.load(open(path)) if os.path.exists(path) else {}
latest["mac"] = {"version": version, "size": os.path.getsize(dmg),
                 "sha256": hashlib.sha256(open(dmg, "rb").read()).hexdigest(), "url": base + "/download"}
json.dump(latest, open(path, "w"), indent=2)
PY
# La versione nei dati strutturati delle due pagine segue la release.
sed -i '' -E "s/\"softwareVersion\": \"[^\"]+\"/\"softwareVersion\": \"$VERSION\"/" worker/public/index.html worker/public/en/index.html

python3 scripts/sync-published.py --check
(cd worker && npx -y wrangler@4 deploy)

# Verifica sul servizio vero: feed con la versione nuova e DMG identico a quello locale.
# Subito dopo il deploy la rete di Cloudflare può servire ancora la versione precedente: si riprova.
LOCAL=$(shasum -a 256 "dist/Cornetta-$VERSION.dmg" | cut -d' ' -f1)
for attempt in 1 2 3 4 5 6; do
  sleep 10
  # «|| true»: con pipefail un 404 passeggero chiuderebbe lo script invece di riprovare.
  FEED_OK=$(curl -fsS "$BASE_URL/appcast.xml" | grep -c "<sparkle:shortVersionString>$VERSION<" || true)
  REMOTE=$(curl -fsSL "$BASE_URL/download" | shasum -a 256 | cut -d' ' -f1 || true)
  [ "$FEED_OK" -ge 1 ] && [ "$REMOTE" = "$LOCAL" ] && break
  echo "Verifica $attempt/6: il servizio non è ancora allineato, riprovo."
done
[ "$FEED_OK" -ge 1 ] || { echo "Il feed pubblicato non contiene $VERSION"; exit 1; }
[ "$REMOTE" = "$LOCAL" ] || { echo "Il DMG scaricato non coincide con quello locale"; exit 1; }
python3 scripts/sync-published.py --verify

git add worker/public/appcast.xml worker/public/_redirects worker/public/index.html worker/public/en/index.html
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
NOTES=$(printf -- '- %s\n' "$@")
gh release create "v$VERSION" "dist/Cornetta-$VERSION.dmg" --title "Cornetta $VERSION" --notes "$NOTES" >/dev/null

# Homebrew: il cask di stellakamikaze/homebrew-tap segue la release (brew install --cask stellakamikaze/tap/cornetta).
TAP=$(mktemp -d)
if gh repo clone stellakamikaze/homebrew-tap "$TAP" -- -q; then
  SHA=$(shasum -a 256 "dist/Cornetta-$VERSION.dmg" | cut -d' ' -f1)
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/cornetta.rb"
  git -C "$TAP" commit -qam "Cornetta $VERSION" && git -C "$TAP" push -q && echo "→ Cask Homebrew aggiornato a $VERSION"
else
  echo "Attenzione: tap Homebrew non aggiornato, fallo a mano in stellakamikaze/homebrew-tap"
fi
rm -rf "$TAP"
echo "✓ Cornetta $VERSION pubblicata: $BASE_URL"
