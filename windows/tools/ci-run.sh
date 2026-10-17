#!/bin/bash
# Stampa l'id della run del CI da pubblicare per la versione Windows indicata. Lo usa windows/tools/publish.sh.
#   windows/tools/ci-run.sh 0.4.0
# Vale solo una run verde del workflow «Windows» partita dal push del tag win-v<versione> e costruita sul
# commit del tag. Il workflow gira anche sulle pull request, e una PR da un fork può avere un ramo che si
# chiama come il tag: filtrare sul solo nome del ramo pubblicherebbe il suo artifact.
set -euo pipefail

VERSION="${1:?Uso: windows/tools/ci-run.sh VERSIONE (es. 0.4.0)}"
TAG="win-v$VERSION"
SHA=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}") || {
  echo "Il tag $TAG non c'è in questo repo: git fetch --tags, oppure crea e pubblica il tag." >&2
  exit 1
}

RUNS=$(gh run list --workflow windows.yml --event push --branch "$TAG" --commit "$SHA" --status success \
  --limit 20 --json databaseId,headSha,event,headBranch,conclusion)

# Controllo anche sul risultato: la run deve dichiarare lo stesso commit, l'evento push e il ramo del tag.
python3 -c '
import json, sys
sha, tag = sys.argv[1], sys.argv[2]
for run in json.loads(sys.stdin.read() or "[]"):
    if (run.get("headSha") == sha and run.get("event") == "push" and run.get("headBranch") == tag
            and run.get("conclusion") == "success"):
        print(run["databaseId"])
        sys.exit(0)
print(f"Nessuna run verde del push di {tag} sul commit {sha[:12]}.", file=sys.stderr)
print(f"Prima: git push origin {tag}, poi aspetta il CI (gh run watch).", file=sys.stderr)
sys.exit(1)
' "$SHA" "$TAG" <<<"$RUNS"
