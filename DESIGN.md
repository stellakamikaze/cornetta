# Design

Mondo visivo della pagina di download (`worker/public/index.html`): la copertina di una musicassetta registrata in casa. Scritto dopo la costruzione, dal codice.

## Colori
- `--paper #f6f7f9` fondo pagina · `--card #ffffff` copertina
- `--ink #14213a` testo e dorso · `--ink-2 #435069` testo secondario · `--rule #d5dbe5` righe fra tracce
- Fascia a righe: `--stripe-1 #e5432d`, `--stripe-2 #f08a24`, `--stripe-3 #f5c22e` (il giallo anche per selezione ed etichette sul fondo scuro)
- `--rec #d42a1f` / `--rec-deep #9e1c14`: solo il tasto di download e il simbolo REC
- `--focus #1f5fd6` anello di focus

## Tipografia
- Etichette e titoli: Barlow Condensed 600/700, maiuscolo, self-hosted in `fonts/`
- Testo: font di sistema, 19 px, interlinea 1.55, misura massima 62ch

## Componenti
- Dorso verticale (orizzontale sotto 860 px) con «Lato A installa · Lato B usa»
- Lati A e B: cerchio con la lettera, titolo condensato
- Traccia: numero o simbolo, titolo, testo; nel Lato A durata in cifre tabulari con barra lunga quanto il tempo
- Tasto REC: rosso pieno con ombra solida sotto, si abbassa di 5 px quando lo premi
- Tasto `.key`: bordo 1 px, ombra di 1,5 px per la profondità
- Retro (flap): fondo inchiostro, tre colonne Privacy, Legalità, Requisiti

## Movimento
Uno solo: il tasto REC si abbassa e il pallino lampeggia a download avviato, poi la pagina scorre al passo 2. Disattivato con prefers-reduced-motion.
