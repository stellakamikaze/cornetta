#!/usr/bin/env python3
"""Riporta in worker/public i file pubblicati che non stanno nel repo (DMG, delta, feed Windows, latest.json).

  scripts/sync-published.py           scarica dal sito ogni file pubblicato e lo scrive se manca o è diverso
  scripts/sync-published.py --check   non scarica: esce 1 se un file pubblicato manca in locale
  scripts/sync-published.py --verify  dopo il deploy: esce 1 se il sito non serve, o serve diverso, un file che i feed citano
  scripts/sync-published.py --not-older mac|windows VERSIONE   esce 1 se VERSIONE è più vecchia di quella in latest.json
  scripts/sync-published.py --recover   a mano, dopo aver controllato le copie locali dei file senza versione nel nome
                                        che il sito ha perso: le conferma, e il deploy successivo le rimette online

wrangler deploy pubblica tutta worker/public, e downloads/ e windows/ sono fuori da git: un deploy da una
macchina che non li ha toglie dal sito i DMG o il feed Windows. Ogni deploy parte quindi da qui, e prima di
wrangler deploy passa --check. I file locali che il sito non ha ancora (una versione nuova, o un file perso
dal sito e recuperato con gh release download) restano, e il deploy li rimette online. Un file obbligatorio senza
versione nel nome (feed Windows, installer, latest.json) perso dal sito ferma invece la sync: la copia locale può
essere più vecchia di quella persa. Riparte solo dopo --recover, che gli script di deploy non passano mai.
"""
import hashlib
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
BIG = (".dmg", ".delta", ".nupkg", ".exe")  # --verify li confronta per lunghezza, senza scaricarli
# Senza versione nel nome: una copia locale può essere più vecchia di quella che il sito ha perso.
UNVERSIONED = {"downloads/latest.json", "windows/releases.win.json", "windows/releases.win.json.sig",
               "windows/RELEASES", "windows/assets.win.json", "windows/CornettaSetup.exe"}


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


def served_length(path):
    """Content-Length pubblicato di path ("" se manca), o None se il sito risponde 404. Legge solo le intestazioni:
    la HEAD di Cloudflare non porta Content-Length, la GET sì, e si chiude prima del corpo."""
    request = urllib.request.Request(BASE_URL + "/" + path, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.headers.get("Content-Length", "")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def tags():
    out = subprocess.run(["git", "-C", ROOT, "tag", "-l"], capture_output=True, text=True, check=True).stdout
    return out.split()


def recover_path():
    """Le copie locali confermate con --recover: dentro .git, quindi mai nel repo né nel deploy."""
    out = subprocess.run(["git", "-C", ROOT, "rev-parse", "--git-path", "cornetta-recover.json"],
                         capture_output=True, text=True, check=True).stdout.strip()
    return out if os.path.isabs(out) else os.path.join(ROOT, out)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def confirmed():
    """{percorso: sha256} delle copie locali confermate con --recover."""
    try:
        with open(recover_path(), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_confirmed(entries):
    path = recover_path()
    if entries:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(entries, f, indent=2)
    elif os.path.exists(path):
        os.remove(path)


def published_files():
    """(obbligatori, facoltativi): percorsi relativi a worker/public.

    Obbligatori sono i file che i feed pubblicati citano: se il sito non li ha, è già rotto e ci si ferma.
    Facoltativi sono quelli delle versioni vecchie (dai tag), le note e i delta: si prendono se il sito li ha.
    Senza un delta Sparkle scarica il DMG intero, e i delta non stanno nelle release GitHub.
    """
    required, optional = UNVERSIONED - {"windows/releases.win.json.sig"}, set()
    appcast = (fetch("appcast.xml") or b"").decode("utf-8")
    for url in re.findall(r'url="([^"]+)"', appcast):
        if url.startswith(BASE_URL + "/downloads/"):
            (optional if url.endswith(".delta") else required).add(url[len(BASE_URL) + 1:])
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


def served(path):
    """None se il sito serve path come il file locale, altrimenti cosa non va."""
    target = local(path)
    if path.endswith(BIG):
        length = served_length(path)
        if length is None:
            return "non serve più"
        same = not length or not os.path.exists(target) or int(length) == os.path.getsize(target)
    else:
        data = fetch(path)
        if data is None:
            return "non serve più"
        same = not os.path.exists(target) or open(target, "rb").read() == data
    return None if same else "serve una versione diversa di"


def verify(required):
    wrong = [(p, problem) for p in sorted(required) if (problem := served(p))]
    for path, problem in wrong:
        print(f"Il sito {problem} {path}")
    return not wrong


def version_key(version):
    """Ordine semver, pre-release compresa (0.4.0-beta.1 < 0.4.0): la stessa forma che accetta la CI Windows."""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?", version)
    if not match:
        sys.exit(f"Versione non valida: {version}")
    pre = match.group(4)
    ids = [(0, int(x), "") if x.isdigit() else (1, 0, x) for x in pre.split(".")] if pre else []
    return tuple(int(x) for x in match.group(1, 2, 3)), not pre, ids


def not_older(platform, version):
    """Vero se version non è più vecchia di quella che latest.json locale (già allineato al sito) dà a platform."""
    path = local("downloads/latest.json")
    latest = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    published = latest.get(platform, {}).get("version")
    return published is None or version_key(version) >= version_key(published), published


def main():
    sys.stdout.reconfigure(encoding="utf-8")  # su Windows la console è cp1252 e non stampa «→»
    if sys.argv[1:2] == ["--not-older"]:
        platform, version = sys.argv[2:4]
        ok, published = not_older(platform, version)
        if not ok:
            sys.exit(f"{version} è più vecchia della versione {platform} pubblicata ({published}): niente da pubblicare.")
        return
    required, optional = published_files()
    if "--verify" in sys.argv[1:]:
        if not verify(required):
            sys.exit("Il sito non serve tutti i file pubblicati, o li serve diversi da quelli locali.")
        print(f"→ il sito serve tutti i {len(required)} file citati dai feed, uguali a quelli locali")
        return
    if "--check" in sys.argv[1:]:
        if not check(required):
            sys.exit("Il deploy toglierebbe dal sito questi file: lancia scripts/sync-published.py e riprova.")
        print(f"→ {len(required)} file pubblicati presenti in locale")
        return
    recover = "--recover" in sys.argv[1:]
    # Una conferma vale solo per la copia controllata: se il file locale cambia, va controllato di nuovo.
    accepted = {} if recover else confirmed()
    written, local_only, unconfirmed = 0, set(), []
    for path in sorted(required | optional):
        # La firma va con il feed: se il feed torna online dalla copia locale, la firma del sito non lo verifica.
        if path == "windows/releases.win.json.sig" and "windows/releases.win.json" in local_only:
            print(f"  {path}: tengo quella locale, come il feed")
            continue
        data = fetch(path)
        if data is None:
            if path in required:
                if not os.path.exists(local(path)):
                    sys.exit(f"Il sito non ha {path}, che i suoi feed citano, e non c'è nemmeno in locale: recuperalo dalla "
                             "release GitHub (gh release download, docs/SERVIZIO.md «File pubblicati persi») e riprova.")
                local_only.add(path)
                if path in UNVERSIONED and not recover and accepted.get(path) != sha256(local(path)):
                    unconfirmed.append(path)
                    print(f"  ATTENZIONE: {path} è solo in locale e non ha la versione nel nome: la copia può essere vecchia.")
                else:
                    print(f"  {path}: solo in locale, torna online col deploy")
            continue
        target = local(path)
        if os.path.exists(target) and open(target, "rb").read() == data:
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        written += 1
        print(f"  {path} ({len(data):,} byte)")
    if recover:
        checked = {p: sha256(local(p)) for p in sorted(local_only & UNVERSIONED)}
        save_confirmed(checked)
        print(f"→ worker/public allineata al sito: {written} file scritti")
        if checked:
            print(f"→ copie locali confermate: {', '.join(checked)}. Ora lancia di nuovo lo script di deploy.")
        return
    # Le conferme dei file che il sito serve di nuovo non servono più.
    save_confirmed({p: h for p, h in accepted.items() if p in local_only and p not in unconfirmed})
    if unconfirmed:
        sys.exit(f"Il sito ha perso {', '.join(unconfirmed)}, senza versione nel nome: la copia locale può essere più "
                 "vecchia dell'ultima pubblicata, e il deploy la rimetterebbe online. Controllala o recuperala "
                 "(docs/SERVIZIO.md «File pubblicati persi»), poi lancia scripts/sync-published.py --recover e di nuovo "
                 "lo script di deploy.")
    print(f"→ worker/public allineata al sito: {written} file scritti")


if __name__ == "__main__":
    main()
