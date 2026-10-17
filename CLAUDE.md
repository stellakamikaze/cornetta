# Cornetta

Registratore di chiamate gratuito e open source: app Mac (Swift, `Sources/`), app Windows in beta (.NET Framework 4.8, `windows/`), sito e servizi su un Cloudflare Worker (`worker/`). Testi e commenti in italiano. Il taglio di prodotto sta in `PRODUCT.md`, il servizio in `docs/SERVIZIO.md`.

## Comandi

```bash
scripts/test.sh                                  # test Mac (Core e app)
cd windows && dotnet test Cornetta.Windows.sln   # test Windows, girano anche su Mac
python3 -m unittest discover -s scripts/tests   # test degli script (publish, firma, feedback)
scripts/deploy-site.sh                           # pagine e Worker, da qualunque macchina
scripts/release.sh X.Y.Z "novità" …              # versione Mac: solo da un Mac col certificato
windows/tools/publish.sh X.Y.Z                   # versione Windows, dopo la CI sul tag win-vX.Y.Z
scripts/feedback.py · scripts/telemetria.py      # feedback e dati di funzionamento
```

## Regole

- Un dato nuovo che parte dall'app o dal Worker entra prima in `/privacy/`, `/en/privacy/` e `llms.txt`, poi nel codice.
- La telemetria accetta solo eventi e valori a lista chiusa (`validateTelemetry`): niente testo libero, niente nomi di file o dispositivi.
- Ogni guasto trovato su una macchina vera diventa un controllo in CI o nei test prima del rilascio successivo.

## Errori comuni

- NON pubblicare con `wrangler deploy` a mano: toglie dal sito DMG e feed Windows, che non stanno in git. Usa `scripts/deploy-site.sh`.
- NON rigenerare la chiave EdDSA di Sparkle né il certificato «Cornetta Self-Signed»: le app installate rifiutano gli aggiornamenti o perdono i permessi. Si ripristinano dal backup.
- NON attivare il runtime rinforzato col certificato locale: senza Team ID Sparkle non si carica. Serve solo con un Developer ID.
- NON mettere `kAudioAggregateDeviceTapAutoStartKey` a true: su macOS 26 l'aggregate col tap non parte (zero callback).
- NON leggere il JSON delle trascrizioni col decoder di default: le date sono ISO 8601 e tutto risulta «Da trascrivere». Usa `Transcript.decoder`.
- NON aprire una finestra in `applicationDidFinishLaunching` di un'app MenuBarExtra: non arriva sullo schermo. Aprila dopo, con `asyncAfter` di 0,5 s.
- NON premere i pulsanti di Sparkle con `click` di System Events nelle prove: blocca osascript. Usa `perform action "AXPress"`.
- NON usare i dispositivi predefiniti generali su Windows: le chiamate passano da quelli del ruolo Comunicazioni.
- NON fidarti di selftest e `--render-ui` per l'avvio su Windows: non passano dal costruttore di `TrayApp`. La CI prova l'app vera con `--smoke-tray`.
- NON aspettarti che una build di prova Windows (0.0.<run>) scarichi il feed pubblicato: Velopack rifiuta una versione più bassa.
- NON verificare un deploy al primo colpo: per qualche secondo Cloudflare può servire i file vecchi o un 404. Gli script riprovano sei volte.
- NON compilare l'app col Command Line Tools 27 senza Xcode: manca il plugin delle macro di SwiftUI («SwiftUIMacros not found»). Core e test compilano.
