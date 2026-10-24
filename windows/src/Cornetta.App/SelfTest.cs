using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cornetta.Core;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace Cornetta.App
{
    /// <summary>
    /// Prova senza interfaccia, per il CI e per un PC vero:
    ///   Cornetta.exe --selftest [--selftest-out report.txt]
    /// 1. legge i dispositivi audio e, se ci sono, li avvia per un secondo e mezzo;
    /// 2. controlla che l'encoder AAC di Media Foundation sia disponibile;
    /// 3. scrive un file .m4a (e un .wav) da un segnale sintetico passato per linea del tempo,
    ///    livellatore, mixer e WAV di lavoro, poi lo rilegge e ne controlla durata e livello;
    /// 4. recupera una registrazione interrotta (WAV di lavoro mai chiuso, come dopo un crash).
    /// Esce con 0 se tutto va bene, con 1 se qualcosa non va.
    /// </summary>
    internal static class SelfTest
    {
        private static readonly List<string> Report = new List<string>();
        private static bool failed;
        /// <summary>--selftest-poison: il sistema non scrive sulla linea del tempo. Il selftest DEVE fallire (prova che sa accorgersene).</summary>
        private static bool poison;

        public static int Run(string[] args)
        {
            ConsoleOutput.Attach();
            string? reportPath = ArgumentAfter(args, "--selftest-out");
            poison = args.Any(a => string.Equals(a, "--selftest-poison", StringComparison.OrdinalIgnoreCase));
            if (poison) Line("VELENO: l'audio di sistema sintetico viene scartato, il selftest deve fallire.");
            try
            {
                Task.Run(Execute).Wait();
            }
            catch (Exception ex)
            {
                Fail("Errore imprevisto: " + ex);
            }
            Line(failed ? "ESITO: KO" : "ESITO: OK");
            try
            {
                string path = reportPath ?? Path.Combine(AppInfo.DataDirectory, "selftest.txt");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllLines(path, Report);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Rapporto non salvato: " + ex.Message);
            }
            return failed ? 1 : 0;
        }

        private static void Execute()
        {
            Line("Cornetta " + AppInfo.Version + " (" + AppInfo.Build + ") · " + AppInfo.Os + " · " + AppInfo.Arch);
            Line("Eseguibile: " + AppInfo.ExecutablePath);
            Line("Log: " + AppInfo.LogPath);
            Diagnostics.Log("Selftest avviato");

            CheckDevices();
            bool aac = CheckAac();
            string folder = Path.Combine(Path.GetTempPath(), "cornetta-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(folder);
            if (aac) CheckSyntheticFile(Path.Combine(folder, "sintetico.m4a"));
            CheckSyntheticFile(Path.Combine(folder, "sintetico.wav"));
            CheckRecovery(folder);
            Line("File di prova in " + folder);
        }

        private static void CheckDevices()
        {
            var devices = AudioDevices.Describe();
            Line("Ingressi attivi: " + devices.ActiveInputs + " · per le chiamate: " + (devices.Input ?? "nessuno")
                + (devices.GeneralInput != null && devices.GeneralInput != devices.Input ? " · predefinito generale: " + devices.GeneralInput : ""));
            Line("Uscite attive: " + devices.ActiveOutputs + " · per le chiamate: " + (devices.Output ?? "nessuna")
                + (devices.GeneralOutput != null && devices.GeneralOutput != devices.Output ? " · predefinita generale: " + devices.GeneralOutput : ""));
            Line("Permesso microfono: " + (MicrophonePrivacy.IsAllowed() ? "sì" : "no"));
            Line("App che usano il microfono: " + string.Join(", ", CallDetector.CallApps(MicrophoneUsage.Read()).Select(a => a.Name)));
            if (devices.Input == null && devices.Output == null)
            {
                Line("Nessun dispositivo audio su questa macchina: salto la cattura reale (normale su un server CI).");
                return;
            }
            string path = Path.Combine(Path.GetTempPath(), "cornetta-selftest-cattura" + RecordingFiles.Extension);
            try
            {
                var recorder = new Recorder(path, Path.Combine(Path.GetTempPath(), "cornetta-selftest-lavoro"));
                recorder.Start(MicrophonePrivacy.IsAllowed());
                Line("Cattura avviata: microfono " + (recorder.MicrophoneName ?? "nessuno") + ", uscita " + (recorder.OutputName ?? "nessuna")
                     + (recorder.GeneralOutputName != null ? " + predefinita generale " + recorder.GeneralOutputName : ""));
                Thread.Sleep(1500);
                var stats = recorder.Stop();
                Line("Cattura reale: " + Diagnostics.F(stats.Seconds, 2) + " s scritti, picco microfono " + Diagnostics.F(stats.MicPeakRms, 4)
                     + ", picco sistema " + Diagnostics.F(stats.SystemPeakRms, 4) + " → " + recorder.OutputPath);
                if (stats.Seconds < 1.0) Fail("La cattura reale ha scritto meno di un secondo");
            }
            catch (Exception ex)
            {
                Fail("Cattura reale non riuscita: " + ex.Message);
            }
        }

        private static bool CheckAac()
        {
            if (RecordingFiles.AacAvailable)
            {
                var rates = MediaFoundationEncoder.GetEncodeBitrates(AudioSubtypes.MFAudioFormat_AAC, 48000, 2);
                Line("Encoder AAC disponibile (bitrate a 48 kHz stereo: " + string.Join(", ", rates.Select(r => r.ToString(CultureInfo.InvariantCulture))) + ")");
                return true;
            }
            Fail("Encoder AAC NON disponibile: Cornetta registrerebbe in WAV (su Windows N serve il Media Feature Pack).");
            return false;
        }

        /// <summary>
        /// Tre secondi: microfono a 44,1 kHz mono molto basso (deve passare dal resampler e dal livellatore),
        /// sistema stereo a 48 kHz solo fra 1,0 e 2,0 s (deve finire nel punto giusto dopo il silenzio).
        /// </summary>
        private static void CheckSyntheticFile(string path)
        {
            const int seconds = 3;
            string working = Path.Combine(Path.GetDirectoryName(path)!, "In corso", Path.GetFileNameWithoutExtension(path) + "-" + Path.GetExtension(path).TrimStart('.') + ".wav");
            using (var sink = new WavRecordingSink(working))
            {
                var pipeline = new RecordingPipeline(sink);
                var micResampler = new StreamResampler(44_100, 48_000, 1);
                int micPhase = 0;
                int systemPhase = 0;
                for (int block = 1; block <= seconds * 100; block++)
                {
                    long arrival = block * 480L;
                    var mic = new float[441];
                    for (int i = 0; i < mic.Length; i++, micPhase++) mic[i] = 0.007f * (float)Math.Sin(2 * Math.PI * 220 * micPhase / 44_100.0);
                    pipeline.Microphone.Write(arrival, micResampler.Process(mic));
                    if (!poison && arrival > 48_000 && arrival <= 96_000)
                    {
                        var system = new float[480 * 2];
                        for (int i = 0; i < 480; i++, systemPhase++)
                        {
                            float s = 0.3f * (float)Math.Sin(2 * Math.PI * 440 * systemPhase / 48_000.0);
                            system[i * 2] = s;
                            system[i * 2 + 1] = -s;
                        }
                        pipeline.System.Write(arrival, system);
                    }
                    if (block % 2 == 0) pipeline.Render(arrival - 16_800); // 350 ms di ritardo, come il mixer vero
                }
                pipeline.Render(seconds * 48_000L);
                sink.Close();
                if (sink.Error != null) { Fail("Scrittura di " + Path.GetFileName(path) + ": " + sink.Error.Message); return; }
                Line("Mix sintetico: guadagno voce finale " + Diagnostics.F(pipeline.MicGain, 1) + ", buchi del sistema riempiti " + pipeline.System.GapsFilled);
                if (pipeline.MicGain < 4) Fail("Il livellatore non ha alzato la voce sintetica (guadagno " + Diagnostics.F(pipeline.MicGain, 1) + ")");
            }
            string saved = RecordingFiles.Finalize(working, path);
            if (saved != path) { Fail("Conversione di " + Path.GetFileName(path) + " non riuscita: salvato " + Path.GetFileName(saved)); return; }

            var info = new FileInfo(path);
            if (!info.Exists || info.Length < 2000)
            {
                Fail(Path.GetFileName(path) + " mancante o vuoto");
                return;
            }
            try
            {
                using (var reader = path.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) ? (WaveStream)new WaveFileReader(path) : new MediaFoundationReader(path))
                {
                    var provider = reader.ToSampleProvider();
                    int channels = provider.WaveFormat.Channels;
                    int rate = provider.WaveFormat.SampleRate;
                    var all = new List<float>();
                    var buffer = new float[rate * channels];
                    int read;
                    while ((read = provider.Read(buffer, 0, buffer.Length)) > 0) all.AddRange(buffer.Take(read));
                    double duration = all.Count / (double)(rate * channels);
                    // Primo secondo: solo la voce. Secondo secondo: voce più sistema, molto più forte.
                    float first = Rms(all, (int)(0.5 * rate) * channels, (int)(0.9 * rate) * channels);
                    float second = Rms(all, (int)(1.2 * rate) * channels, (int)(1.8 * rate) * channels);
                    Line(Path.GetFileName(path) + ": " + info.Length + " byte, " + rate + " Hz, " + channels + " canali, "
                         + Diagnostics.F(duration, 2) + " s, livello voce " + Diagnostics.F(first, 4) + ", voce+sistema " + Diagnostics.F(second, 4));
                    if (rate != 48_000 || channels != 2) Fail("Formato inatteso");
                    if (duration < seconds - 0.2 || duration > seconds + 0.3) Fail("Durata inattesa");
                    if (first < 0.01) Fail("La voce sintetica non si sente");
                    if (second < first * 2) Fail("L'audio di sistema non è finito nel punto giusto");
                }
            }
            catch (Exception ex)
            {
                Fail("Rilettura di " + Path.GetFileName(path) + " non riuscita: " + ex.Message);
            }
        }

        /// <summary>
        /// Tre secondi nel WAV di lavoro, poi il processo «muore»: si copia quello che c'è sul disco senza chiudere il file.
        /// Il recupero dell'avvio deve salvare una registrazione di almeno 2,5 secondi.
        /// </summary>
        private static void CheckRecovery(string folder)
        {
            string workingFolder = Path.Combine(folder, "interrotta");
            string working = Path.Combine(workingFolder, "Chiamata interrotta.wav");
            try
            {
                using (var sink = new WavRecordingSink(Path.Combine(folder, "aperto.wav")))
                {
                    int phase = 0;
                    for (int block = 0; block < 300; block++)
                    {
                        var samples = new float[480 * 2];
                        for (int i = 0; i < 480; i++, phase++) samples[i * 2] = samples[i * 2 + 1] = 0.3f * (float)Math.Sin(2 * Math.PI * 440 * phase / 48_000.0);
                        sink.Write(samples, 480);
                    }
                    Directory.CreateDirectory(workingFolder);
                    using (var source = new FileStream(sink.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (var target = File.Create(working))
                    {
                        source.CopyTo(target);
                    }
                }
                var saved = RecordingFiles.Recover(WorkingFiles.Leftovers(workingFolder), folder);
                if (saved.Count != 1) { Fail("Recupero della registrazione interrotta non riuscito"); return; }
                string path = Path.Combine(folder, saved[0]);
                using (var reader = path.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) ? (WaveStream)new WaveFileReader(path) : new MediaFoundationReader(path))
                {
                    double duration = reader.TotalTime.TotalSeconds;
                    Line("Recupero: " + saved[0] + ", " + Diagnostics.F(duration, 2) + " s");
                    if (duration < 2.5) Fail("La registrazione recuperata dura solo " + Diagnostics.F(duration, 2) + " s");
                }
                if (File.Exists(working)) Fail("Il recupero ha lasciato il WAV di lavoro");
            }
            catch (Exception ex)
            {
                Fail("Recupero della registrazione interrotta: " + ex.Message);
            }
        }

        private static float Rms(List<float> samples, int from, int to)
        {
            to = Math.Min(to, samples.Count);
            if (to <= from) return 0;
            double sum = 0;
            for (int i = from; i < to; i++) sum += samples[i] * samples[i];
            return (float)Math.Sqrt(sum / (to - from));
        }

        private static void Line(string text)
        {
            Report.Add(text);
            Console.WriteLine(text);
        }

        private static void Fail(string text)
        {
            failed = true;
            Line("ERRORE: " + text);
            Diagnostics.Log("Selftest: " + text);
        }

        internal static string? ArgumentAfter(string[] args, string name)
        {
            int index = Array.FindIndex(args, a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }
    }

    /// <summary>
    /// Registrazione senza interfaccia, per provare la cattura su un PC vero:
    ///   Cornetta.exe --record 10 --out C:\prova.m4a
    /// Scrive il file e accanto le statistiche (C:\prova.m4a.json).
    /// </summary>
    internal static class Headless
    {
        public static int Run(string[] args)
        {
            ConsoleOutput.Attach();
            string secondsText = SelfTest.ArgumentAfter(args, "--record") ?? "10";
            double seconds = double.TryParse(secondsText, NumberStyles.Float, CultureInfo.InvariantCulture, out var s) ? s : 10;
            string output = SelfTest.ArgumentAfter(args, "--out")
                ?? FileNaming.RecordingPath(AppInfo.RecordingsDirectory, DateTime.Now, null, RecordingFiles.Extension);
            try
            {
                string json = "";
                Task.Run(() =>
                {
                    var recorder = new Recorder(output);
                    recorder.Start(MicrophonePrivacy.IsAllowed());
                    Console.WriteLine("Registro " + seconds.ToString(CultureInfo.InvariantCulture) + " s · microfono " + (recorder.MicrophoneName ?? "nessuno")
                        + " · uscita " + (recorder.OutputName ?? "nessuna") + " → " + output);
                    Thread.Sleep(TimeSpan.FromSeconds(seconds));
                    var stats = recorder.Stop();
                    output = recorder.OutputPath;
                    json = stats.ToJson();
                }).Wait();
                File.WriteAllText(output + ".json", json);
                Console.WriteLine(json);
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Registrazione non riuscita: " + ex.GetBaseException().Message);
                return 1;
            }
        }
    }

    /// <summary>Un'app WinExe non ha console: se lanciata dal prompt, scrive su quella del chiamante.</summary>
    internal static class ConsoleOutput
    {
        public static void Attach()
        {
            if (Console.IsOutputRedirected)
            {
                // Output su file o pipe (CI): UTF-8, così «·» e le lettere accentate restano leggibili.
                Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
                return;
            }
            if (NativeMethods.AttachConsole(NativeMethods.ATTACH_PARENT_PROCESS))
            {
                try { Console.OutputEncoding = new System.Text.UTF8Encoding(false); } catch (Exception) { }
                var stdout = new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true };
                Console.SetOut(stdout);
                Console.WriteLine();
            }
        }
    }
}
