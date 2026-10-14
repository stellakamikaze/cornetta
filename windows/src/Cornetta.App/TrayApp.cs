using System;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using Cornetta.Core;
using Microsoft.Win32;

namespace Cornetta.App
{
    /// <summary>
    /// Cornetta nell'area di notifica: menu, registrazione, pannelli, rilevamento chiamate, aggiornamenti.
    /// Porta di RecorderModel.swift e CornettaApp.swift. Tutto gira sul thread dell'interfaccia,
    /// tranne avvio e stop della cattura (Task.Run).
    /// </summary>
    internal sealed class TrayApp : ApplicationContext
    {
        private static readonly TimeSpan UpdateInterval = TimeSpan.FromHours(4);

        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu = new ContextMenuStrip();
        private readonly Control invoker = new Control();
        private readonly Timer meterTimer = new Timer { Interval = 100 };
        private readonly Timer callTimer = new Timer { Interval = 2000 };
        private readonly Timer updateTimer = new Timer { Interval = (int)UpdateInterval.TotalMilliseconds };
        private readonly CallMonitor calls = new CallMonitor();
        private readonly UpdateService updates = new UpdateService();
        private readonly GlobalHotkey hotkey;

        private Recorder? recorder;
        private bool busy;
        private DateTime startedAt;
        private string? microphoneName;
        private string? message;
        private string? lastFile;
        private bool microphoneDenied;
        private bool callEndedSuggestion;

        private OverlayForm? overlay;
        private NoticeForm? notice;
        private Timer? noticeTimeout;
        private FeedbackForm? feedback;
        private string? pendingUpdateNotice;
        private bool installing;

        public TrayApp(bool firstRun)
        {
            invoker.CreateControl();
            tray = new NotifyIcon { Icon = TrayIcons.Idle, Text = "Cornetta", ContextMenuStrip = menu, Visible = true };
            tray.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) ShowMenu(); };
            tray.BalloonTipClicked += (_, __) => RevealLastFile();
            menu.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
            BuildMenu();

            meterTimer.Tick += (_, __) => Tick();
            callTimer.Tick += (_, __) => PollCalls();
            callTimer.Start();
            updateTimer.Tick += async (_, __) => await CheckUpdates(manual: false);
            updateTimer.Start();
            hotkey = new GlobalHotkey(Toggle);
            // Spegnimento, disconnessione e sospensione: il file va chiuso prima, o resta illeggibile.
            SystemEvents.SessionEnding += OnSessionEnding;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;

            // Un controllo all'avvio, oltre a quelli ogni 4 ore: chi apre l'app scopre subito la novità.
            var startupCheck = new Timer { Interval = 5000 };
            startupCheck.Tick += async (_, __) => { startupCheck.Stop(); startupCheck.Dispose(); await CheckUpdates(manual: false); };
            startupCheck.Start();

            if (firstRun)
            {
                tray.ShowBalloonTip(10_000, "Cornetta è pronta",
                    "La trovi qui, nell'area di notifica vicino all'orologio. Un clic sull'icona apre il menu.", ToolTipIcon.Info);
            }
        }

        private bool IsRecording => recorder != null;

        private string ElapsedText => TimeText.Elapsed(IsRecording ? DateTime.UtcNow - startedAt : TimeSpan.Zero);

        // MARK: - Menu

        private void ShowMenu()
        {
            // NotifyIcon apre il menu solo col tasto destro: col sinistro si usa lo stesso metodo interno.
            var method = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
            method?.Invoke(tray, null);
        }

        private void BuildMenu()
        {
            menu.Items.Clear();
            string? version = updates.AvailableVersion;
            if (version != null)
            {
                Add("Installa l'aggiornamento a Cornetta " + version + "…", () => InstallUpdate());
                menu.Items.Add(new ToolStripSeparator());
            }
            var toggle = Add(IsRecording ? "Ferma registrazione" : "Avvia registrazione", Toggle);
            if (hotkey.Registered) toggle.ShortcutKeyDisplayString = "Ctrl+Alt+R";
            toggle.Enabled = !busy;
            if (IsRecording)
            {
                Info("In registrazione · " + ElapsedText);
                Info("Microfono: " + (microphoneName ?? "nessuno"));
            }
            if (message != null) Info(message);
            if (microphoneDenied)
            {
                Add("Apri le impostazioni del microfono…", OpenMicrophoneSettings);
            }
            menu.Items.Add(new ToolStripSeparator());
            Add("Apri cartella registrazioni", OpenFolder);
            if (lastFile != null) Add("Mostra l'ultima registrazione", RevealLastFile);
            menu.Items.Add(new ToolStripSeparator());
            Add("Invia un feedback…", OpenFeedback);
            var overlayItem = Add("Mostra il pannello durante la registrazione", () =>
            {
                Settings.ShowOverlay = !Settings.ShowOverlay;
                RefreshOverlay();
            });
            overlayItem.Checked = Settings.ShowOverlay;
            var proposeItem = Add("Proponi di registrare quando inizia una chiamata", () => Settings.ProposeOnCall = !Settings.ProposeOnCall);
            proposeItem.Checked = Settings.ProposeOnCall;
            Add("Controlla aggiornamenti…", async () => await CheckUpdates(manual: true));
            menu.Items.Add(new ToolStripSeparator());
            Info("Cornetta " + AppInfo.Version);
            Add("Esci da Cornetta", Quit);
        }

        private ToolStripMenuItem Add(string text, Action action)
        {
            var item = new ToolStripMenuItem(text);
            item.Click += (_, __) => action();
            menu.Items.Add(item);
            return item;
        }

        private void Info(string text)
        {
            menu.Items.Add(new ToolStripMenuItem(text) { Enabled = false });
        }

        private void UpdateTrayIcon()
        {
            if (IsRecording)
            {
                tray.Icon = TrayIcons.Recording;
                SetTrayText("Cornetta · In registrazione " + ElapsedText);
            }
            else if (updates.AvailableVersion != null)
            {
                tray.Icon = TrayIcons.Update;
                SetTrayText("Cornetta · Aggiornamento disponibile");
            }
            else
            {
                tray.Icon = TrayIcons.Idle;
                SetTrayText("Cornetta");
            }
        }

        private void SetTrayText(string text)
        {
            // NotifyIcon accetta al massimo 63 caratteri.
            tray.Text = text.Length > 63 ? text.Substring(0, 63) : text;
        }

        // MARK: - Registrazione

        private void Toggle()
        {
            if (busy) return;
            if (IsRecording) _ = Stop(); else _ = Start();
        }

        private async Task Start()
        {
            if (IsRecording || busy) return;
            if (installing)
            {
                // L'aggiornamento riavvia l'app: una registrazione partita adesso verrebbe troncata.
                tray.ShowBalloonTip(5000, "Cornetta", "Sto installando l'aggiornamento: fra pochi secondi puoi registrare.", ToolTipIcon.Info);
                return;
            }
            busy = true;
            message = null;
            CloseNotice();
            Diagnostics.Log("Avvio richiesto");
            bool micAllowed = MicrophonePrivacy.IsAllowed();
            Diagnostics.Log("Permesso microfono: " + (micAllowed ? "true" : "false"));
            microphoneDenied = !micAllowed;
            string path = FileNaming.RecordingPath(AppInfo.RecordingsDirectory, DateTime.Now, null, AudioFileSink.Extension);
            var newRecorder = new Recorder(path);
            newRecorder.MicrophoneChanged += name => invoker.BeginInvoke(new Action(() => { microphoneName = name; Tick(); }));
            newRecorder.Failure += text => invoker.BeginInvoke(new Action(() => HandleFailure(newRecorder, text)));
            try
            {
                await Task.Run(() => newRecorder.Start(micAllowed));
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Avvio non riuscito: " + ex.Message);
                message = ex is InvalidOperationException ? ex.Message : "Non riesco ad avviare la registrazione: " + ex.Message;
                busy = false;
                tray.ShowBalloonTip(8000, "Cornetta", message, ToolTipIcon.Warning);
                return;
            }
            recorder = newRecorder;
            busy = false;
            microphoneName = newRecorder.MicrophoneName;
            if (!micAllowed)
            {
                message = "Microfono non autorizzato: registro solo l'audio della chiamata.";
            }
            else if (newRecorder.MicrophoneName == null)
            {
                message = "Nessun microfono trovato: registro solo l'audio della chiamata.";
            }
            else if (newRecorder.OutputName == null)
            {
                message = "Nessuna uscita audio trovata: registro solo il microfono.";
            }
            startedAt = DateTime.UtcNow;
            callEndedSuggestion = false;
            calls.RecordingStarted(DateTime.UtcNow);
            meterTimer.Start();
            RefreshOverlay();
            UpdateTrayIcon();
            if (message != null) tray.ShowBalloonTip(6000, "Cornetta", message, ToolTipIcon.Warning);
        }

        private async Task Stop()
        {
            var current = recorder;
            if (current == null || busy) return;
            busy = true;
            try
            {
                var stats = await Task.Run(() => current.Stop());
                Diagnostics.Log("Stop: " + Diagnostics.F(stats.Seconds, 2) + " s scritti, "
                    + Diagnostics.F((DateTime.UtcNow - startedAt).TotalSeconds, 2) + " s dall'avvio, riavvii " + current.RestartCount
                    + ", guadagno voce " + Diagnostics.F(current.MicGain, 1));
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Stop non riuscito: " + ex.Message);
            }
            finally
            {
                busy = false;
            }
            lastFile = current.OutputPath;
            Finish();
            message = "Salvata: " + Path.GetFileName(current.OutputPath);
            tray.ShowBalloonTip(6000, "Registrazione salvata", Path.GetFileName(current.OutputPath) + "\nUn clic qui per vederla nella cartella.", ToolTipIcon.Info);
            if (pendingUpdateNotice != null)
            {
                string version = pendingUpdateNotice;
                pendingUpdateNotice = null;
                AnnounceUpdate(version);
            }
        }

        private void HandleFailure(Recorder failed, string text)
        {
            if (recorder != failed) return;
            lastFile = failed.OutputPath;
            Finish();
            message = text;
            tray.ShowBalloonTip(8000, "Cornetta", text, ToolTipIcon.Error);
        }

        private void Finish()
        {
            meterTimer.Stop();
            recorder = null;
            callEndedSuggestion = false;
            RefreshOverlay();
            UpdateTrayIcon();
        }

        private void Tick()
        {
            if (!IsRecording) return;
            var levels = recorder!.Meter?.Levels ?? (0f, 0f);
            overlay?.UpdateState(ElapsedText, levels.Mic, levels.System, microphoneName, callEndedSuggestion);
            if (DateTime.UtcNow.Millisecond < 100) UpdateTrayIcon();
        }

        // MARK: - Pannello di registrazione

        private void RefreshOverlay()
        {
            if (IsRecording && Settings.ShowOverlay)
            {
                if (overlay == null || overlay.IsDisposed)
                {
                    overlay = new OverlayForm();
                    overlay.StopClicked += () => _ = Stop();
                    overlay.FeedbackClicked += OpenFeedback;
                    overlay.ContinueClicked += DismissCallEnded;
                }
                Tick();
                overlay.ShowPanel();
            }
            else
            {
                overlay?.Hide();
            }
        }

        private void DismissCallEnded()
        {
            callEndedSuggestion = false;
            calls.DismissCallEnded();
            Tick();
        }

        // MARK: - Chiamate

        private void PollCalls()
        {
            var apps = CallDetector.CallApps(MicrophoneUsage.Read());
            bool noticeOpen = notice != null;
            var result = calls.Poll(DateTime.UtcNow, apps, IsRecording, Settings.ProposeOnCall, noticeOpen, notice?.Kind == "call");

            if (IsRecording)
            {
                if (result.CallResumed)
                {
                    callEndedSuggestion = false;
                    if (notice?.Kind == "ended") CloseNotice();
                    Tick();
                }
                if (result.CallEnded)
                {
                    callEndedSuggestion = true;
                    if (!Settings.ShowOverlay) ShowCallEndedNotice();
                    Tick();
                }
                return;
            }

            if (result.CloseCallNotice) CloseNotice();
            if (result.PromptApp != null) ShowCallNotice(result.PromptApp);
        }

        private void ShowCallNotice(string appName)
        {
            Diagnostics.Log("Chiamata rilevata: " + appName);
            ShowNotice(new NoticeForm("call", "", Theme.Red,
                "Chiamata in corso su " + appName,
                "Vuoi registrarla? Registro la tua voce e quella delle altre persone in un file.",
                "Registra", "Non ora",
                () => { CloseNotice(); _ = Start(); },
                CloseNotice));
            // Se nessuno risponde, l'avviso sparisce da solo dopo 30 secondi.
            noticeTimeout = new Timer { Interval = 30_000 };
            noticeTimeout.Tick += (_, __) => { if (notice?.Kind == "call") CloseNotice(); };
            noticeTimeout.Start();
        }

        private void ShowCallEndedNotice()
        {
            ShowNotice(new NoticeForm("ended", "", Theme.Orange,
                "La chiamata sembra finita",
                "Cornetta sta ancora registrando.",
                "Ferma e salva", "Continua",
                () => { CloseNotice(); _ = Stop(); },
                () => { CloseNotice(); DismissCallEnded(); }));
        }

        // MARK: - Aggiornamenti

        private async Task CheckUpdates(bool manual)
        {
            var result = await updates.CheckAsync();
            UpdateTrayIcon();
            switch (result)
            {
                case UpdateCheck.Found:
                    AnnounceUpdate(updates.AvailableVersion!);
                    break;
                case UpdateCheck.UpToDate when manual:
                    tray.ShowBalloonTip(5000, "Cornetta", "Hai già la versione più recente (" + AppInfo.Version + ").", ToolTipIcon.Info);
                    break;
                case UpdateCheck.NotInstalled when manual:
                    tray.ShowBalloonTip(5000, "Cornetta", "Gli aggiornamenti funzionano solo nella versione installata con CornettaSetup.exe.", ToolTipIcon.Info);
                    break;
                case UpdateCheck.Failed when manual:
                    tray.ShowBalloonTip(5000, "Cornetta", "Non riesco a controllare gli aggiornamenti. Controlla la connessione e riprova.", ToolTipIcon.Warning);
                    break;
            }
        }

        private void AnnounceUpdate(string version)
        {
            // Durante una registrazione l'avviso aspetta lo stop: niente distrazioni in chiamata.
            if (IsRecording)
            {
                pendingUpdateNotice = version;
                return;
            }
            if (notice?.Kind == "update" || installing) return;
            ShowNotice(new NoticeForm("update", "", Theme.Blue,
                "Aggiornamento disponibile",
                "È pronta Cornetta " + version + ". L'installazione richiede pochi secondi e l'app si riapre da sola.",
                "Aggiorna ora", "Più tardi",
                () => { CloseNotice(); InstallUpdate(); },
                CloseNotice));
            SystemSounds.Asterisk.Play();
        }

        private async void InstallUpdate()
        {
            if (installing) return;
            if (IsRecording)
            {
                // Non si interrompe una chiamata: l'avviso torna appena la registrazione finisce.
                pendingUpdateNotice = updates.AvailableVersion;
                tray.ShowBalloonTip(5000, "Cornetta", "L'aggiornamento parte quando fermi la registrazione.", ToolTipIcon.Info);
                return;
            }
            installing = true;
            SetTrayText("Cornetta · Scarico l'aggiornamento…");
            try
            {
                await updates.InstallAsync(
                    percent => invoker.BeginInvoke(new Action(() => SetTrayText("Cornetta · Aggiornamento " + percent + "%"))),
                    () => { tray.Visible = false; });
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Aggiornamento non riuscito: " + ex.Message);
                tray.Visible = true;
                tray.ShowBalloonTip(8000, "Cornetta", "L'aggiornamento non è riuscito. Riprova più tardi.", ToolTipIcon.Warning);
            }
            installing = false;
            UpdateTrayIcon();
        }

        // MARK: - Avvisi

        private void ShowNotice(NoticeForm form)
        {
            CloseNotice();
            notice = form;
            notice.ShowPanel();
        }

        private void CloseNotice()
        {
            noticeTimeout?.Stop();
            noticeTimeout?.Dispose();
            noticeTimeout = null;
            if (notice != null)
            {
                notice.Close();
                notice.Dispose();
                notice = null;
            }
        }

        // MARK: - Feedback

        private void OpenFeedback()
        {
            if (feedback != null && !feedback.IsDisposed)
            {
                feedback.Activate();
                return;
            }
            feedback = new FeedbackForm(microphoneName ?? AudioDevices.Describe().Input);
            feedback.FormClosed += (_, __) => feedback = null;
            feedback.Show();
            feedback.Activate();
        }

        // MARK: - Esplora file

        private void OpenFolder()
        {
            string folder = AppInfo.RecordingsDirectory;
            try
            {
                Directory.CreateDirectory(folder);
                Process.Start(new ProcessStartInfo("explorer.exe", "\"" + folder + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Cartella non aperta: " + ex.Message);
            }
        }

        private void RevealLastFile()
        {
            if (lastFile == null || !File.Exists(lastFile)) return;
            try
            {
                Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + lastFile + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Diagnostics.Log("File non mostrato: " + ex.Message);
            }
        }

        private void OpenMicrophoneSettings()
        {
            try
            {
                Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Impostazioni non aperte: " + ex.Message);
            }
        }

        // MARK: - Uscita

        private async void Quit()
        {
            // Se una registrazione sta partendo, aspetta che sia partita: poi la chiude bene.
            while (busy) await Task.Delay(100);
            if (recorder != null)
            {
                var current = recorder;
                var stats = await Task.Run(() => current.Stop());
                Diagnostics.Log("Stop all'uscita: " + Diagnostics.F(stats.Seconds, 2) + " s scritti");
                recorder = null;
            }
            ExitThread();
        }

        private void OnSessionEnding(object sender, SessionEndingEventArgs e) =>
            StopForSystem("Registrazione fermata: Windows si sta spegnendo.");

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Suspend) StopForSystem("Registrazione fermata e salvata: il PC è andato in sospensione.");
        }

        /// <summary>Chiude subito il file, da qualunque thread arrivi l'evento di sistema.</summary>
        private void StopForSystem(string reason)
        {
            var current = recorder;
            if (current == null) return;
            try
            {
                var stats = Task.Run(() => current.Stop()).Result;
                Diagnostics.Log(reason + " " + Diagnostics.F(stats.Seconds, 2) + " s scritti");
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Stop di sistema non riuscito: " + ex.GetBaseException().Message);
            }
            try
            {
                invoker.BeginInvoke(new Action(() =>
                {
                    if (recorder != current) return;
                    lastFile = current.OutputPath;
                    Finish();
                    message = reason;
                }));
            }
            catch (InvalidOperationException) { }
        }

        protected override void ExitThreadCore()
        {
            SystemEvents.SessionEnding -= OnSessionEnding;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            // Chiude il file anche se l'app esce durante una registrazione.
            if (recorder != null)
            {
                var current = recorder;
                recorder = null;
                Task.Run(() => current.Stop()).Wait(TimeSpan.FromSeconds(30));
            }
            meterTimer.Stop();
            callTimer.Stop();
            updateTimer.Stop();
            CloseNotice();
            overlay?.Close();
            feedback?.Close();
            hotkey.Dispose();
            tray.Visible = false;
            tray.Dispose();
            base.ExitThreadCore();
        }
    }
}
