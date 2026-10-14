# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (pagina di download); l'app è nativa macOS (SwiftUI, barra dei menu).

## Stack

Delegato (inferito dal brief, Federico ha detto «procedi»): HTML/CSS statico in `worker/public/`, servito da un Cloudflare Worker con static assets.

## Users

Persone non tecniche che ricevono il link da Federico, per esempio familiari e colleghi (la prima è Liliana). Aprono il link dal Mac o dal telefono, scaricano un DMG e installano un'app non notarizzata. [Inferito]

## Product Purpose

Cornetta registra le chiamate dal Mac con qualunque app (WhatsApp, FaceTime, Meet, Zoom, Teams): la voce di chi registra dal microfono e la voce degli altri dall'audio di sistema, in un file `.m4a`. Gratuita, si aggiorna da sola. Successo della pagina: la persona installa e concede i permessi senza chiamare Federico.

## Positioning

Nessun driver audio virtuale da installare, nessun account, nessun abbonamento: un'icona nella barra dei menu, un clic per registrare. Propone da sola di registrare quando parte una chiamata.

## Capabilities and Constraints

- macOS 14.4 o successivo, Mac Apple Silicon e Intel.
- App non notarizzata: al primo avvio macOS la blocca e serve «Apri comunque» in Impostazioni di Sistema → Privacy e sicurezza.
- Due permessi: Microfono, Registrazione audio di sistema.
- Aggiornamenti automatici (Sparkle) con avviso in primo piano.
- Pulsante Feedback nell'app.

## Evidence on Hand

Icona dell'app (`build/icon.png`). Nessuna testimonianza, nessun numero di utenti: non inventarli.

## Product Principles

- Chi installa non deve sapere cos'è un DMG: ogni passo dice cosa vedrà sullo schermo.
- Onestà sul blocco di macOS: lo si spiega prima che spaventi.
- La privacy è un fatto: i file restano sul Mac.

## Accessibility & Inclusion

Pubblico anche anziano o poco pratico: testo grande, contrasto alto, passi numerati, niente gergo. [Inferito]
