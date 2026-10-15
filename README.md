# Cornetta

**Free, open-source call recorder for Mac, with a beta for Windows.** Cornetta records your voice from the microphone and the other people from system audio into one `.m4a` file, with any calling app: WhatsApp, FaceTime, Google Meet, Zoom, Microsoft Teams, Slack, Discord, browser calls. No account, no virtual audio driver, no subscription. On macOS 26 it also transcribes each call on the Mac, separating your voice from the others.

- Download: [cornetta.stellakamikaze.org](https://cornetta.stellakamikaze.org/en/) (macOS 14.4+, Apple Silicon and Intel · Windows 10 and 11, beta)
- Homebrew: `brew install --cask stellakamikaze/tap/cornetta`
- Privacy: recordings and transcripts never leave your computer. The app sends anonymous usage data that you can turn off: [what is sent](https://cornetta.stellakamikaze.org/en/privacy/)
- Stack: Swift and Core Audio process taps (`Sources/`), C# .NET Framework 4.8 with NAudio and Velopack (`windows/`), Cloudflare Worker for the site, updates, feedback and telemetry (`worker/`)
- License: MIT. Interface and code comments are in Italian.

---

Registratore di chiamate gratuito per Mac. Registra in un solo file la tua voce dal microfono e la voce delle altre persone, con qualunque app: Meet, Zoom, Teams, WhatsApp, FaceTime, Slack, Discord, il browser.

Cornetta vive nella barra dei menu. Un clic avvia la registrazione, un clic la ferma. Il file finisce in `~/Music/Cornetta/` con il nome `Chiamata AAAA-MM-GG HH.MM.m4a`.

## Requisiti

- macOS 14.4 o successivo.
- Mac con Apple Silicon o Intel (app universale).

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

## Trascrizione

Da macOS 26 Cornetta trascrive ogni chiamata sul Mac, con il riconoscimento vocale di Apple (SpeechAnalyzer): niente esce dal computer.

- Durante la registrazione salva due tracce separate in `~/Library/Application Support/Cornetta/Tracce/`: «Tu» (microfono) e «Altri» (audio di sistema). Le voci si attribuiscono dalla traccia, senza indovinare.
- Allo stop la trascrizione parte da sola. L'eco degli altoparlanti che rientra nel microfono viene tolta.
- Il testo si salva in JSON (`~/Library/Application Support/Cornetta/Trascrizioni/`) e come `.md` accanto all'audio.
- La finestra **Registrazioni** (⌘T dal menu) ha l'elenco, la ricerca, il testo diviso per voce e l'ascolto dal punto scelto.

Prova da riga di comando: `build/Cornetta.app/Contents/MacOS/Cornetta --transcribe file.m4a [--tracks cartella]`. Libreria dimostrativa: `python3 site-src/make-demo-library.py /tmp/demo && open -n build/Cornetta.app --args --demo-library /tmp/demo`.

## Come funziona

Cornetta usa i *process tap* di Core Audio (macOS 14.2+): legge tutto l'audio che il Mac riproduce, senza driver virtuali come BlackHole e senza registrare lo schermo. Il tap e il microfono stanno nello stesso dispositivo aggregato privato, quindi le due voci condividono lo stesso orologio e restano sincronizzate.

Il file è AAC stereo a 48 kHz. La tua voce sta al centro, l'audio della chiamata mantiene il suo stereo. Un limitatore evita la distorsione quando parlate insieme.

Durante la chiamata Cornetta non scrive ancora l'AAC: scrive file CAF in `~/Library/Application Support/Cornetta/In corso/`, che restano leggibili anche se il Mac si spegne o l'app si chiude di colpo. Allo stop li converte nel `.m4a` in `~/Music/Cornetta/` e svuota la cartella. Se all'avvio trova una cartella rimasta lì, recupera la registrazione interrotta e la mette in libreria. Lo stesso vale quando la registrazione si ferma per un errore del dispositivo audio: quello che era già registrato si salva e si trascrive.

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

- L'app non è notarizzata da Apple: al primo avvio serve «Apri comunque» in Impostazioni › Privacy e sicurezza. È firmata con un certificato proprio, sempre lo stesso: gli aggiornamenti non chiedono di nuovo i permessi.
- Con le AirPods come microfono la qualità della chiamata scende (profilo Bluetooth per le chiamate). Vale per qualunque registratore.

## Windows

La versione Windows sta in `windows/`. Fa le stesse cose della versione Mac: icona nell'area di notifica, pannello durante la registrazione, avviso quando parte una chiamata, feedback, aggiornamenti automatici.

### Installazione

1. Scarica `CornettaSetup.exe` da <https://cornetta.stellakamikaze.org/windows/CornettaSetup.exe> e aprilo. Non servono permessi di amministratore.
2. Al primo avvio Windows mostra «Windows ha protetto il PC», perché l'installer non è firmato. Premi **Ulteriori informazioni**, poi **Esegui comunque**.
3. Cornetta compare nell'area di notifica, vicino all'orologio. Se non la vedi, apri la freccia `^` accanto all'orologio.

Se il microfono resta muto, apri **Impostazioni → Privacy e sicurezza → Microfono** e attiva **Consenti alle app desktop di accedere al microfono**.

### Uso

- **Avvia registrazione** (Ctrl+Alt+R da qualunque app): l'icona diventa un pallino rosso e compare il pannello in alto a destra.
- **Ferma registrazione** (di nuovo Ctrl+Alt+R, oppure **Ferma** nel pannello): il file viene chiuso e salvato.
- I file finiscono in `Musica\Cornetta\` con il nome `Chiamata AAAA-MM-GG HH.MM.m4a`.

Il log sta in `%LOCALAPPDATA%\Cornetta\cornetta.log`.

### Come funziona

Cornetta legge l'audio di sistema con il loopback WASAPI e la tua voce dal microfono, usando l'uscita e il microfono che Windows assegna alle comunicazioni: sono quelli di Teams, Zoom, WhatsApp e del browser in chiamata. Se mancano, usa i predefiniti generali. Porta le due sorgenti a 48 kHz stereo e le mette su una linea del tempo comune, decisa da un orologio unico. Il loopback non manda pacchetti quando nessuno suona: Cornetta suona silenzio sull'uscita e riempie di zeri i buchi rimasti, così le due voci restano allineate. Il file è AAC 160 kbit/s con Media Foundation. Su Windows N senza Media Feature Pack Cornetta registra in WAV.

Le chiamate si riconoscono dalle sessioni audio attive sui microfoni e dal registro di Windows (`ConsentStore\microphone`): quando un'app diversa da Cornetta usa il microfono da almeno 4 secondi, compare l'avviso. Su Windows 24H2 il registro può restare fermo, perché Windows annota l'uso in un database che solo il sistema legge: per questo contano le sessioni audio.

### Compilare e provare

Serve il .NET SDK 10. L'app è per .NET Framework 4.8, già presente in Windows 10 e 11: il pacchetto pesa pochi MB e non installa runtime.

```bash
cd windows
dotnet test Cornetta.Windows.sln                 # test (anche su Mac e Linux)
dotnet build Cornetta.Windows.sln -c Release     # compila anche fuori da Windows, per controllo
```

Su un PC Windows:

```bat
Cornetta.exe --selftest                          :: dispositivi, encoder AAC, file di prova sintetico
Cornetta.exe --record 10 --out C:\prova.m4a      :: 10 secondi di cattura vera, statistiche in C:\prova.m4a.json
```

Il CI (`.github/workflows/windows.yml`) compila, esegue i test con .NET 10 e .NET Framework 4.8 e lancia `--selftest`. Poi controlla che il selftest sappia fallire (`--selftest-poison`, deve uscire con 1 e dire perché), disegna i pannelli (`--render-ui`) e avvia l'app vera (`--smoke-tray`): selftest e pannelli non passano dal costruttore dell'app, e un crash all'avvio arriverebbe agli utenti. Infine impacchetta con Velopack e prova l'installer. Le build di prova (versione 0.0.<run>) non scaricano il feed pubblicato, perché Velopack rifiuta una versione più bassa.

### Pubblicare una versione Windows

```bash
git tag win-v0.3.0 && git push origin win-v0.3.0   # il CI impacchetta la versione 0.3.0
gh run watch                                       # aspetta la run verde
windows/tools/publish.sh 0.3.0                     # copia in worker/public/windows/, deploy, verifica
```

Le app installate vedono la versione nuova all'avvio e ogni 4 ore.

### Limiti noti su Windows

- L'installer non è firmato: SmartScreen chiede «Ulteriori informazioni → Esegui comunque».
- Cornetta registra il microfono e l'uscita che Windows assegna alle comunicazioni. Se l'app di chiamata è impostata a mano su un altro dispositivo, quel dispositivo non entra nel file.
- `wrangler deploy` pubblica tutta `worker/public`: deploya solo da una macchina che ha anche `worker/public/windows/`.

## Notarizzazione Apple (installazione senza «Apri comunque»)

Oggi Cornetta è firmata con un certificato locale: macOS la blocca al primo avvio e chiede «Apri comunque». Con la notarizzazione Apple si apre con un doppio clic, come un'app dell'App Store. Serve l'[Apple Developer Program](https://developer.apple.com/programs/) (99 $ l'anno).

1. Iscriviti al programma come persona fisica. L'app mostrerà il tuo nome come sviluppatore.
2. Crea un certificato «Developer ID Application» e importalo nel portachiavi.
3. Salva le credenziali di notarizzazione, con una password specifica per app creata su appleid.apple.com:
   `xcrun notarytool store-credentials cornetta-notary --apple-id <email> --team-id <TEAMID>`
4. Pubblica come sempre, indicando certificato e profilo:
   `SIGN_IDENTITY="Developer ID Application: <Nome> (<TEAMID>)" NOTARY_PROFILE=cornetta-notary scripts/release.sh X.Y.Z "novità"`

Lo script attiva il runtime rinforzato, notarizza app e DMG e vi aggancia il ticket (`stapler`). Al primo aggiornamento dopo il passaggio, macOS chiede una volta sola di nuovo i due permessi, perché cambia il certificato.

## Nota legale

In Italia registrare una conversazione a cui partecipi è lecito per uso personale. Diffonderla senza il consenso delle altre persone non lo è. In altri paesi le regole cambiano: informati prima di registrare.

## Licenza

MIT. Vedi `LICENSE`.
