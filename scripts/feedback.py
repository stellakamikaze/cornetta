#!/usr/bin/env python3
"""Legge i feedback arrivati dall'app (Cloudflare KV, via wrangler).

  scripts/feedback.py                 elenco (i più recenti in fondo)
  scripts/feedback.py show N|ID       un feedback completo, con la diagnostica
  scripts/feedback.py issue N|ID      apre una issue GitHub e segna il feedback
  scripts/feedback.py done N|ID       segna il feedback come gestito
  scripts/feedback.py delete N|ID     cancella il feedback
  scripts/feedback.py --all           l'elenco include i feedback gestiti
"""
import json
import os
import subprocess
import sys
import tempfile
import time

NAMESPACE = "0071efedaeb74429b6cc2325753f653f"
REPO = "stellakamikaze/cornetta"
WORKER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worker")


def wrangler(*args, capture=True):
    cmd = ["npx", "-y", "wrangler@4", "kv", *args, "--namespace-id", NAMESPACE, "--remote"]
    for attempt in range(3):
        result = subprocess.run(cmd, cwd=WORKER_DIR, capture_output=capture, text=True)
        if result.returncode == 0 or "fetch failed" not in (result.stderr or ""):
            break
        time.sleep(3)  # errore di rete passeggero: riprova
    if result.returncode != 0:
        sys.exit(f"wrangler non riuscito: {result.stderr.strip()[-400:]}")
    return result.stdout


def keys():
    out = wrangler("key", "list", "--prefix", "fb:")
    start = out.find("[")
    items = json.loads(out[start:]) if start >= 0 else []
    return sorted(items, key=lambda k: k["name"])


def resolve(ref, items):
    if ref.isdigit() and 1 <= int(ref) <= len(items):
        return items[int(ref) - 1]
    for item in items:
        if item["name"] == ref or item["name"].endswith(ref):
            return item
    sys.exit(f"Feedback non trovato: {ref}")


def get(name):
    return json.loads(wrangler("key", "get", name, "--text"))


def safe(text):
    """Toglie i caratteri di controllo: un feedback non può muovere il cursore o cambiare il terminale."""
    return "".join(c for c in str(text) if c in "\n\t" or (c.isprintable() and not 0x202A <= ord(c) <= 0x202E and not 0x2066 <= ord(c) <= 0x2069))


def set_status(item, record, status):
    metadata = dict(item.get("metadata") or {})
    metadata["status"] = status
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(record, f)
        path = f.name
    try:
        # La scadenza a 90 giorni dalla ricezione resta anche dopo il cambio di stato.
        received = time.mktime(time.strptime(record["receivedAt"][:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
        ttl = max(60, int(received + 90 * 24 * 3600 - time.time()))
        wrangler("key", "put", item["name"], "--path", path, "--metadata", json.dumps(metadata), "--ttl", str(ttl))
    finally:
        os.unlink(path)


def main():
    args = [a for a in sys.argv[1:] if a != "--all"]
    show_all = "--all" in sys.argv
    items = keys()

    if not args:
        shown = 0
        for i, item in enumerate(items, 1):
            meta = item.get("metadata") or {}
            status = meta.get("status", "nuovo")
            if status != "nuovo" and not show_all:
                continue
            shown += 1
            when = item["name"][3:19].replace("T", " ")
            platform = "win" if meta.get("platform") == "windows" else "mac"
            print(f"{i:>3}. {when}  {platform} v{meta.get('version', '?'):<7} [{status}]  {safe(meta.get('preview', ''))}")
        if not shown:
            print("Nessun feedback nuovo." if items else "Nessun feedback.")
        return

    command, ref = args[0], args[1] if len(args) > 1 else ""
    if not ref:
        sys.exit(__doc__)
    item = resolve(ref, items)
    record = get(item["name"])

    if command == "show":
        app = record.get("app", {})
        print(f"ID:        {record['id']}")
        print(f"Ricevuto:  {record['receivedAt']}  ({record.get('country', '')})")
        print(f"Da:        {safe(record.get('name') or '-')} {safe(record.get('email') or '')}")
        print(f"App:       {safe(app)}")
        print(f"Stato:     {(item.get('metadata') or {}).get('status', 'nuovo')}\n")
        print(safe(record["message"]))
        if record.get("diagnostics"):
            print("\n--- diagnostica ---")
            print(safe(record["diagnostics"]))
    elif command == "issue":
        title = "Feedback: " + record["message"].splitlines()[0][:80]
        body = (f"{record['message']}\n\n---\nRicevuto {record['receivedAt']} · app {record.get('app', {})}\n"
                f"Da: {record.get('name') or '-'} {record.get('email') or ''}\nID: `{record['id']}`\n\n"
                f"<details><summary>Diagnostica</summary>\n\n```\n{record.get('diagnostics', '')}\n```\n</details>")
        subprocess.run(["gh", "label", "create", "feedback", "-R", REPO, "--color", "E4572E", "--force"],
                       capture_output=True)
        url = subprocess.run(["gh", "issue", "create", "-R", REPO, "--title", title, "--body-file", "-",
                              "--label", "feedback"], input=body, capture_output=True, text=True, check=True).stdout.strip()
        set_status(item, record, "issue " + url.rsplit("/", 1)[-1])
        print(url)
    elif command == "done":
        set_status(item, record, "gestito")
        print("Segnato come gestito.")
    elif command == "delete":
        wrangler("key", "delete", item["name"])
        print("Cancellato.")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
