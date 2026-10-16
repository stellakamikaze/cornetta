#!/bin/bash
# Pubblica una versione Windows già impacchettata dal CI (workflow «Windows», tag win-v<versione>).
#   git tag win-v0.3.0 && git push origin win-v0.3.0     # il CI compila, prova e impacchetta
#   windows/tools/publish.sh 0.3.0                        # scarica gli artifact e li mette online
# Le app installate vedono la versione nuova al prossimo controllo (all'avvio e ogni 4 ore).
#
# wrangler deploy pubblica TUTTA la cartella worker/public: lo script riparte dai file pubblicati
# (scripts/sync-published.py), così non toglie dal sito i DMG del Mac se la macchina non li ha.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?Uso: windows/tools/publish.sh VERSIONE (es. 0.3.0)}"
git fetch -q origin
[ -z "$(git rev-list HEAD..@{u})" ] || { echo "Il repo è indietro rispetto a GitHub: git pull prima di pubblicare."; exit 1; }
python3 scripts/sync-published.py
BASE_URL="https://cornetta.stellakamikaze.org"
DEST="worker/public/windows"
ARTIFACT="cornetta-windows-$VERSION"

RUN_ID=$(gh run list --workflow windows.yml --branch "win-v$VERSION" --status success --limit 1 \
  --json databaseId --jq '.[0].databaseId // empty')
if [ -z "$RUN_ID" ]; then
  echo "Nessuna run verde per il tag win-v$VERSION."
  echo "Prima: git tag win-v$VERSION && git push origin win-v$VERSION, poi aspetta il CI (gh run watch)."
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN_ID" -n "$ARTIFACT" -D "$TMP"
[ -f "$TMP/upload/CornettaSetup.exe" ] || { echo "L'artifact non contiene CornettaSetup.exe"; exit 1; }
grep -q "\"$VERSION\"" "$TMP/upload/releases.win.json" || { echo "releases.win.json non contiene $VERSION"; exit 1; }

# I pacchetti delle versioni precedenti restano: servono a chi aggiorna da lì.
mkdir -p "$DEST"
cp "$TMP"/upload/* "$DEST"/
ls -la "$DEST"

# La homepage propone Windows solo se latest.json ha la voce «windows» (worker/public/assets/site.js).
python3 - "$VERSION" "$DEST/CornettaSetup.exe" "$BASE_URL" <<'PY'
import hashlib, json, os, sys
version, exe, base = sys.argv[1:4]
path = "worker/public/downloads/latest.json"
latest = json.load(open(path)) if os.path.exists(path) else {}
latest["windows"] = {"version": version, "size": os.path.getsize(exe),
                     "sha256": hashlib.sha256(open(exe, "rb").read()).hexdigest(), "url": base + "/download/windows"}
json.dump(latest, open(path, "w"), indent=2)
PY
# /download/windows punta all'installer; la riga del Mac la scrive scripts/release.sh e resta.
grep -v '^/download/windows ' worker/public/_redirects > "$TMP/redirects" || true
echo "/download/windows /windows/CornettaSetup.exe 302" >> "$TMP/redirects"
cp "$TMP/redirects" worker/public/_redirects

python3 scripts/sync-published.py --check
(cd worker && npx -y wrangler@4 deploy)

# Verifica sul servizio vero: feed con la versione nuova e installer identico a quello del CI.
# Subito dopo il deploy la rete di Cloudflare può servire ancora i file vecchi: si riprova.
LOCAL=$(shasum -a 256 "$DEST/CornettaSetup.exe" | cut -d' ' -f1)
for attempt in 1 2 3 4 5 6; do
  sleep 10
  FEED_OK=$(curl -fsS "$BASE_URL/windows/releases.win.json" | grep -c "\"$VERSION\"" || true)
  REMOTE=$(curl -fsSL "$BASE_URL/windows/CornettaSetup.exe" | shasum -a 256 | cut -d' ' -f1 || true)
  [ "$FEED_OK" -ge 1 ] && [ "$REMOTE" = "$LOCAL" ] && break
  echo "Verifica $attempt/6: il servizio non è ancora allineato, riprovo."
done
[ "$FEED_OK" -ge 1 ] || { echo "Il feed pubblicato non contiene $VERSION"; exit 1; }
[ "$REMOTE" = "$LOCAL" ] || { echo "Il CornettaSetup.exe scaricato non coincide con quello del CI"; exit 1; }
curl -fsS "$BASE_URL/downloads/latest.json" | grep -q '"windows"' || { echo "latest.json pubblicato senza la voce windows"; exit 1; }
VIA_REDIRECT=$(curl -fsSL "$BASE_URL/download/windows" | shasum -a 256 | cut -d' ' -f1)
[ "$VIA_REDIRECT" = "$LOCAL" ] || { echo "/download/windows non porta all'installer nuovo"; exit 1; }
python3 scripts/sync-published.py --verify

git add worker/public/_redirects
git diff --cached --quiet || git commit -q -m "Windows $VERSION: /download/windows"

if ! gh release view "win-v$VERSION" >/dev/null 2>&1; then
  # --latest=false: la release in evidenza su GitHub resta quella del Mac, la versione principale.
  gh release create "win-v$VERSION" "$DEST/CornettaSetup.exe" --title "Cornetta $VERSION per Windows" --latest=false \
    --notes "Installer per utente, senza permessi di amministratore. Si aggiorna da solo." >/dev/null
fi
echo "Cornetta $VERSION per Windows pubblicata: $BASE_URL/windows/CornettaSetup.exe"
