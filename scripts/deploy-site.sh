#!/bin/bash
# Pubblica le pagine e il Worker senza toccare le versioni: da qualunque macchina, Mac o Windows.
#   scripts/deploy-site.sh
# Parte dal repo allineato a GitHub e dai file pubblicati (scripts/sync-published.py), così un deploy
# da una macchina che non ha fatto le release non toglie dal sito DMG, delta o feed Windows.
set -euo pipefail
cd "$(dirname "$0")/.."

git diff --quiet && git diff --cached --quiet || { echo "Ci sono modifiche non committate: committa prima di pubblicare."; exit 1; }
git fetch -q origin
[ -z "$(git rev-list HEAD..@{u})" ] || { echo "Il repo è indietro rispetto a GitHub: git pull prima di pubblicare."; exit 1; }

python3 scripts/sync-published.py
python3 scripts/sync-published.py --check
(cd worker && npx -y wrangler@4 deploy)

# Verifica sul servizio vero: il sito serve ancora ogni file che i feed e /download citano.
# Subito dopo il deploy la rete di Cloudflare può servire ancora la versione precedente: si riprova.
for attempt in 1 2 3 4 5 6; do
  sleep 10
  python3 scripts/sync-published.py --verify >/dev/null && break
  echo "Verifica $attempt/6: il servizio non è ancora allineato, riprovo."
done
python3 scripts/sync-published.py --verify
echo "✓ Sito pubblicato: https://cornetta.stellakamikaze.org"
