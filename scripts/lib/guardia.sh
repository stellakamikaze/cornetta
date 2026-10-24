# Controlli comuni prima di ogni deploy: li caricano deploy-site.sh, release.sh e windows/tools/publish.sh.
#   source scripts/lib/guardia.sh && guardia      # dalla radice del repo
# Il deploy pubblica worker/ così com'è sul disco: si parte solo da un repo pulito, su un ramo allineato a
# GitHub, coi test verdi e con le migration D1 già applicate.

# Repo pulito (anche i file non tracciati), su un ramo con upstream, né indietro né avanti rispetto a GitHub.
guardia_repo() {
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    git status --short
    echo "Modifiche non committate o file non tracciati: committa o aggiungi a .gitignore prima di pubblicare."
    return 1
  fi
  git symbolic-ref -q HEAD >/dev/null || { echo "HEAD staccato: torna sul ramo principale prima di pubblicare."; return 1; }
  git rev-parse -q --verify '@{u}' >/dev/null || { echo "Il ramo non ha un upstream su GitHub: pubblica dal ramo principale."; return 1; }
  git fetch -q --tags origin || return 1
  [ "$(git rev-list --count 'HEAD..@{u}')" = 0 ] || { echo "Il repo è indietro rispetto a GitHub: git pull prima di pubblicare."; return 1; }
  [ "$(git rev-list --count '@{u}..HEAD')" = 0 ] || { echo "Ci sono commit non pushati: git push prima di pubblicare."; return 1; }
}

# Un node >= 22.13 (node:sqlite senza flag, per i test del Worker): quello del PATH, poi Homebrew e nvm.
node22() {
  local candidate
  for candidate in "$(command -v node || true)" /opt/homebrew/opt/node@22/bin/node /usr/local/opt/node@22/bin/node \
      $(ls -d "${NVM_DIR:-$HOME/.nvm}"/versions/node/v*/bin/node 2>/dev/null | sort -rV); do
    [ -x "$candidate" ] && "$candidate" -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 13) ? 0 : 1)' 2>/dev/null \
      && { echo "$candidate"; return 0; }
  done
  return 1
}

# I test del Worker e degli script: un guasto già coperto da un test non va online.
guardia_test() {
  local node
  node=$(node22) || { echo "Serve Node 22.13 o più recente per i test del Worker: brew install node@22, oppure nvm install 22."; return 1; }
  (cd worker && "$node" --test >/dev/null 2>&1) || { echo "I test del Worker falliscono: cd worker && node --test"; return 1; }
  python3 -m unittest discover -s scripts/tests >/dev/null 2>&1 || { echo "I test degli script falliscono: python3 -m unittest discover -s scripts/tests"; return 1; }
}

# Ogni file di worker/migrations deve essere già applicato al D1 vero, o la telemetria risponde 503.
guardia_migrations() {
  local applied
  applied=$(cd worker && npx -y wrangler@4.147.0 d1 execute cornetta-telemetria --remote --json \
    --command "SELECT name FROM d1_migrations") || { echo "Non riesco a leggere le migration applicate al D1."; return 1; }
  python3 - "$applied" worker/migrations <<'PY'
import json, os, re, sys
out, folder = sys.argv[1], sys.argv[2]
# Il JSON è la prima riga che apre un array («[», «[{» o «[]»): prima wrangler può stampare altro, anche «[WARNING] …».
match = re.search(r"^\[\s*(\{|\]|$)", out, re.M)
try:
    if not match:
        raise ValueError("nessun JSON")
    applied = {row["name"] for result in json.loads(out[match.start():]) for row in result.get("results", [])}
except (ValueError, TypeError, KeyError, AttributeError) as error:
    sys.exit(f"Risposta di wrangler d1 execute non leggibile ({error}):\n{out[:500]}")
missing = sorted(name for name in os.listdir(folder) if name.endswith(".sql") and name not in applied)
if missing:
    sys.exit(f"Migration non applicate al D1: {', '.join(missing)}\n"
             "Prima: cd worker && npx wrangler@4.147.0 d1 migrations apply cornetta-telemetria --remote")
PY
}

guardia() {
  guardia_repo && guardia_test && guardia_migrations
}
