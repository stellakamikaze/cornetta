# Manuale del servizio

Cosa gira dietro Cornetta, dove sta, e come si rimette in piedi se si perde. I valori dei segreti non stanno qui: li tiene il gestore password di chi mantiene il progetto.

## Mappa

```
app Mac (Sparkle) ──┐                      ┌── worker/public  (pagine, appcast.xml, _redirects: in git)
app Windows (Velopack)┤                    │   downloads/     (DMG, delta, note, latest.json: FUORI da git)
browser ────────────┼──► Worker «cornetta» ┤   windows/       (installer, nupkg, feed Velopack: FUORI da git)
                    │   (Cloudflare)       │
                    │                      ├── D1  cornetta-telemetria   ◄── POST /api/t
                    │                      ├── KV  FEEDBACK               ◄── POST /api/feedback
                    │                      ├── Telegram (segreti)         ◄── download e feedback
                    │                      └── Plausible (server esterno) ◄── /js/p.js, /api/e, /download
                    └── GitHub: codice, release con DMG e installer, CI Windows
```

Se Telegram o Plausible non rispondono il sito funziona lo stesso: gli avvisi e le statistiche si perdono, i download no.

## Worker e dominio

- Configurazione: `worker/wrangler.toml`. Dominio `cornetta.stellakamikaze.org` come custom domain: la zona `stellakamikaze.org` deve stare sullo stesso account Cloudflare.
- Pubblicare le pagine: `scripts/deploy-site.sh`. Mai `wrangler deploy` a mano: pubblica tutta `worker/public`, e `downloads/` e `windows/` non stanno in git. Lo script li riscarica dal sito con `scripts/sync-published.py`, si ferma se ne manca uno (`--check`) e dopo il deploy controlla che il sito li serva ancora (`--verify`).
- Pubblicare una versione: `scripts/release.sh` (Mac, solo da un Mac col certificato) e `windows/tools/publish.sh` (Windows, dopo la CI). Partono anche loro dai file pubblicati.

## Dati

| Risorsa | Binding | Contenuto | Durata | Lettura |
|---|---|---|---|---|
| D1 `cornetta-telemetria` | `TELEMETRY` | eventi di funzionamento, tabella `eventi` | 12 mesi, cron notturno `17 3 * * *` | `scripts/telemetria.py` |
| KV `FEEDBACK` | `FEEDBACK` | feedback dall'app | 90 giorni (`KEEP_SECONDS`) | `scripts/feedback.py` |
| Rate limit | `TELEMETRY_LIMIT` | 60 eventi al minuto per IP | — | — |

Ricreare da zero (i dati vecchi non tornano):

```bash
cd worker
npx wrangler@4 d1 create cornetta-telemetria          # copia il nuovo database_id in wrangler.toml
npx wrangler@4 d1 migrations apply cornetta-telemetria --remote
npx wrangler@4 kv namespace create FEEDBACK           # copia il nuovo id in wrangler.toml
```

Il rate limit non va creato: basta il blocco `[[ratelimits]]` in `wrangler.toml`.

## Segreti del Worker

| Nome | A cosa serve | Se manca |
|---|---|---|
| `TELEGRAM_TOKEN` | token del bot che manda gli avvisi | nessun avviso, il resto funziona |
| `TELEGRAM_CHAT` | chat che riceve gli avvisi | nessun avviso, il resto funziona |

```bash
cd worker && npx wrangler@4 secret put TELEGRAM_TOKEN   # incolla il valore quando lo chiede
```

Prova: `npx wrangler@4 tail cornetta` mentre scarichi la pagina da un browser vero. Nel log compare «Telegram: messaggio N inviato». Lo stesso IP manda un solo avviso l'ora per piattaforma.

## File pubblicati persi

Se il sito perde DMG o feed e nessuna macchina li ha più:

1. DMG: `gh release download vX.Y.Z` per ogni versione, in `worker/public/downloads/`.
2. Installer Windows: `windows/tools/publish.sh X.Y.Z` riscarica dalla CI l'ultima versione e la ripubblica.
3. `latest.json` lo riscrivono `release.sh` e `publish.sh`. I delta li rigenera `generate_appcast` alla release successiva.

## Chiavi di firma (solo Mac)

- **Chiave EdDSA di Sparkle**: firma il feed degli aggiornamenti. La privata sta nel portachiavi del Mac che pubblica, account `cornetta`. La pubblica è in `Resources/Info.plist` (`SUPublicEDKey`). Se si perde, le app installate rifiutano ogni aggiornamento futuro: va ripristinata dal backup, mai rigenerata. Ripristino: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account cornetta -f <file>`. Esporta il backup con `-x <file>`.
- **Certificato «Cornetta Self-Signed»**: firma l'app. Sta nel portachiavi login. `release.sh` si ferma se la firma è diversa. macOS lega i permessi (microfono, audio di sistema) al certificato: con un certificato nuovo chi aggiorna deve concederli di nuovo. Va ripristinato dal backup `.p12`, mai rifatto.

## Distribuzione

- **Homebrew**: tap `stellakamikaze/homebrew-tap`, file `Casks/cornetta.rb`. `release.sh` aggiorna versione e SHA-256. Homebrew ufficiale non accetta app che non passano Gatekeeper, quindi c'è solo il tap.
- **winget**: manifest in `windows/winget/`, validato con `winget validate`. L'inserimento passa da una PR a `microsoft/winget-pkgs`.
- **Ricerca**: sitemap in `worker/public/sitemap.xml`, chiave IndexNow nel file `.txt` di 32 caratteri esadecimali in `worker/public/`.

## Statistiche delle visite

Plausible gira su un server esterno (`PLAUSIBLE` in `worker/src/index.js`). Il Worker serve lo script da `/js/p.js` e gli eventi da `/api/e`, e passa l'IP vero in `X-Plausible-IP`. `/download` e `/download/windows` mandano l'evento «Download» dal server. Plausible ignora i browser automatici: per provarlo serve un POST diretto a `/api/e`.

## Privacy

Le pagine `/privacy/` e `/en/privacy/` elencano ogni dato che parte. Se cambia un campo della telemetria, del feedback o degli avvisi, cambiano anche quelle pagine e `llms.txt`.
