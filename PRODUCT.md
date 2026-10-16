# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (pagina di download). Le app sono native: macOS (SwiftUI, barra dei menu) e Windows in beta (.NET Framework 4.8, area di notifica).

## Stack

Delegato (inferito dal brief, Federico ha detto «procedi»): HTML/CSS statico in `worker/public/`, servito da un Cloudflare Worker con static assets.

## Users

Chiunque abbia bisogno di registrare una chiamata dal computer, su Mac o su Windows. Molti non sono tecnici: arrivano dal link di un amico, da una ricerca o da una lista di app. Aprono il link dal Mac o dal telefono, scaricano un DMG o un installer e installano un'app non notarizzata. [Inferito]

## Product Purpose

Cornetta registra le chiamate dal computer con qualunque app (WhatsApp, FaceTime, Meet, Zoom, Teams): la voce di chi registra dal microfono e la voce degli altri dall'audio di sistema, in un file `.m4a`. Sul Mac trascrive la chiamata sul computer. Gratuita, open source (MIT), si aggiorna da sola. Successo della pagina: la persona installa e concede i permessi senza chiamare Federico.

## Positioning

Un software gratis e open source per fare una cosa semplice che serve a tutti: registrare una chiamata (Federico, 15/10/2026). Il resto viene da lì: nessun driver audio virtuale da installare, nessun account, nessun abbonamento, un'icona nella barra dei menu e un clic per registrare. Propone da sola di registrare quando parte una chiamata. Ogni testo, dal sito ai post di lancio, parte da questo taglio: niente toni da prodotto premium, niente funzioni elencate per stupire.

## Capabilities and Constraints

- Mac: macOS 14.4 o successivo, Apple Silicon e Intel. App non notarizzata: al primo avvio macOS la blocca e serve «Apri comunque» in Impostazioni di Sistema → Privacy e sicurezza. Due permessi: Microfono, Registrazione audio di sistema. Si installa anche con Homebrew (`brew install --cask stellakamikaze/tap/cornetta`), solo dal tap personale: Homebrew ufficiale non accetta app non notarizzate.
- Trascrizione sul Mac, solo con macOS 26: righe «Tu» e «Altri» dalle due tracce, file Markdown accanto all'audio.
- Windows (beta): Windows 10 e 11, installer per utente senza permessi di amministratore. L'installer non è firmato: SmartScreen chiede «Ulteriori informazioni → Esegui comunque». Niente trascrizione. La homepage propone Windows finché `latest.json` ha la voce `windows`.
- Telefoni esclusi: iOS non dà l'audio delle chiamate, Android lo blocca dalla 10.
- Aggiornamenti automatici (Sparkle sul Mac, Velopack su Windows) con avviso in primo piano.
- Pulsante Feedback nell'app.
- Dati che partono, tutti dichiarati in `/privacy/`: visite al sito con Plausible senza cookie, dati di funzionamento dell'app (accesi di default, si spengono dal menu), feedback solo su richiesta, un avviso Telegram a Federico per ogni download e ogni feedback. Se cambia uno di questi, cambia anche la pagina privacy.

## Evidence on Hand

Icona dell'app (`build/icon.png`), screenshot in `worker/public/img/`. Download e avvii veri si leggono da Plausible e da `scripts/telemetria.py`. Nessuna testimonianza: non inventarle, e non citare numeri di utenti che non vengono da quelle due fonti.

## Product Principles

- Chi installa non deve sapere cos'è un DMG: ogni passo dice cosa vedrà sullo schermo.
- Onestà sul blocco di macOS: lo si spiega prima che spaventi.
- La privacy è un fatto: registrazioni e trascrizioni restano sul computer, e ogni dato che parte è scritto nella pagina privacy.

## Accessibility & Inclusion

Pubblico anche anziano o poco pratico: testo grande, contrasto alto, passi numerati, niente gergo. [Inferito]
