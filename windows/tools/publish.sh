#!/bin/bash
# Pubblica una versione Windows già impacchettata dal CI (workflow «Windows», tag win-v<versione>).
#   git tag win-v0.3.0 && git push origin win-v0.3.0     # il CI compila, prova e impacchetta
#   windows/tools/publish.sh 0.3.0                        # scarica gli artifact e li mette online
# Le app installate vedono la versione nuova al prossimo controllo (all'avvio e ogni 4 ore).
#
# Firma il feed (releases.win.json.sig) con la chiave indicata da CORNETTA_FEED_KEY_FILE: senza, si ferma
# subito. Le app dalla versione con la verifica rifiutano un feed senza firma valida (docs/SERVIZIO.md).
#
# wrangler deploy pubblica TUTTA la cartella worker/public: lo script parte dal repo pulito e allineato a
# GitHub, coi test verdi (scripts/lib/guardia.sh), e dai file pubblicati (scripts/sync-published.py), così
# non toglie dal sito i DMG del Mac se la macchina non li ha.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?Uso: windows/tools/publish.sh VERSIONE (es. 0.3.0)}"
python3 windows/tools/sign-feed.py --check-key
source scripts/lib/guardia.sh
guardia
python3 scripts/sync-published.py
# Mai sopra una versione più recente: le installazioni nuove riceverebbero quella vecchia. Uguale sì, per riprendere.
python3 scripts/sync-published.py --not-older windows "$VERSION"
BASE_URL="https://cornetta.stellakamikaze.org"
DEST="worker/public/windows"
ARTIFACT="cornetta-windows-$VERSION"

# Solo la run del push del tag, sul commit del tag: mai quella di una pull request col ramo omonimo.
RUN_ID=$(windows/tools/ci-run.sh "$VERSION")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN_ID" -n "$ARTIFACT" -D "$TMP"
[ -f "$TMP/upload/CornettaSetup.exe" ] || { echo "L'artifact non contiene CornettaSetup.exe"; exit 1; }
grep -q "\"$VERSION\"" "$TMP/upload/releases.win.json" || { echo "releases.win.json non contiene $VERSION"; exit 1; }

# I pacchetti delle versioni precedenti restano: servono a chi aggiorna da lì.
mkdir -p "$DEST"
cp "$TMP"/upload/* "$DEST"/
python3 windows/tools/sign-feed.py "$DEST/releases.win.json"
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
(cd worker && npx -y wrangler@4.147.0 deploy)

# Verifica sul servizio vero: feed con la versione nuova e installer identico a quello del CI.
# Subito dopo il deploy la rete di Cloudflare può servire ancora i file vecchi: si riprova.
LOCAL=$(shasum -a 256 "$DEST/CornettaSetup.exe" | cut -d' ' -f1)
for attempt in 1 2 3 4 5 6; do
  sleep 10
  FEED_OK=$(curl -fsS "$BASE_URL/windows/releases.win.json" | grep -c "\"$VERSION\"" || true)
  REMOTE=$(curl -fsSL "$BASE_URL/windows/CornettaSetup.exe" | shasum -a 256 | cut -d' ' -f1 || true)
  SIG_OK=0
  curl -fsS -o "$TMP/feed.json" "$BASE_URL/windows/releases.win.json" \
    && curl -fsS -o "$TMP/feed.sig" "$BASE_URL/windows/releases.win.json.sig" \
    && python3 windows/tools/sign-feed.py --verify "$TMP/feed.json" "$TMP/feed.sig" >/dev/null 2>&1 && SIG_OK=1
  LATEST_OK=$(curl -fsS "$BASE_URL/downloads/latest.json" | grep -c '"windows"' || true)
  VIA_REDIRECT=$(curl -fsSL "$BASE_URL/download/windows" | shasum -a 256 | cut -d' ' -f1 || true)
  [ "$FEED_OK" -ge 1 ] && [ "$REMOTE" = "$LOCAL" ] && [ "$SIG_OK" = 1 ] && [ "$LATEST_OK" -ge 1 ] \
    && [ "$VIA_REDIRECT" = "$LOCAL" ] && python3 scripts/sync-published.py --verify >/dev/null && break
  echo "Verifica $attempt/6: il servizio non è ancora allineato, riprovo."
done
[ "$FEED_OK" -ge 1 ] || { echo "Il feed pubblicato non contiene $VERSION"; exit 1; }
[ "$REMOTE" = "$LOCAL" ] || { echo "Il CornettaSetup.exe scaricato non coincide con quello del CI"; exit 1; }
[ "$SIG_OK" = 1 ] || { echo "Il feed pubblicato non ha una firma valida (releases.win.json.sig)"; exit 1; }
[ "$LATEST_OK" -ge 1 ] || { echo "latest.json pubblicato senza la voce windows"; exit 1; }
[ "$VIA_REDIRECT" = "$LOCAL" ] || { echo "/download/windows non porta all'installer nuovo"; exit 1; }
python3 scripts/sync-published.py --verify

# Solo _redirects, e subito su GitHub: un deploy dall'altra macchina parte da git e deve avere la riga.
git diff --quiet -- worker/public/_redirects || {
  git commit -q -m "Windows $VERSION: /download/windows" -- worker/public/_redirects
  git push -q origin HEAD
}

# La release è anche il backup dei file pubblicati: l'artifact della CI scade dopo 90 giorni, e un tag
# ricompilato non dà gli stessi byte (lo SHA-256 nel feed non tornerebbe).
FILES=("$TMP"/upload/* "$DEST/releases.win.json.sig")
if gh release view "win-v$VERSION" >/dev/null 2>&1; then
  gh release upload "win-v$VERSION" "${FILES[@]}" --clobber
else
  # --latest=false: la release in evidenza su GitHub resta quella del Mac, la versione principale.
  gh release create "win-v$VERSION" "${FILES[@]}" --title "Cornetta $VERSION per Windows" --latest=false \
    --notes "Installer per utente, senza permessi di amministratore. Si aggiorna da solo." >/dev/null
fi
echo "Cornetta $VERSION per Windows pubblicata: $BASE_URL/windows/CornettaSetup.exe"
