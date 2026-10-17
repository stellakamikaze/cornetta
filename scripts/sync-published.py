#!/usr/bin/env python3
"""Riporta in worker/public i file pubblicati che non stanno nel repo (DMG, delta, feed Windows, latest.json).

  scripts/sync-published.py           scarica dal sito ogni file pubblicato e lo scrive se manca o è diverso
  scripts/sync-published.py --check   non scarica: esce 1 se un file pubblicato manca in locale
  scripts/sync-published.py --verify  dopo il deploy: esce 1 se il sito non serve un file che i feed citano

wrangler deploy pubblica tutta worker/public, e downloads/ e windows/ sono fuori da git: un deploy da una
macchina che non li ha toglie dal sito i DMG o il feed Windows. Ogni deploy parte quindi da qui, e prima di
wrangler deploy passa --check. I file locali che il sito non ha ancora (una versione nuova) restano.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

BASE_URL = "https://cornetta.stellakamikaze.org"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PUBLIC = os.path.join(ROOT, "worker", "public")
USER_AGENT = "cornetta-sync-published"  # il Worker non conta come download chi non sembra un browser


def fetch(path):
    """Il contenuto pubblicato di path, o None se il sito risponde 404."""
    request = urllib.request.Request(BASE_URL + "/" + path, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def tags():
    out = subprocess.run(["git", "-C", ROOT, "tag", "-l"], capture_output=True, text=True, check=True).stdout
    return out.split()


def published_files():
    """(obbligatori, facoltativi): percorsi relativi a worker/public.

    Obbligatori sono i file che i feed pubblicati citano: se il sito non li ha, è già rotto e ci si ferma.
    Facoltativi sono quelli delle versioni vecchie (dai tag) e le note: si prendono se il sito li ha.
    """
    required, optional = {"downloads/latest.json", "windows/releases.win.json", "windows/RELEASES",
                          "windows/assets.win.json", "windows/CornettaSetup.exe"}, set()
    appcast = (fetch("appcast.xml") or b"").decode("utf-8")
    for url in re.findall(r'url="([^"]+)"', appcast):
        if url.startswith(BASE_URL + "/downloads/"):
            required.add(url[len(BASE_URL) + 1:])
    # La firma del feed è obbligatoria appena il sito la serve: un deploy senza farebbe rifiutare gli aggiornamenti.
    if fetch("windows/releases.win.json.sig") is not None:
        required.add("windows/releases.win.json.sig")
    feed = fetch("windows/releases.win.json")
    if feed:
        for asset in json.loads(feed.decode("utf-8-sig"))["Assets"]:
            required.add("windows/" + asset["FileName"])
    assets = fetch("windows/assets.win.json")
    if assets:
        for asset in json.loads(assets.decode("utf-8-sig")):
            optional.add("windows/" + asset["RelativeFileName"])
    # Le destinazioni di /download e /download/windows (scritte da release.sh e publish.sh, in git).
    with open(os.path.join(PUBLIC, "_redirects"), encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("/download"):
                required.add(parts[1].lstrip("/"))
    for tag in tags():
        if tag.startswith("v"):
            version = tag[1:]
            optional |= {f"downloads/Cornetta-{version}.dmg", f"downloads/Cornetta-{version}.html"}
        elif tag.startswith("win-v"):
            version = tag[5:]
            optional |= {f"windows/Cornetta-{version}-full.nupkg", f"windows/Cornetta-{version}-delta.nupkg"}
    return required, optional - required


def local(path):
    return os.path.join(PUBLIC, *path.split("/"))


def check(required):
    missing = sorted(p for p in required if not os.path.exists(local(p)))
    for path in missing:
        print(f"Manca in locale: worker/public/{path}")
    # latest.json locale deve avere ogni piattaforma di quello pubblicato, o la homepage la perde.
    published = json.loads((fetch("downloads/latest.json") or b"{}").decode("utf-8"))
    path = local("downloads/latest.json")
    mine = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    lost = sorted(set(published) - set(mine))
    if lost:
        print(f"latest.json locale senza la voce {', '.join(lost)}")
    return not missing and not lost


def verify(required):
    missing = sorted(p for p in required if fetch(p) is None)
    for path in missing:
        print(f"Il sito non serve più {path}")
    return not missing


def main():
    sys.stdout.reconfigure(encoding="utf-8")  # su Windows la console è cp1252 e non stampa «→»
    required, optional = published_files()
    if "--verify" in sys.argv[1:]:
        if not verify(required):
            sys.exit("Il sito ha perso dei file pubblicati.")
        print(f"→ il sito serve tutti i {len(required)} file citati dai feed")
        return
    if "--check" in sys.argv[1:]:
        if not check(required):
            sys.exit("Il deploy toglierebbe dal sito questi file: lancia scripts/sync-published.py e riprova.")
        print(f"→ {len(required)} file pubblicati presenti in locale")
        return
    written = 0
    for path in sorted(required | optional):
        data = fetch(path)
        if data is None:
            if path in required:
                sys.exit(f"Il sito non ha {path}, che i suoi feed citano: va ripubblicato prima di ogni altro deploy.")
            continue
        target = local(path)
        if os.path.exists(target) and open(target, "rb").read() == data:
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        written += 1
        print(f"  {path} ({len(data):,} byte)")
    print(f"→ worker/public allineata al sito: {written} file scritti")


if __name__ == "__main__":
    main()
