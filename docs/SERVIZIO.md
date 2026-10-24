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
- Pubblicare le pagine: `scripts/deploy-site.sh`. Mai `wrangler deploy` a mano: pubblica tutta `worker/public`, e `downloads/` e `windows/` non stanno in git. Lo script li riscarica dal sito con `scripts/sync-published.py`, si ferma se ne manca uno (`--check`) e dopo il deploy controlla che il sito li serva ancora, uguali a quelli locali (`--verify`).
- Prima di tutto i tre script passano da `scripts/lib/guardia.sh`, e si fermano se: il repo ha modifiche o file non tracciati; HEAD è staccato o il ramo non ha upstream; il ramo è indietro o ha commit non pushati; falliscono i test del Worker (con un Node 22.13 o più recente, cercato anche in Homebrew e nvm) o degli script; una migration di `worker/migrations/` non è applicata al D1.
- Pubblicare una versione: `scripts/release.sh` (Mac, solo da un Mac col certificato) e `windows/tools/publish.sh` (Windows, dopo la CI). Partono anche loro dai file pubblicati, e rifiutano una versione più vecchia di quella in `latest.json`. `publish.sh` pusha il suo commit di `_redirects` e allega alla release `win-vX.Y.Z` tutti i file del feed: è il loro backup. Se `release.sh` si ferma dopo il deploy, stampa i passi da finire a mano.

## Dati

| Risorsa | Binding | Contenuto | Durata | Lettura |
|---|---|---|---|---|
| D1 `cornetta-telemetria` | `TELEMETRY` | eventi di funzionamento, tabella `eventi` | 12 mesi, cron notturno `17 3 * * *` | `scripts/telemetria.py` |
| KV `FEEDBACK` | `FEEDBACK` | feedback dall'app | 90 giorni (`KEEP_SECONDS`) | `scripts/feedback.py` |
| Rate limit | `TELEMETRY_LIMIT` | 6 eventi al minuto per IPv4 o rete IPv6 /64 | — | — |
| Rate limit | `TELEMETRY48_LIMIT` | 30 eventi al minuto per rete IPv6 /48 (namespace 3004) | — | — |
| Rate limit | `FEEDBACK_LIMIT` | 2 feedback al minuto per IPv4 o /64 | — | — |
| Rate limit | `ALERT_LIMIT` | 2 avvisi Telegram al minuto per tipo (download, feedback) | — | — |

I rate limit usano come chiave un hash dell'indirizzo: l'IP non si salva. Contano per minuto e per località Cloudflare.
Nella tabella `eventi` resta un solo `avvio` per installazione al giorno (indice unico della migration 0002).

Una migration nuova in `worker/migrations/` va applicata **prima** del deploy del Worker che la usa, altrimenti la telemetria risponde 503. Gli script di deploy confrontano i file con la tabella `d1_migrations` e si fermano con questo comando:

```bash
cd worker && npx wrangler@4.147.0 d1 migrations apply cornetta-telemetria --remote
```

Ricreare da zero (i dati vecchi non tornano):

```bash
cd worker
npx wrangler@4.147.0 d1 create cornetta-telemetria          # copia il nuovo database_id in wrangler.toml
npx wrangler@4.147.0 d1 migrations apply cornetta-telemetria --remote
npx wrangler@4.147.0 kv namespace create FEEDBACK           # copia il nuovo id in wrangler.toml
```

Il rate limit non va creato: basta il blocco `[[ratelimits]]` in `wrangler.toml`.

## Segreti del Worker

| Nome | A cosa serve | Se manca |
|---|---|---|
| `TELEGRAM_TOKEN` | token del bot che manda gli avvisi | nessun avviso, il resto funziona |
| `TELEGRAM_CHAT` | chat che riceve gli avvisi | nessun avviso, il resto funziona |

```bash
cd worker && npx wrangler@4.147.0 secret put TELEGRAM_TOKEN   # incolla il valore quando lo chiede
```

Prova: `npx wrangler@4.147.0 tail cornetta` mentre scarichi la pagina da un browser vero. Nel log compare «Telegram: messaggio N inviato». Lo stesso IPv4 o la stessa rete IPv6 /64 manda un solo avviso l'ora per piattaforma, e sopra ogni tipo di avviso c'è il tetto di `ALERT_LIMIT` («Avviso download saltato» nel log).

## File pubblicati persi

Se il sito perde DMG o file Windows (per esempio dopo un `wrangler deploy` a mano), `sync-published.py` dice quale file manca. Se una macchina lo ha ancora in `worker/public`, basta `scripts/deploy-site.sh` da lì: i file solo in locale tornano online. Per i file senza versione nel nome (`latest.json`, feed Windows con la sua `.sig`, `RELEASES`, `assets.win.json`, `CornettaSetup.exe`) la sync invece si ferma, e con lei i tre script di deploy: la copia locale può essere più vecchia di quella persa. Controlla che sia l'ultima pubblicata (la versione in `latest.json` e nel feed, l'hash dell'installer nella release GitHub) o recuperala come sotto. Poi lancia a mano `python3 scripts/sync-published.py --recover`, che conferma le copie locali, e di nuovo lo script di deploy. La conferma vale solo per quelle copie: se il file locale cambia, la sync si ferma di nuovo. Se il feed Windows torna dalla copia locale, torna con la sua firma locale. I file mancanti si recuperano dalle release GitHub, poi `--recover` se servono file senza versione nel nome, e `scripts/deploy-site.sh`:

1. DMG: `gh release download vX.Y.Z -p '*.dmg' -D worker/public/downloads` per ogni versione citata dall'appcast o da `/download`.
2. File Windows: ogni release `win-vX.Y.Z` contiene anche i file senza versione nel nome, quindi scaricarne più di una nella stessa cartella va in conflitto. Per ogni versione citata dal feed scarica solo i pacchetti: `gh release download win-vX.Y.Z -p '*.nupkg' -D worker/public/windows`. Feed, `.sig`, `RELEASES`, `assets.win.json` e `CornettaSetup.exe` vengono solo dalla release dell'ultima versione citata dal feed, sopra le copie locali: `gh release download win-vX.Y.Z -p 'releases.win.json*' -p RELEASES -p assets.win.json -p CornettaSetup.exe -D worker/public/windows --clobber`. Le release fino a `win-v0.3.0` hanno solo l'installer: i nupkg e il feed stanno nell'artifact della CI (`gh run download <run> -n cornetta-windows-X.Y.Z`, poi `upload/*`), che scade 90 giorni dopo la run. Un feed senza `.sig` si firma con `windows/tools/sign-feed.py worker/public/windows/releases.win.json`.
3. I delta del Mac sono facoltativi: senza, Sparkle scarica il DMG intero. Li rigenera `generate_appcast` alla release successiva.
4. `latest.json` si copia da una macchina che ha fatto un deploy. Altrimenti si riscrive a mano nel formato di `release.sh` e `publish.sh`.

## Chiavi di firma

- **Chiave EdDSA di Sparkle**: firma il feed degli aggiornamenti. La privata sta nel portachiavi del Mac che pubblica, account `cornetta`. La pubblica è in `Resources/Info.plist` (`SUPublicEDKey`). Se si perde, le app installate rifiutano ogni aggiornamento futuro: va ripristinata dal backup, mai rigenerata. Ripristino: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account cornetta -f <file>`. Esporta il backup con `-x <file>`.
- **Chiave del feed Windows** (ECDSA P-256): firma `windows/releases.win.json` in `releases.win.json.sig`. L'app Windows verifica la firma prima di scaricare un aggiornamento (`FeedSignature.cs`) e senza firma valida non si aggiorna. Ed25519 non c'è in .NET Framework 4.8: ECDSA P-256 sì, senza librerie in più. La privata sta in un file PEM fuori dal repo, indicato da `CORNETTA_FEED_KEY_FILE`; `windows/tools/sign-feed.py` la legge dal file, si ferma se il file sta nel repo o è leggibile da altri, e confronta la sua chiave pubblica con quella dell'app. Se si perde, le app installate rifiutano ogni aggiornamento futuro: va ripristinata dal backup, mai rigenerata. Va creata **una volta sola**, prima della prima versione Windows con la verifica:

  ```bash
  mkdir -p ~/.config/cornetta && (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ~/.config/cornetta/feed-windows.pem)
  export CORNETTA_FEED_KEY_FILE=~/.config/cornetta/feed-windows.pem   # anche nel profilo della shell
  windows/tools/sign-feed.py --public-key                              # stampa solo la chiave pubblica
  ```

  La chiave pubblica va in `windows/src/Cornetta.App/AppInfo.cs`, `UpdateFeedPublicKey = "<128 cifre>"` al posto di `FeedSignature.Placeholder`: finché c'è il segnaposto, la CI dei tag si ferma. Il file PEM va nel gestore password (voce «Cornetta – chiave feed Windows»), poi `windows/tools/sign-feed.py --check-key` deve dire «chiave del feed pronta».
- **Certificato «Cornetta Self-Signed»**: firma l'app. Sta nel portachiavi login. `release.sh` si ferma se la firma è diversa. macOS lega i permessi (microfono, audio di sistema) al certificato: con un certificato nuovo chi aggiorna deve concederli di nuovo. Va ripristinato dal backup `.p12`, mai rifatto.

## Distribuzione

- **Homebrew**: tap `stellakamikaze/homebrew-tap`, file `Casks/cornetta.rb`. `release.sh` aggiorna versione e SHA-256. Homebrew ufficiale non accetta app che non passano Gatekeeper, quindi c'è solo il tap.
- **winget**: manifest in `windows/winget/`, validato con `winget validate`. L'inserimento passa da una PR a `microsoft/winget-pkgs`.
- **Ricerca**: sitemap in `worker/public/sitemap.xml`, chiave IndexNow nel file `.txt` di 32 caratteri esadecimali in `worker/public/`.

## Statistiche delle visite

Plausible gira su un server esterno (`PLAUSIBLE` in `worker/src/index.js`). Il Worker serve lo script da `/js/p.js` e gli eventi da `/api/e`, e passa l'IP vero in `X-Plausible-IP`. `/download` e `/download/windows` mandano l'evento «Download» dal server. Plausible ignora i browser automatici: per provarlo serve un POST diretto a `/api/e`.

## Privacy

Le pagine `/privacy/` e `/en/privacy/` elencano ogni dato che parte. Se cambia un campo della telemetria, del feedback o degli avvisi, cambiano anche quelle pagine e `llms.txt`.
