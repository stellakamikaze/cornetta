# Design

Pagina pubblica `worker/public/index.html` (e `/en/`): lo standard delle app per Mac, scelto da Federico il 14/10/2026 sulla pagina di confronto. Riferimenti di finitura: CleanShot X, Raycast. Scritto dal codice costruito (`assets/site.css`).

## Colori
- `--bg #ffffff`, `--bg-soft #f5f5f7` (sezioni alterne, riquadri delle immagini), `--bg-deep #ececf0`
- `--ink #1d1d1f`, `--ink-2 #5f5f66`, `--line #e3e3e8`
- `--accent #d42a1f` (rosso dell'icona): solo pulsanti di download, pallini delle liste, icone dei dettagli
- Livelli dell'app: `--blue #2f6fe4` (Tu), `--green #2f9e4f` (Altri)
- Avviso giallo per i passaggi di macOS: fondo `#fff7e0`, testo `#5c4400`

## Tipografia
Font di sistema (SF Pro sul Mac). Titoli 800, interlinea 1.02-1.06, tracking -0.03/-0.035em, `clamp()` fino a 80 px nel titolo principale. Testo 18 px, interlinea 1.6, secondario in `--ink-2`.

## Componenti
- Barra di navigazione fissa, sfocata, con bordo solo dopo lo scorrimento.
- Pulsante primario a pillola rosso con ombra colorata; secondario grigio chiaro.
- Scena della prima schermata: porzione di desktop (barra dei menu disegnata in CSS) con gli screenshot reali del pannello e dell'avviso, presi con `Cornetta --demo`.
- Funzioni in righe alterne testo/immagine; dettagli in elenco a tre colonne con icone a tratto, senza schede.
- Passi di installazione numerati con filetto superiore, tasti in stile `.key`.
- FAQ con `details/summary`, chevron disegnato in CSS.

## Movimento
Solo micro-transizioni (pulsanti, chevron, bordo della barra). Disattivate con prefers-reduced-motion.

## Vincoli tecnici
Niente stili o script inline: la CSP ammette solo `/assets/site.css` e `/assets/site.js`. Versione, peso e SHA-256 arrivano da `/downloads/latest.json`.
