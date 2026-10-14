#!/usr/bin/env python3
"""Genera le icone Windows di Cornetta dal PNG 1024x1024 del Mac (build/icon.png, da scripts/make-icon.swift).

Uso: python3 windows/tools/make-icons.py [icon.png]
Scrive in windows/src/Cornetta.App/Assets/:
  icon.png            copia del sorgente, per rigenerare senza Mac
  cornetta.ico        icona dell'app e dell'installer (16-256 px)
  tray-idle.ico       area di notifica, a riposo
  tray-recording.ico  area di notifica, in registrazione (pallino rosso)
  tray-update.ico     area di notifica, aggiornamento disponibile (pallino blu)
Serve Pillow (pip install pillow).
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "src", "Cornetta.App", "Assets")
APP_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
TRAY_SIZES = [16, 20, 24, 32, 40, 48, 64]
RED = (212, 42, 31, 255)       # --rec della pagina di download
BLUE = (31, 95, 214, 255)      # --focus della pagina di download


def squared(source: Image.Image) -> Image.Image:
    """Toglie il margine della griglia macOS (100 px su 1024): su Windows l'icona riempie il quadrato."""
    crop = source.crop((84, 84, 940, 940))
    return crop.resize((1024, 1024), Image.LANCZOS)


def badge(base: Image.Image, color) -> Image.Image:
    """Pallino in basso a destra con bordo bianco, leggibile anche a 16 px."""
    image = base.copy()
    draw = ImageDraw.Draw(image)
    size = image.size[0]
    d = int(size * 0.46)
    x0 = size - d
    y0 = size - d
    draw.ellipse((x0, y0, size - 1, size - 1), fill=(255, 255, 255, 255))
    inset = int(d * 0.16)
    draw.ellipse((x0 + inset, y0 + inset, size - 1 - inset, size - 1 - inset), fill=color)
    return image


def recording_dot() -> Image.Image:
    """Pallino rosso pieno con bordo bianco: come il pallino nella barra dei menu del Mac."""
    size = 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse((40, 40, size - 40, size - 40), fill=(255, 255, 255, 255))
    draw.ellipse((150, 150, size - 150, size - 150), fill=RED)
    return image


def save_ico(image: Image.Image, name: str, sizes) -> None:
    path = os.path.join(ASSETS, name)
    image.save(path, format="ICO", sizes=[(s, s) for s in sizes])
    print("scritto", os.path.relpath(path))


def main() -> None:
    source_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ASSETS, "icon.png")
    source = Image.open(source_path).convert("RGBA")
    if source.size != (1024, 1024):
        source = source.resize((1024, 1024), Image.LANCZOS)
    os.makedirs(ASSETS, exist_ok=True)
    if os.path.abspath(source_path) != os.path.abspath(os.path.join(ASSETS, "icon.png")):
        source.save(os.path.join(ASSETS, "icon.png"))
    app = squared(source)
    save_ico(app, "cornetta.ico", APP_SIZES)
    save_ico(app, "tray-idle.ico", TRAY_SIZES)
    save_ico(recording_dot(), "tray-recording.ico", TRAY_SIZES)
    save_ico(badge(app, BLUE), "tray-update.ico", TRAY_SIZES)


if __name__ == "__main__":
    main()
