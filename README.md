# Cornetta

Registratore di chiamate gratuito per Mac. Registra in un solo file la tua voce dal microfono e la voce delle altre persone, con qualunque app: Meet, Zoom, Teams, WhatsApp, FaceTime, Slack, Discord, il browser.

Cornetta vive nella barra dei menu. Un clic avvia la registrazione, un clic la ferma. Il file finisce in `~/Music/Cornetta/` con il nome `Chiamata AAAA-MM-GG HH.MM.m4a`.

## Requisiti

- macOS 14.4 o successivo.
- Mac con Apple Silicon (M1 e successivi).

## Installazione

1. Apri `Cornetta.dmg` e trascina Cornetta nella cartella Applicazioni.
2. Al primo avvio macOS blocca l'app, perché non è firmata da uno sviluppatore Apple registrato. Apri **Impostazioni di Sistema → Privacy e sicurezza**, scorri in fondo e premi **Apri comunque**.
3. Alla prima registrazione Cornetta chiede due permessi. Concedili entrambi:
   - **Microfono**, per la tua voce;
   - **Registrazione audio di sistema**, per la voce degli altri.

Se hai negato un permesso, riattivalo in **Impostazioni di Sistema → Privacy e sicurezza → Microfono** oppure **→ Registrazione schermo e audio di sistema**.

## Uso

- **Avvia registrazione** (⌘R): l'icona diventa un pallino rosso con il tempo trascorso.
- **Ferma registrazione** (⌘R): il file viene chiuso e salvato.
- **Apri cartella registrazioni**: apre `~/Music/Cornetta/` nel Finder.

Se a metà chiamata cambi microfono (per esempio colleghi le AirPods), Cornetta passa al nuovo microfono e continua sullo stesso file.

## Come funziona

Cornetta usa i *process tap* di Core Audio (macOS 14.2+): legge tutto l'audio che il Mac riproduce, senza driver virtuali come BlackHole e senza registrare lo schermo. Il tap e il microfono stanno nello stesso dispositivo aggregato privato, quindi le due voci condividono lo stesso orologio e restano sincronizzate.

Il file è AAC stereo a 48 kHz. La tua voce sta al centro, l'audio della chiamata mantiene il suo stereo. Un limitatore evita la distorsione quando parlate insieme.

## Compilare da sorgente

Bastano i Command Line Tools di Xcode (`xcode-select --install`).

```bash
scripts/test.sh          # test
scripts/build-dmg.sh     # produce dist/Cornetta.dmg
```

Per provare la cattura senza interfaccia:

```bash
open -W -n build/Cornetta.app --args --record 10 --out /tmp/prova.m4a --debug-tracks /tmp/prova
```

Il comando scrive `/tmp/prova.m4a`, le tracce separate `mic.wav` e `system.wav`, e le statistiche in `/tmp/prova.m4a.json`. Con `--cycles 3` registra tre volte di seguito nello stesso processo.

Se la registrazione resta muta, lancia la sonda e leggi il risultato:

```bash
open -W -n /Applications/Cornetta.app --args --probe /tmp/sonda.txt && cat /tmp/sonda.txt
```

Il log dell'app sta in `~/Library/Logs/Cornetta/cornetta.log`.

## Limiti noti

- L'app ha una firma ad-hoc: a ogni nuova versione macOS chiede di nuovo i due permessi.
- Con le AirPods come microfono la qualità della chiamata scende (profilo Bluetooth per le chiamate). Vale per qualunque registratore.
- La build universale (anche Mac Intel) richiede Xcode completo.

## Nota legale

In Italia registrare una conversazione a cui partecipi è lecito per uso personale. Diffonderla senza il consenso delle altre persone non lo è. In altri paesi le regole cambiano: informati prima di registrare.

## Licenza

MIT. Vedi `LICENSE`.
