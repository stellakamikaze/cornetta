using System;
using System.Diagnostics;
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
    /// Due catture WASAPI indipendenti (microfono e loopback dell'uscita predefinita) scrivono sulla
    /// stessa linea del tempo, decisa da un orologio unico (CaptureTimeline). Un thread mixer legge
    /// la linea del tempo con 350 ms di ritardo, livella la voce, mixa e scrive il file.
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
        private AudioFileSink? sink;
        private RecordingPipeline? pipeline;
        private SourceCapture? mic;
        private SourceCapture? system;
        private WasapiOut? keepAlive;
        private Thread? mixThread;
        private Timer? watchdog;
        private Timer? restartDebounce;
        private volatile bool running;
        private bool useMicrophone;
        private int firstBlockLogged;
        private bool pendingMicRestart;
        private bool pendingSystemRestart;
        private int watchdogTicks;

        public Recorder(string outputPath)
        {
            OutputPath = outputPath;
        }

        public string OutputPath { get; }
        public string? MicrophoneName { get; private set; }
        public string? OutputName { get; private set; }
        public bool IsAac => sink?.IsAac ?? false;
        public bool IsRunning => running;
        public int RestartCount { get; private set; }
        public LevelMeter? Meter => pipeline?.Meter;
        public float MicGain => pipeline?.MicGain ?? 1;

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
                sink = AudioFileSink.Create(OutputPath);
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
                        system?.Dispose();
                        system = null;
                        OutputName = null;
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
                    enumerator.Dispose();
                    enumerator = null;
                    throw;
                }

                Diagnostics.Log("Cattura avviata: microfono=" + (mic?.Description ?? "nessuno")
                    + " sistema=" + (system?.Description ?? "nessuno")
                    + " file=" + (sink.IsAac ? "aac" : "wav")
                    + " silenzio=" + (keepAlive != null ? "sì" : "no"));

                watcher = new DeviceWatcher(OnDefaultDeviceChanged);
                try { enumerator.RegisterEndpointNotificationCallback(watcher); }
                catch (Exception ex) { Diagnostics.Log("Notifiche dei dispositivi non disponibili: " + ex.Message); watcher = null; }

                mixThread = new Thread(MixLoop) { IsBackground = true, Name = "Cornetta mixer", Priority = ThreadPriority.AboveNormal };
                mixThread.Start();
                watchdog = new Timer(_ => Watchdog(), null, 2000, 2000);
            }
        }

        /// <summary>Ferma la registrazione e chiude il file. Restituisce le statistiche della sessione.</summary>
        public RecordingStats Stop()
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
                    if (mixerStopped) pipeline?.Render(NowFrame());
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

        public double ElapsedSeconds => clock.Elapsed.TotalSeconds;

        public void Dispose() => Stop();

        private long NowFrame() => clock.ElapsedTicks * Rate / Stopwatch.Frequency;

        // MARK: - Catture

        private void StartSystem()
        {
            var device = AudioDevices.Default(enumerator!, DataFlow.Render);
            if (device == null)
            {
                OutputName = null;
                Diagnostics.Log("Nessuna uscita audio: registro solo il microfono");
                return;
            }
            OutputName = device.FriendlyName;
            var capture = new WasapiLoopbackCapture(device);
            system = new SourceCapture("sistema", capture, pipeline!.System, NowFrame, OnFirstBlock, OnCaptureStopped);
            system.Start();
            try
            {
                // Silenzio sull'uscita: il loopback continua a mandare pacchetti anche quando nessuno parla.
                keepAlive = new WasapiOut(device, AudioClientShareMode.Shared, false, 200);
                keepAlive.Init(new SilenceProvider(capture.WaveFormat));
                keepAlive.Play();
            }
            catch (Exception ex)
            {
                keepAlive?.Dispose();
                keepAlive = null;
                Diagnostics.Log("Flusso di silenzio non avviato (resta il riempimento a orologio): " + ex.Message);
            }
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
            system?.Dispose();
            system = null;
            try { keepAlive?.Stop(); } catch (Exception) { }
            keepAlive?.Dispose();
            keepAlive = null;
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
                    if (upTo > pipeline!.RenderedFrames) pipeline.Render(upTo);
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

        private void OnDefaultDeviceChanged(DataFlow flow)
        {
            if (!running) return;
            lock (control)
            {
                if (flow == DataFlow.Capture) pendingMicRestart = true; else pendingSystemRestart = true;
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
                if (pendingSystemRestart)
                {
                    pendingSystemRestart = false;
                    system?.Dispose();
                    system = null;
                    try { keepAlive?.Stop(); } catch (Exception) { }
                    keepAlive?.Dispose();
                    keepAlive = null;
                    try { StartSystem(); }
                    catch (Exception ex)
                    {
                        system?.Dispose();
                        system = null;
                        Diagnostics.Log("Riavvio del sistema non riuscito, riprovo fra poco: " + ex.Message);
                    }
                    Diagnostics.Log("Uscita: " + (OutputName ?? "nessuna"));
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

        private bool HasDefault(DataFlow flow)
        {
            try { return enumerator!.HasDefaultAudioEndpoint(flow, Role.Console); }
            catch (Exception) { return false; }
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
                // Una sorgente persa (dispositivo non pronto al riavvio) si riprova ogni 10 s, se Windows ha un dispositivo predefinito.
                watchdogTicks++;
                if (watchdogTicks % 5 == 0 && enumerator != null)
                {
                    if (useMicrophone && mic == null && HasDefault(DataFlow.Capture)) { pendingMicRestart = true; restart = true; }
                    if (system == null && HasDefault(DataFlow.Render)) { pendingSystemRestart = true; restart = true; }
                }
                if (mic != null && mic.SecondsSinceLastData > 3)
                {
                    pendingMicRestart = true;
                    restart = true;
                }
                // Senza il flusso di silenzio il loopback tace di suo: solo con il silenzio attivo è un guasto.
                if (system != null && keepAlive != null && system.SecondsSinceLastData > 3)
                {
                    pendingSystemRestart = true;
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

    /// <summary>Notifiche di Windows sul cambio del dispositivo predefinito.</summary>
    internal sealed class DeviceWatcher : IMMNotificationClient
    {
        private readonly Action<DataFlow> onDefaultChanged;

        public DeviceWatcher(Action<DataFlow> onDefaultChanged) { this.onDefaultChanged = onDefaultChanged; }

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (role != Role.Console) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try { onDefaultChanged(flow); }
                catch (Exception ex) { Diagnostics.Log("Cambio dispositivo: " + ex.Message); }
            });
        }

        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}
