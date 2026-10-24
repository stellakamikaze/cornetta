using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Cornetta.Core;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Cornetta.App
{
    /// <summary>
    /// Registra in un file la voce dal microfono e l'audio di sistema (la voce degli altri in chiamata).
    ///
    /// Catture WASAPI indipendenti (microfono e loopback dell'uscita, quelli che Windows assegna alle chiamate, più il loopback
    /// dell'uscita predefinita generale se è un'altra) scrivono sulla stessa linea del tempo, decisa da un orologio unico
    /// (CaptureTimeline). Un thread mixer legge la linea del tempo con 350 ms di ritardo, livella la voce, mixa e scrive
    /// il WAV di lavoro, che allo stop diventa il file nella cartella delle registrazioni (RecordingFiles).
    /// Per tenere vivo il loopback quando nessuno parla, Cornetta suona silenzio sull'uscita.
    ///
    /// Start, Stop e i riavvii girano su thread MTA (Task.Run), mai sul thread dell'interfaccia.
    /// </summary>
    internal sealed class Recorder : IDisposable
    {
        private const int Rate = RecordingPipeline.SampleRate;
        private static readonly double LatencySeconds = 0.35;

        private readonly object control = new object();
        private readonly Stopwatch clock = new Stopwatch();
        private MMDeviceEnumerator? enumerator;
        private DeviceWatcher? watcher;
        private WavRecordingSink? sink;
        private RecordingPipeline? pipeline;
        private SourceCapture? mic;
        private SourceCapture? system;
        private SourceCapture? system2;
        /// <summary>L'ID del dispositivo che il loopback delle chiamate ascolta, per riconoscere un cambio che lo sposta.</summary>
        private string? systemDeviceId;
        private WasapiOut? keepAlive;
        private WasapiOut? keepAlive2;
        private Thread? mixThread;
        private Timer? watchdog;
        private Timer? restartDebounce;
        private volatile bool running;
        private bool useMicrophone;
        private int firstBlockLogged;
        private bool pendingMicRestart;
        private bool pendingSystemRestart;
        private bool pendingSystem2Restart;
        private int watchdogTicks;

        public Recorder(string outputPath, string? workingDirectory = null)
        {
            OutputPath = outputPath;
            WorkingPath = WorkingFiles.PathFor(workingDirectory ?? AppInfo.WorkingDirectory, outputPath);
        }

        /// <summary>Il file nella cartella delle registrazioni. Dopo il salvataggio è quello vero (un .wav se la conversione non è riuscita).</summary>
        public string OutputPath { get; private set; }
        /// <summary>Il WAV di lavoro, scritto durante la registrazione.</summary>
        public string WorkingPath { get; }
        public string? MicrophoneName { get; private set; }
        /// <summary>L'uscita delle chiamate.</summary>
        public string? OutputName { get; private set; }
        /// <summary>L'uscita predefinita generale, ascoltata anche lei se è diversa da quella delle chiamate.</summary>
        public string? GeneralOutputName { get; private set; }
        public bool IsRunning => running;
        public int RestartCount { get; private set; }
        public LevelMeter? Meter => pipeline?.Meter;
        public RecordingStats? Stats => pipeline?.Stats;
        public float MicGain => pipeline?.MicGain ?? 1;
        /// <summary>Perché il salvataggio nella cartella delle registrazioni non è riuscito; null se è riuscito.</summary>
        public Exception? SaveError { get; private set; }

        /// <summary>Il microfono è cambiato (es. cuffie collegate a metà chiamata). Arriva da un thread qualsiasi.</summary>
        public event Action<string?>? MicrophoneChanged;
        /// <summary>La registrazione si è fermata per un errore. Arriva da un thread qualsiasi.</summary>
        public event Action<string>? Failure;

        public void Start(bool useMicrophone)
        {
            lock (control)
            {
                if (running) return;
                this.useMicrophone = useMicrophone;
                // La cartella delle registrazioni (OneDrive offline, disco esterno staccato) si prova subito, non allo stop.
                Directory.CreateDirectory(Path.GetDirectoryName(OutputPath)!);
                sink = new WavRecordingSink(WorkingPath);
                pipeline = new RecordingPipeline(sink);
                enumerator = new MMDeviceEnumerator();
                clock.Restart();
                running = true;
                try
                {
                    try { StartSystem(); }
                    catch (Exception ex)
                    {
                        // Senza loopback si registra almeno il microfono; il watchdog riprova l'uscita.
                        StopSystem();
                        OutputName = null;
                        GeneralOutputName = null;
                        Diagnostics.Log("Audio di sistema non avviato: " + ex.Message);
                    }
                    if (useMicrophone) StartMicrophone();
                    pipeline.HasMicrophone = mic != null;
                    if (mic == null && system == null)
                    {
                        throw new InvalidOperationException("Nessun dispositivo audio disponibile: non posso registrare.");
                    }
                }
                catch
                {
                    running = false;
                    StopCaptures();
                    sink.Close();
                    try { File.Delete(WorkingPath); } catch (Exception) { }
                    enumerator.Dispose();
                    enumerator = null;
                    throw;
                }

                Diagnostics.Log("Cattura avviata: microfono=" + (mic?.Description ?? "nessuno")
                    + " sistema=" + (system?.Description ?? "nessuno")
                    + (system2 != null ? " + " + system2.Description : "")
                    + " uscite=" + (system2 != null ? 2 : system != null ? 1 : 0)
                    + " file=" + Path.GetExtension(OutputPath).TrimStart('.')
                    + " silenzio=" + (keepAlive != null ? "sì" : "no"));

                watcher = new DeviceWatcher(OnDefaultDeviceChanged);
                try { enumerator.RegisterEndpointNotificationCallback(watcher); }
                catch (Exception ex) { Diagnostics.Log("Notifiche dei dispositivi non disponibili: " + ex.Message); watcher = null; }

                mixThread = new Thread(MixLoop) { IsBackground = true, Name = "Cornetta mixer", Priority = ThreadPriority.AboveNormal };
                mixThread.Start();
                watchdog = new Timer(_ => Watchdog(), null, 2000, 2000);
            }
        }

        /// <summary>Ferma la registrazione e salva il file nella cartella delle registrazioni. Restituisce le statistiche della sessione.</summary>
        public RecordingStats Stop()
        {
            lock (control)
            {
                var stats = StopWithoutSaving();
                SaveRecording();
                return stats;
            }
        }

        /// <summary>
        /// Ferma e chiude il WAV di lavoro senza convertirlo, come stopForTermination del Mac: allo spegnimento o all'uscita
        /// non c'è tempo. Il file lo salva SaveRecording, oppure il recupero al prossimo avvio.
        /// </summary>
        public RecordingStats StopWithoutSaving()
        {
            lock (control)
            {
                var stats = pipeline?.Stats ?? new RecordingStats();
                if (!running) return stats;
                running = false;
                watchdog?.Dispose();
                watchdog = null;
                restartDebounce?.Dispose();
                restartDebounce = null;
                if (watcher != null && enumerator != null)
                {
                    try { enumerator.UnregisterEndpointNotificationCallback(watcher); } catch (Exception) { }
                }
                watcher = null;
                StopCaptures();
                bool mixerStopped = mixThread?.Join(TimeSpan.FromSeconds(5)) ?? true;
                mixThread = null;
                try
                {
                    // Gli ultimi 350 ms che il mixer teneva in attesa (solo se il mixer è fermo: la pipeline ha un solo thread).
                    if (mixerStopped) pipeline?.CatchUp(NowFrame());
                    else Diagnostics.Log("Il mixer non si è fermato entro 5 s: salto gli ultimi 350 ms");
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Chiusura del mix: " + ex.Message);
                }
                try { sink?.Close(); }
                catch (Exception ex) { Diagnostics.Log("Chiusura del file: " + ex.Message); }
                if (sink?.Error != null) Diagnostics.Log("Errore del file: " + sink.Error.Message);
                if (pipeline != null)
                {
                    Diagnostics.Log("Linea del tempo: microfono buchi=" + pipeline.Microphone.GapsFilled + " scarti=" + pipeline.Microphone.FramesDropped
                        + ", sistema buchi=" + pipeline.System.GapsFilled + " scarti=" + pipeline.System.FramesDropped);
                }
                enumerator?.Dispose();
                enumerator = null;
                clock.Stop();
                return stats;
            }
        }

        /// <summary>
        /// Converte il WAV di lavoro, se c'è ancora, nel file della cartella delle registrazioni (OutputPath).
        /// Restituisce falso se il file non c'è: il WAV resta in «In corso» e lo salva il recupero al prossimo avvio.
        /// </summary>
        public bool SaveRecording()
        {
            lock (control)
            {
                if (running) return false;
                if (File.Exists(WorkingPath))
                {
                    try
                    {
                        OutputPath = RecordingFiles.Finalize(WorkingPath, OutputPath);
                        SaveError = null;
                    }
                    catch (Exception ex)
                    {
                        SaveError = ex;
                        Diagnostics.Log("Registrazione non salvata, la recupero al prossimo avvio: " + ex.Message);
                    }
                }
                return File.Exists(OutputPath);
            }
        }

        public double ElapsedSeconds => clock.Elapsed.TotalSeconds;

        public void Dispose() => Stop();

        private long NowFrame() => clock.ElapsedTicks * Rate / Stopwatch.Frequency;

        // MARK: - Catture

        private void StartSystem()
        {
            var device = AudioDevices.Default(enumerator!, DataFlow.Render);
            GeneralOutputName = null;
            if (device == null)
            {
                OutputName = null;
                Diagnostics.Log("Nessuna uscita audio: registro solo il microfono");
                return;
            }
            OutputName = device.FriendlyName;
            system = OpenLoopback(device, pipeline!.System, "sistema", out keepAlive);
            systemDeviceId = device.ID;
            StartGeneralOutput(device);
        }

        /// <summary>
        /// Chrome, Edge e Firefox (Meet, Teams web) suonano sul predefinito generale finché il sito non sceglie un'uscita:
        /// se è diverso da quello delle chiamate si ascoltano tutti e due. Il microfono resta solo quello delle chiamate.
        /// </summary>
        private void StartGeneralOutput(MMDevice callOutput)
        {
            GeneralOutputName = null;
            var general = AudioDevices.GeneralOutput(enumerator!, callOutput);
            if (general == null) return;
            try
            {
                system2 = OpenLoopback(general, pipeline!.System2, "sistema 2", out keepAlive2);
                GeneralOutputName = general.FriendlyName;
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Seconda uscita non avviata: " + ex.Message);
            }
        }

        /// <summary>Loopback di un'uscita sulla linea del tempo, più il flusso di silenzio che lo tiene vivo.</summary>
        private SourceCapture OpenLoopback(MMDevice device, CaptureTimeline timeline, string name, out WasapiOut? silence)
        {
            AudioDevices.OptOutOfDucking(device);
            var capture = new WasapiLoopbackCapture(device);
            var source = new SourceCapture(name, capture, timeline, NowFrame, OnFirstBlock, OnCaptureStopped);
            try { source.Start(); }
            catch
            {
                source.Dispose();
                throw;
            }
            silence = null;
            try
            {
                // Silenzio sull'uscita: il loopback continua a mandare pacchetti anche quando nessuno parla.
                silence = new WasapiOut(device, AudioClientShareMode.Shared, false, 200);
                silence.Init(new SilenceProvider(capture.WaveFormat));
                silence.Play();
            }
            catch (Exception ex)
            {
                silence?.Dispose();
                silence = null;
                Diagnostics.Log("Flusso di silenzio non avviato su " + name + " (resta il riempimento a orologio): " + ex.Message);
            }
            return source;
        }

        private void StartMicrophone()
        {
            var device = AudioDevices.Default(enumerator!, DataFlow.Capture);
            if (device == null)
            {
                MicrophoneName = null;
                return;
            }
            try
            {
                AudioDevices.OptOutOfDucking(device);
                var capture = new WasapiCapture(device, true, 100);
                mic = new SourceCapture("microfono", capture, pipeline!.Microphone, NowFrame, OnFirstBlock, OnCaptureStopped);
                mic.Start();
                MicrophoneName = device.FriendlyName;
            }
            catch (Exception ex)
            {
                mic?.Dispose();
                mic = null;
                MicrophoneName = null;
                Diagnostics.Log("Microfono non avviato: " + ex.Message);
            }
        }

        private void StopCaptures()
        {
            mic?.Dispose();
            mic = null;
            StopSystem();
        }

        private void StopSystem()
        {
            system?.Dispose();
            system = null;
            systemDeviceId = null;
            StopSilence(ref keepAlive);
            StopGeneralOutput();
        }

        private void StopGeneralOutput()
        {
            system2?.Dispose();
            system2 = null;
            StopSilence(ref keepAlive2);
        }

        private static void StopSilence(ref WasapiOut? silence)
        {
            try { silence?.Stop(); } catch (Exception) { }
            silence?.Dispose();
            silence = null;
        }

        private void OnFirstBlock(string source)
        {
            if (Interlocked.Exchange(ref firstBlockLogged, 1) == 0)
            {
                Diagnostics.Log("Primo blocco audio dopo " + Diagnostics.F(clock.Elapsed.TotalSeconds, 3) + " s (" + source + ")");
            }
        }

        // MARK: - Mixer

        private void MixLoop()
        {
            long latency = (long)(LatencySeconds * Rate);
            while (running)
            {
                Thread.Sleep(20);
                try
                {
                    long upTo = NowFrame() - latency;
                    if (upTo > pipeline!.RenderedFrames)
                    {
                        long skipped = pipeline.CatchUp(upTo);
                        if (skipped > 0) Diagnostics.Log("Orologio saltato di " + Diagnostics.F(skipped / (double)Rate, 1) + " s: salto il buco");
                    }
                }
                catch (Exception ex)
                {
                    Fail("Errore nel mix: " + ex.Message);
                    return;
                }
                if (sink?.Error != null)
                {
                    Fail("Errore di scrittura: " + sink.Error.Message);
                    return;
                }
            }
        }

        private void Fail(string message)
        {
            Diagnostics.Log(message);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                // Su .NET Framework un'eccezione in un thread del pool chiude il processo: qui non ne esce nessuna.
                try { Stop(); }
                catch (Exception ex) { Diagnostics.Log("Stop dopo l'errore: " + ex.Message); }
                try { Failure?.Invoke(message); }
                catch (Exception ex) { Diagnostics.Log("Avviso dell'errore: " + ex.Message); }
            });
        }

        // MARK: - Cambio dispositivo (es. cuffie collegate a metà chiamata)

        private void OnDefaultDeviceChanged(DeviceRestart restart)
        {
            if (!running) return;
            lock (control)
            {
                if (restart == DeviceRestart.Microphone) pendingMicRestart = true;
                else if (restart == DeviceRestart.CallOutput) pendingSystemRestart = true;
                else if (restart == DeviceRestart.GeneralOutput) pendingSystem2Restart = true;
                else return;
                // Windows manda più notifiche di fila: si riavvia una volta sola, dopo mezzo secondo.
                restartDebounce?.Dispose();
                restartDebounce = new Timer(_ => ApplyPendingRestarts(), null, 500, Timeout.Infinite);
            }
        }

        private void OnCaptureStopped(SourceCapture source, Exception? error)
        {
            if (!running || error == null) return;
            Diagnostics.Log("Cattura " + source.Name + " interrotta: " + error.Message);
            lock (control)
            {
                if (source == mic) pendingMicRestart = true;
                if (source == system) pendingSystemRestart = true;
                if (source == system2) pendingSystem2Restart = true;
                restartDebounce?.Dispose();
                restartDebounce = new Timer(_ => ApplyPendingRestarts(), null, 500, Timeout.Infinite);
            }
        }

        private void ApplyPendingRestarts()
        {
            // Gira su un timer: nessuna eccezione deve uscire di qui.
            try { ApplyPendingRestartsCore(); }
            catch (Exception ex) { Diagnostics.Log("Riavvio della cattura non riuscito: " + ex.Message); }
        }

        private void ApplyPendingRestartsCore()
        {
            bool micChanged = false;
            string? name;
            lock (control)
            {
                if (!running) return;
                if (pendingSystem2Restart && !pendingSystemRestart && DeviceChange.CallOutputMoved(CallOutputId(), systemDeviceId))
                {
                    // Senza un'uscita per le Comunicazioni quella delle chiamate è il predefinito generale: è cambiata lei.
                    pendingSystemRestart = true;
                }
                if (pendingSystemRestart)
                {
                    pendingSystemRestart = false;
                    pendingSystem2Restart = false;
                    StopSystem();
                    try { StartSystem(); }
                    catch (Exception ex)
                    {
                        StopSystem();
                        Diagnostics.Log("Riavvio del sistema non riuscito, riprovo fra poco: " + ex.Message);
                    }
                    Diagnostics.Log("Uscita: " + (OutputName ?? "nessuna") + (GeneralOutputName != null ? " + " + GeneralOutputName : ""));
                }
                if (pendingSystem2Restart)
                {
                    // Solo la seconda uscita: la voce degli altri sull'uscita delle chiamate non si interrompe.
                    pendingSystem2Restart = false;
                    StopGeneralOutput();
                    GeneralOutputName = null;
                    var callOutput = system != null ? AudioDevices.Default(enumerator!, DataFlow.Render) : null;
                    if (callOutput != null) StartGeneralOutput(callOutput);
                    Diagnostics.Log("Seconda uscita: " + (GeneralOutputName ?? "nessuna"));
                }
                if (pendingMicRestart && useMicrophone)
                {
                    pendingMicRestart = false;
                    mic?.Dispose();
                    mic = null;
                    StartMicrophone();
                    pipeline!.HasMicrophone = mic != null;
                    micChanged = true;
                    Diagnostics.Log("Microfono: " + (MicrophoneName ?? "nessuno"));
                }
                name = MicrophoneName;
            }
            if (micChanged) MicrophoneChanged?.Invoke(name);
        }

        // MARK: - Watchdog
        // Se l'audio smette di arrivare (dispositivo sparito senza notifica), ricrea la cattura.

        private void Watchdog()
        {
            try { WatchdogCore(); }
            catch (Exception ex) { Diagnostics.Log("Watchdog: " + ex.Message); }
        }

        private void WatchdogCore()
        {
            if (!running) return;
            bool restart = false;
            lock (control)
            {
                // Una sorgente persa (dispositivo non pronto al riavvio) si riprova ogni 10 s, se Windows ha un dispositivo da usare.
                watchdogTicks++;
                if (watchdogTicks % 5 == 0 && enumerator != null)
                {
                    if (useMicrophone && mic == null && AudioDevices.Exists(enumerator, DataFlow.Capture)) { pendingMicRestart = true; restart = true; }
                    if (system == null && AudioDevices.Exists(enumerator, DataFlow.Render)) { pendingSystemRestart = true; restart = true; }
                }
                if (mic != null && mic.SecondsSinceLastData > 3)
                {
                    pendingMicRestart = true;
                    restart = true;
                }
                // Senza il flusso di silenzio il loopback tace di suo: solo con il silenzio attivo è un guasto.
                if (Stalled(system, keepAlive))
                {
                    pendingSystemRestart = true;
                    restart = true;
                }
                if (Stalled(system2, keepAlive2))
                {
                    pendingSystem2Restart = true;
                    restart = true;
                }
                if (restart)
                {
                    RestartCount++;
                    Diagnostics.Log("Nessun audio da 3 s: riavvio la cattura (" + RestartCount + ")");
                }
            }
            if (restart) ApplyPendingRestarts();
        }

        /// <summary>L'ID dell'uscita che AudioDevices.Default sceglie adesso per le chiamate, o null se non c'è.</summary>
        private string? CallOutputId()
        {
            var device = AudioDevices.Default(enumerator!, DataFlow.Render);
            try { return device?.ID; }
            finally { device?.Dispose(); }
        }

        private static bool Stalled(SourceCapture? source, WasapiOut? silence) =>
            source != null && silence != null && source.SecondsSinceLastData > 3;
    }

    /// <summary>Una cattura WASAPI che converte, ricampiona a 48 kHz e scrive sulla linea del tempo.</summary>
    internal sealed class SourceCapture : IDisposable
    {
        private readonly IWaveIn capture;
        private readonly CaptureTimeline timeline;
        private readonly Func<long> nowFrame;
        private readonly Action<string> onFirstBlock;
        private readonly InputFormat format;
        private readonly StreamResampler resampler;
        private readonly Stopwatch sinceData = Stopwatch.StartNew();
        private bool disposed;

        public SourceCapture(string name, IWaveIn capture, CaptureTimeline timeline, Func<long> nowFrame,
                             Action<string> onFirstBlock, Action<SourceCapture, Exception?> onStopped)
        {
            Name = name;
            this.capture = capture;
            this.timeline = timeline;
            this.nowFrame = nowFrame;
            this.onFirstBlock = onFirstBlock;
            format = Describe(capture.WaveFormat);
            resampler = new StreamResampler(format.SampleRate, RecordingPipeline.SampleRate, timeline.Channels);
            capture.DataAvailable += OnData;
            capture.RecordingStopped += (_, e) => { if (!disposed) onStopped(this, e.Exception); };
        }

        public string Name { get; }
        public string Description => Name + " " + format;
        public double SecondsSinceLastData => sinceData.Elapsed.TotalSeconds;

        public void Start()
        {
            sinceData.Restart();
            capture.StartRecording();
        }

        private void OnData(object? sender, WaveInEventArgs e)
        {
            if (disposed || e.BytesRecorded <= 0) return;
            try
            {
                long arrival = nowFrame();
                sinceData.Restart();
                onFirstBlock(Name);
                var samples = AudioConversion.ToFloat(e.Buffer, e.BytesRecorded, format);
                var shaped = timeline.Channels == 1
                    ? AudioConversion.ToMono(samples, format.Channels)
                    : AudioConversion.ToStereo(samples, format.Channels);
                timeline.Write(arrival, resampler.Process(shaped));
            }
            catch (Exception ex)
            {
                // Thread di cattura di NAudio: un'eccezione qui chiuderebbe l'app.
                Diagnostics.Log("Blocco " + Name + " scartato: " + ex.Message);
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { capture.StopRecording(); } catch (Exception) { }
            try { capture.Dispose(); } catch (Exception) { }
        }

        internal static InputFormat Describe(WaveFormat waveFormat)
        {
            bool isFloat = waveFormat.Encoding == WaveFormatEncoding.IeeeFloat;
            if (waveFormat is WaveFormatExtensible extensible)
            {
                isFloat = extensible.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
            }
            return new InputFormat(waveFormat.SampleRate, waveFormat.Channels, waveFormat.BitsPerSample, isFloat);
        }
    }

    /// <summary>Notifiche di Windows sul cambio dei dispositivi che Cornetta usa.</summary>
    internal sealed class DeviceWatcher : IMMNotificationClient
    {
        private readonly Action<DeviceRestart> onDefaultChanged;

        public DeviceWatcher(Action<DeviceRestart> onDefaultChanged) { this.onDefaultChanged = onDefaultChanged; }

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            // Cornetta segue i dispositivi delle chiamate e, per l'uscita, anche il predefinito generale (Recorder.StartSystem).
            var restart = DeviceChange.For(flow == DataFlow.Capture, role == AudioDevices.CallRole, role == Role.Console);
            if (restart == DeviceRestart.None) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try { onDefaultChanged(restart); }
                catch (Exception ex) { Diagnostics.Log("Cambio dispositivo: " + ex.Message); }
            });
        }

        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}
