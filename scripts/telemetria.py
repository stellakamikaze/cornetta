#!/usr/bin/env python3
"""Legge la telemetria di funzionamento delle app (Cloudflare D1 «cornetta-telemetria», via wrangler).

  scripts/telemetria.py              riepilogo: installazioni attive, versioni, esiti, errori più frequenti
  scripts/telemetria.py errori       gli ultimi 50 errori, con versione e sistema
  scripts/telemetria.py --locale     legge il D1 di «wrangler dev» invece di quello vero
"""
import json
import os
import subprocess
import sys

DATABASE = "cornetta-telemetria"
WORKER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worker")
REMOTE = "--locale" not in sys.argv


def query(sql):
    cmd = ["npx", "-y", "wrangler@4", "d1", "execute", DATABASE, "--json", "--command", sql,
           "--remote" if REMOTE else "--local"]
    result = subprocess.run(cmd, cwd=WORKER_DIR, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("wrangler non ha risposto:\n" + (result.stderr or result.stdout)[-800:])
    return json.loads(result.stdout)[0]["results"]


def table(title, rows):
    print(f"\n{title}")
    if not rows:
        print("  (niente)")
        return
    keys = list(rows[0].keys())
    widths = {k: max(len(k), *(len(str(r[k])) for r in rows)) for k in keys}
    print("  " + "  ".join(k.ljust(widths[k]) for k in keys))
    for r in rows:
        print("  " + "  ".join(str(r[k]).ljust(widths[k]) for k in keys))


def summary():
    table("Installazioni attive", query(
        "SELECT piattaforma, "
        "COUNT(DISTINCT CASE WHEN ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-7 days') THEN installazione END) AS ultimi_7_giorni, "
        "COUNT(DISTINCT CASE WHEN ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days') THEN installazione END) AS ultimi_30_giorni, "
        "COUNT(DISTINCT installazione) AS da_sempre FROM eventi GROUP BY piattaforma"))
    table("Versioni in uso (ultimi 30 giorni)", query(
        "SELECT piattaforma, versione, COUNT(DISTINCT installazione) AS installazioni FROM eventi "
        "WHERE ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days') GROUP BY piattaforma, versione ORDER BY piattaforma, versione DESC"))
    table("Registrazioni e trascrizioni (ultimi 30 giorni)", query(
        "SELECT piattaforma, evento, esito, COUNT(*) AS volte FROM eventi "
        "WHERE evento IN ('registrazione','trascrizione') AND ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days') "
        "GROUP BY piattaforma, evento, esito ORDER BY piattaforma, evento, volte DESC"))
    table("Errori più frequenti (ultimi 30 giorni)", query(
        "SELECT piattaforma, evento, codice, COUNT(*) AS volte, COUNT(DISTINCT installazione) AS installazioni "
        "FROM eventi WHERE esito = 'errore' AND ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days') "
        "GROUP BY piattaforma, evento, codice ORDER BY volte DESC LIMIT 15"))


def errors():
    table("Ultimi errori", query(
        "SELECT ts, piattaforma, versione, os, evento, codice, durata FROM eventi "
        "WHERE esito = 'errore' ORDER BY ts DESC LIMIT 50"))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    errors() if args[:1] == ["errori"] else summary()
