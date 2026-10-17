#!/usr/bin/env python3
"""Firma e verifica il feed degli aggiornamenti Windows (releases.win.json) con ECDSA P-256 e SHA-256.

  windows/tools/sign-feed.py FEED                 scrive FEED.sig (firma r||s di 64 byte, in base64)
  windows/tools/sign-feed.py --check-key          controlla la chiave privata senza firmare niente
  windows/tools/sign-feed.py --public-key         stampa la chiave pubblica (X||Y in esadecimale) della privata
  windows/tools/sign-feed.py --verify FEED SIG    verifica con la chiave pubblica incorporata nell'app

La chiave privata è un file PEM fuori dal repo, indicato da CORNETTA_FEED_KEY_FILE: il valore non passa mai
da argv né dai log, openssl lo legge dal file. Prima di firmare lo script controlla che la sua chiave pubblica
sia quella incorporata in windows/src/Cornetta.App/AppInfo.cs (UpdateFeedPublicKey): una firma con la chiave
sbagliata farebbe rifiutare l'aggiornamento a tutte le app installate.
Come generare la chiave: docs/SERVIZIO.md, «Chiave del feed Windows». La verifica nell'app: FeedSignature.cs.
"""
import base64
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
APP_INFO = os.path.join(ROOT, "windows", "src", "Cornetta.App", "AppInfo.cs")
KEY_ENV = "CORNETTA_FEED_KEY_FILE"
# SubjectPublicKeyInfo DER di una chiave P-256 non compressa: questa intestazione, poi 0x04, X e Y.
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")


def fail(message):
    sys.exit(f"sign-feed: {message}")


def openssl(*args, data=None):
    result = subprocess.run(["openssl", *args], input=data, capture_output=True)
    if result.returncode != 0:
        fail(f"openssl {args[0]} non riuscito: {result.stderr.decode(errors='replace').strip()[-300:]}")
    return result.stdout


def embedded_public_key(app_info=None):
    """X||Y (64 byte) dalla riga UpdateFeedPublicKey di AppInfo.cs, o None se c'è ancora il segnaposto."""
    path = app_info or os.environ.get("CORNETTA_APP_INFO") or APP_INFO
    with open(path, encoding="utf-8") as f:
        match = re.search(r'UpdateFeedPublicKey\s*=\s*(?:"([0-9A-Fa-f]*)"|FeedSignature\.Placeholder)\s*;', f.read())
    if not match:
        fail(f"UpdateFeedPublicKey non trovata in {path}")
    if match.group(1) is None:
        return None
    key = bytes.fromhex(match.group(1))
    if len(key) != 64:
        fail("UpdateFeedPublicKey deve avere 128 cifre esadecimali (X||Y)")
    return key


def key_file():
    """Il percorso della chiave privata, dopo i controlli: esiste, sta fuori dal repo, la legge solo il proprietario."""
    path = os.environ.get(KEY_ENV, "")
    if not path:
        fail(f"manca {KEY_ENV}: il percorso del file con la chiave privata del feed (docs/SERVIZIO.md)")
    path = os.path.realpath(os.path.expanduser(path))
    if not os.path.isfile(path):
        fail(f"{KEY_ENV} non indica un file esistente")
    if path == ROOT or path.startswith(ROOT + os.sep):
        fail("la chiave privata sta dentro il repo: spostala fuori (il repo è pubblico)")
    if os.name == "posix" and os.stat(path).st_mode & 0o077:
        fail("la chiave privata è leggibile da altri utenti: chmod 600")
    return path


def public_key_of(path):
    spki = openssl("pkey", "-in", path, "-pubout", "-outform", "DER")
    if not spki.startswith(P256_SPKI_PREFIX) or len(spki) != len(P256_SPKI_PREFIX) + 65 or spki[len(P256_SPKI_PREFIX)] != 4:
        fail("la chiave privata non è ECDSA P-256")
    return spki[len(P256_SPKI_PREFIX) + 1:]


def der_to_raw(der):
    """Firma DER (SEQUENCE di due INTEGER) → r||s di 32 byte ciascuno, il formato di .NET (IEEE P1363)."""
    def integer(buf, i):
        if buf[i] != 0x02:
            fail("firma DER inattesa")
        length = buf[i + 1]
        value = buf[i + 2:i + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            fail("firma DER inattesa")
        return value.rjust(32, b"\x00"), i + 2 + length

    if der[0] != 0x30:
        fail("firma DER inattesa")
    start = 3 if der[1] & 0x80 else 2
    r, i = integer(der, start)
    s, _ = integer(der, i)
    return r + s


def raw_to_der(raw):
    def integer(value):
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return bytes([0x02, len(value)]) + value

    body = integer(raw[:32]) + integer(raw[32:])
    return bytes([0x30, len(body)]) + body


def verify(feed_path, sig_path, public_key):
    """Vero se SIG (base64 di r||s) è una firma valida di FEED per la chiave pubblica X||Y."""
    try:
        raw = base64.b64decode(open(sig_path, "rb").read().strip(), validate=True)
    except ValueError:
        return False
    if len(raw) != 64:
        return False
    with tempfile.TemporaryDirectory() as tmp:
        pub, der = os.path.join(tmp, "pub.der"), os.path.join(tmp, "sig.der")
        open(pub, "wb").write(P256_SPKI_PREFIX + b"\x04" + public_key)
        open(der, "wb").write(raw_to_der(raw))
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-keyform", "DER", "-signature", der, feed_path],
                                capture_output=True)
        return result.returncode == 0


def checked_key():
    path = key_file()
    mine, embedded = public_key_of(path), embedded_public_key()
    if embedded is None:
        fail("in AppInfo.cs UpdateFeedPublicKey è ancora il segnaposto: metti la chiave pubblica (--public-key) e pubblica l'app")
    if mine != embedded:
        fail("la chiave privata non corrisponde a UpdateFeedPublicKey dell'app: le app installate rifiuterebbero il feed")
    return path, mine


def sign(feed_path):
    path, public_key = checked_key()
    with tempfile.TemporaryDirectory() as tmp:
        der = os.path.join(tmp, "sig.der")
        openssl("dgst", "-sha256", "-sign", path, "-out", der, feed_path)
        raw = der_to_raw(open(der, "rb").read())
    sig_path = feed_path + ".sig"
    with open(sig_path, "w", encoding="ascii") as f:
        f.write(base64.b64encode(raw).decode("ascii") + "\n")
    if not verify(feed_path, sig_path, public_key):
        fail("la firma appena scritta non si verifica")
    print(f"→ firmato {os.path.basename(feed_path)} ({os.path.basename(sig_path)})")


def main():
    args = sys.argv[1:]
    if args == ["--check-key"]:
        checked_key()
        print("→ chiave del feed pronta")
    elif args == ["--public-key"]:
        print(public_key_of(key_file()).hex())
    elif len(args) == 3 and args[0] == "--verify":
        embedded = embedded_public_key()
        if embedded is None or not verify(args[1], args[2], embedded):
            fail(f"firma non valida per {args[1]}")
        print("→ firma del feed valida")
    elif len(args) == 1 and not args[0].startswith("-"):
        sign(args[0])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
