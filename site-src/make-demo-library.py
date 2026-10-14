#!/usr/bin/env python3
"""Crea una libreria dimostrativa per Cornetta (--demo-library) con un dialogo sintetico a due voci.
Uso: python3 site-src/make-demo-library.py <cartella>
Le voci sono quelle di sistema di macOS (Alice = Altri, Eddy = Tu). Nessuna registrazione vera."""
import os, subprocess, sys, tempfile

root = sys.argv[1]
DIALOGO = [
    ("altri", "Ciao! Ti sento benissimo. Allora, confermiamo l'intervista per giovedì?"),
    ("tu", "Sì, giovedì alle dieci va bene. Ti mando le domande entro domani sera."),
    ("altri", "Perfetto. Registriamo da remoto o vieni in studio?"),
    ("tu", "Da remoto. Uso Cornetta, così ho subito anche la trascrizione."),
    ("altri", "Ottimo. Allora a giovedì, buona giornata!"),
    ("tu", "A giovedì, ciao!"),
]
VOCE = {"altri": "Alice", "tu": "Eddy (Italiano (Italia))"}

def run(*a):
    subprocess.run(a, check=True, capture_output=True)

def make_call(name, dialog, tmp):
    rec_dir = os.path.join(root, "Registrazioni"); os.makedirs(rec_dir, exist_ok=True)
    tracks = os.path.join(root, "Supporto", "Tracce", name); os.makedirs(tracks, exist_ok=True)
    t = 1.0; parts = {"tu": [], "altri": []}
    for i, (who, line) in enumerate(dialog):
        f = os.path.join(tmp, f"{name}-{i}.aiff")
        run("say", "-v", VOCE[who], "-o", f, line)
        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f],
                                   capture_output=True, text=True).stdout)
        parts[who].append((f, t)); t += dur + 0.6
    total = t + 1
    for who in ("tu", "altri"):
        inputs, filters = [], []
        for j, (f, start) in enumerate(parts[who]):
            inputs += ["-i", f]
            filters.append(f"[{j}:a]aresample=16000,adelay={int(start*1000)}|{int(start*1000)}[a{j}]")
        mix = "".join(f"[a{j}]" for j in range(len(parts[who])))
        graph = ";".join(filters) + f";{mix}amix=inputs={len(parts[who])}:normalize=0,apad=whole_dur={total},atrim=0:{total}"
        run("ffmpeg", "-y", *inputs, "-filter_complex", graph, "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "48k",
            os.path.join(tracks, f"{who}.m4a"))
    run("ffmpeg", "-y", "-i", os.path.join(tracks, "tu.m4a"), "-i", os.path.join(tracks, "altri.m4a"),
        "-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0,aresample=48000", "-ac", "2", "-c:a", "aac", "-b:a", "128k",
        os.path.join(rec_dir, name + ".m4a"))

with tempfile.TemporaryDirectory() as tmp:
    make_call("Chiamata 2026-10-14 15.30", DIALOGO, tmp)
    make_call("Chiamata 2026-10-13 11.05", [
        ("altri", "Buongiorno, la chiamo dallo studio per l'appuntamento di lunedì."),
        ("tu", "Buongiorno. Lunedì alle nove per me va benissimo."),
        ("altri", "Bene, allora la segno. Arrivederci."),
    ], tmp)
print("ok", root)
