#!/usr/bin/env python3
"""Finto `gh` per i test: risponde a `gh run list` con le run del file in FAKE_GH_RUNS.

Applica i filtri come GitHub (--branch, --event, --commit, --status, --limit) e stampa i campi di --json.
FAKE_GH_IGNORE_FILTERS=1 simula un gh che ignora --event e --commit: il controllo sul risultato deve reggere.
Di --jq capisce solo l'espressione della versione vecchia di publish.sh, per la prova sul codice vecchio.
Ogni chiamata finisce in FAKE_GH_LOG, una per riga.
"""
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\n")

if args[:2] != ["run", "list"]:
    sys.exit(f"fake gh: comando non previsto {args}")

opts, i = {}, 2
while i < len(args):
    opts[args[i]] = args[i + 1]
    i += 2

runs = json.load(open(os.environ["FAKE_GH_RUNS"], encoding="utf-8"))
ignore = os.environ.get("FAKE_GH_IGNORE_FILTERS") == "1"
filters = {"--branch": "headBranch", "--status": "conclusion"}
if not ignore:
    filters.update({"--event": "event", "--commit": "headSha"})
for flag, field in filters.items():
    if flag in opts:
        runs = [r for r in runs if r[field] == opts[flag]]
runs = runs[: int(opts.get("--limit", "20"))]
fields = opts.get("--json", "databaseId").split(",")
out = [{f: r[f] for f in fields} for r in runs]

jq = opts.get("--jq")
if jq is None:
    print(json.dumps(out))
elif jq == ".[0].databaseId // empty":
    if out:
        print(out[0]["databaseId"])
else:
    sys.exit(f"fake gh: --jq non previsto {jq}")
