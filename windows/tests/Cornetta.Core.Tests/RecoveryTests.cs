using System;
using System.IO;
using System.Linq;
using Cornetta.Core;
using NAudio.Wave;
using Xunit;

namespace Cornetta.Core.Tests
{
    public class WorkingRecordingTests : IDisposable
    {
        private readonly string folder = Path.Combine(Path.GetTempPath(), "cornetta-test-" + Guid.NewGuid().ToString("N").Substring(0, 8));

        public WorkingRecordingTests() { Directory.CreateDirectory(folder); }

        public void Dispose()
        {
            try { Directory.Delete(folder, true); } catch (IOException) { }
        }

        private static void WriteTone(WavRecordingSink sink, double seconds)
        {
            int phase = 0;
            for (int block = 0; block < seconds * 100; block++)
            {
                var samples = new float[480 * 2];
                for (int i = 0; i < 480; i++, phase++) samples[i * 2] = samples[i * 2 + 1] = 0.3f * (float)Math.Sin(2 * Math.PI * 440 * phase / 48_000.0);
                sink.Write(samples, 480);
            }
        }

        /// <summary>Quello che resta sul disco se il processo muore adesso: il file aperto, senza la chiusura del writer.</summary>
        private string CrashCopy(string path)
        {
            string copy = Path.Combine(folder, "dopo-il-crash.wav");
            using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var target = File.Create(copy))
            {
                source.CopyTo(target);
            }
            return copy;
        }

        private static double Duration(string path)
        {
            using (var reader = new WaveFileReader(path)) return reader.TotalTime.TotalSeconds;
        }

        [Fact]
        public void InterruptedRecordingIsRecoveredFromTheFileSize()
        {
            string working = Path.Combine(folder, "In corso", "Chiamata.wav");
            string crashed;
            using (var sink = new WavRecordingSink(working))
            {
                WriteTone(sink, 3);
                crashed = CrashCopy(working);
            }
            // Veleno: senza riparazione l'intestazione dice zero byte (nessun Flush entro 5 s) e il file non si apre.
            Assert.Throws<FormatException>(() => Duration(crashed));
            long bytes = WavRepair.Repair(crashed);
            Assert.True(bytes > 0);
            Assert.InRange(Duration(crashed), 2.5, 3.01);
        }

        [Fact]
        public void HeaderIsUpdatedEveryFiveSeconds()
        {
            string working = Path.Combine(folder, "Chiamata.wav");
            using (var sink = new WavRecordingSink(working))
            {
                WriteTone(sink, 6);
                Assert.InRange(Duration(CrashCopy(working)), 5, 6.01);
            }
            Assert.Equal(6, Duration(working), 2);
        }

        [Fact]
        public void HalfFrameAndGarbageAreHandled()
        {
            string working = Path.Combine(folder, "Chiamata.wav");
            using (var sink = new WavRecordingSink(working)) WriteTone(sink, 1);
            using (var stream = new FileStream(working, FileMode.Append)) stream.Write(new byte[] { 1, 2, 3 }, 0, 3);
            Assert.Equal(48_000 * 4, WavRepair.Repair(working));
            Assert.Equal(1, Duration(working), 3);

            string empty = Path.Combine(folder, "vuoto.wav");
            File.WriteAllBytes(empty, new byte[0]);
            Assert.Equal(-1, WavRepair.Repair(empty));
        }

        [Fact]
        public void SizeLimitStopsWithAnError()
        {
            string working = Path.Combine(folder, "Chiamata.wav");
            using (var sink = new WavRecordingSink(working) { MaxDataBytes = 48_000 * 4 })
            {
                WriteTone(sink, 2);
                Assert.NotNull(sink.Error);
            }
            Assert.Equal(1, Duration(working), 2);
        }

        [Fact]
        public void LeftoversAndRecoveredNames()
        {
            string working = Path.Combine(folder, "In corso");
            Assert.Empty(WorkingFiles.Leftovers(working));
            Directory.CreateDirectory(working);
            string file = WorkingFiles.PathFor(working, @"C:\Musica\Cornetta\Chiamata 2026-10-24 10.00.m4a".Replace('\\', Path.DirectorySeparatorChar));
            File.WriteAllBytes(file, new byte[] { 0 });
            File.WriteAllBytes(Path.Combine(working, "Chiamata.parziale.m4a"), new byte[] { 0 });
            Assert.Equal(new[] { file }, WorkingFiles.Leftovers(working));
            Assert.Equal("Chiamata 2026-10-24 10.00.wav", Path.GetFileName(file));

            string taken = Path.Combine(folder, "Chiamata 2026-10-24 10.00.m4a");
            Assert.Equal(Path.Combine(folder, "Chiamata 2026-10-24 10.00 (2).m4a"),
                WorkingFiles.RecoveredPath(file, folder, ".m4a", p => p == taken));
        }
        [Fact]
        public void SavedWavIsNotRecoveredTwice()
        {
            string working = Path.Combine(folder, "In corso");
            Directory.CreateDirectory(working);
            string saved = Path.Combine(working, "Chiamata 2026-10-24 10.00.wav");
            string other = Path.Combine(working, "Chiamata 2026-10-24 11.00.wav");
            File.WriteAllBytes(saved, new byte[] { 0 });
            File.WriteAllBytes(other, new byte[] { 0 });
            // Il .m4a è salvato ma il WAV non si è cancellato (antivirus): resta il marcatore.
            WorkingFiles.MarkSaved(saved, Path.Combine(folder, "Chiamata 2026-10-24 10.00.m4a"));
            Assert.Equal(Path.Combine(working, "Chiamata 2026-10-24 10.00.salvato"), WorkingFiles.SavedMarkerFor(saved));

            // Senza marcatore il recupero lo salverebbe di nuovo come «(2).m4a».
            Assert.Equal(new[] { other }, WorkingFiles.Leftovers(working));
            Assert.False(File.Exists(saved));
            Assert.False(File.Exists(WorkingFiles.SavedMarkerFor(saved)));
            Assert.True(File.Exists(other));

            // Un marcatore rimasto senza WAV sparisce anche lui.
            File.WriteAllText(Path.Combine(working, "Vecchia.salvato"), "x");
            Assert.Equal(new[] { other }, WorkingFiles.Leftovers(working));
            Assert.False(File.Exists(Path.Combine(working, "Vecchia.salvato")));
        }

        [Fact]
        public void WorkingDirectoryIsOutsideTheInstallRoot()
        {
            // Velopack cancella %LOCALAPPDATA%\<packId> alla disinstallazione e alla riparazione da CornettaSetup.exe.
            string workflow = File.ReadAllText(Path.Combine(RepoRoot(), ".github", "workflows", "windows.yml"));
            var packId = System.Text.RegularExpressions.Regex.Match(workflow, @"--packId\s+(\S+)");
            Assert.True(packId.Success, "--packId non trovato in windows.yml");
            Assert.Equal(WorkingFiles.InstallRootName, packId.Groups[1].Value);

            string localAppData = Path.Combine(folder, "AppData", "Local");
            string root = Path.Combine(localAppData, WorkingFiles.InstallRootName) + Path.DirectorySeparatorChar;
            string working = WorkingFiles.DefaultDirectory(localAppData) + Path.DirectorySeparatorChar;
            Assert.StartsWith(localAppData + Path.DirectorySeparatorChar, working);
            Assert.False(working.StartsWith(root, StringComparison.OrdinalIgnoreCase), working + " sta dentro " + root);
        }

        private static string RepoRoot()
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, ".github", "workflows", "windows.yml"))) return dir.FullName;
            }
            throw new DirectoryNotFoundException("Radice del repository non trovata da " + AppContext.BaseDirectory);
        }
    }

    public class DeviceChangeTests
    {
        [Fact]
        public void GeneralDefaultChangeRestartsOnlyTheSecondOutput()
        {
            // Veleno storico: ogni cambio di uscita riavviava anche il loopback delle chiamate.
            Assert.Equal(DeviceRestart.GeneralOutput, DeviceChange.For(capture: false, callRole: false, consoleRole: true));
            Assert.Equal(DeviceRestart.CallOutput, DeviceChange.For(capture: false, callRole: true, consoleRole: false));
            Assert.Equal(DeviceRestart.Microphone, DeviceChange.For(capture: true, callRole: true, consoleRole: false));
            // Il microfono è solo quello di Comunicazioni; Multimedia non conta.
            Assert.Equal(DeviceRestart.None, DeviceChange.For(capture: true, callRole: false, consoleRole: true));
            Assert.Equal(DeviceRestart.None, DeviceChange.For(capture: false, callRole: false, consoleRole: false));
        }

        [Fact]
        public void CallOutputOnTheGeneralDefaultRestartsEverything()
        {
            Assert.False(DeviceChange.CallOutputMoved("{cuffie}", "{cuffie}"));
            // Senza ruolo Comunicazioni l'uscita delle chiamate è il predefinito generale, appena cambiato.
            Assert.True(DeviceChange.CallOutputMoved("{hdmi}", "{altoparlanti}"));
            Assert.True(DeviceChange.CallOutputMoved("{cuffie}", null));
            Assert.False(DeviceChange.CallOutputMoved(null, null));
        }
    }

    public class SilenceWatchTests
    {
        /// <summary>Secondi di registrazione con il microfono vivo e l'audio di sistema dato da <paramref name="system"/>.</summary>
        private static RecordingPipeline Record(double seconds, Func<long, float> system, RecordingPipeline? pipeline = null, long from = 0)
        {
            pipeline ??= new RecordingPipeline(new MemorySink());
            for (long t = from + 480; t <= from + (long)(seconds * 48_000); t += 480)
            {
                pipeline.Microphone.Write(t, Enumerable.Repeat(0.05f, 480).ToArray());
                var block = new float[960];
                for (int i = 0; i < 480; i++) block[i * 2] = block[i * 2 + 1] = system(t - 480 + i);
                pipeline.System.Write(t, block);
                pipeline.Render(t);
            }
            return pipeline;
        }

        [Fact]
        public void MutedOthersDuringACallAreReportedOnce()
        {
            var watch = new SilenceWatch();
            watch.NoteCallApps(1);
            var pipeline = Record(20, _ => 0);
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
            Record(10, _ => 0, pipeline, 20 * 48_000);
            Assert.Equal(SilenceAlert.OthersMuted, watch.Check(pipeline.Stats));
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
        }

        [Fact]
        public void NoCallAppNoWarning()
        {
            var watch = new SilenceWatch();
            watch.NoteCallApps(0);
            Assert.Equal(SilenceAlert.None, watch.Check(Record(30, _ => 0).Stats));
        }

        [Fact]
        public void OneNonZeroSampleSilencesTheWarning()
        {
            var watch = new SilenceWatch();
            watch.NoteCallApps(2);
            var pipeline = Record(30, t => t == 96_000 ? 0.001f : 0);
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
        }

        [Fact]
        public void LongSilenceMidCallGoesToTheLogOncePerStreak()
        {
            var watch = new SilenceWatch();
            watch.NoteCallApps(1);
            var pipeline = Record(5, _ => 0.2f);
            Record(119, _ => 0, pipeline, 5 * 48_000);
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
            Record(2, _ => 0, pipeline, 124 * 48_000);
            Assert.Equal(SilenceAlert.LongSilence, watch.Check(pipeline.Stats));
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
            Record(1, _ => 0.2f, pipeline, 126 * 48_000);
            Assert.Equal(SilenceAlert.None, watch.Check(pipeline.Stats));
            Assert.Equal(0, pipeline.Stats.SystemSilentSeconds, 3);
        }
    }

    public class DiagnosticsTests : IDisposable
    {
        private readonly string folder = Path.Combine(Path.GetTempPath(), "cornetta-log-" + Guid.NewGuid().ToString("N").Substring(0, 8));

        public DiagnosticsTests() { Directory.CreateDirectory(folder); }

        public void Dispose()
        {
            try { Directory.Delete(folder, true); } catch (IOException) { }
        }

        [Fact]
        public void LogRotatesPastTheLimit()
        {
            string path = Path.Combine(folder, "cornetta.log");
            File.WriteAllText(path, new string('a', 100));
            Diagnostics.Rotate(path, 200);
            Assert.True(File.Exists(path));
            File.AppendAllText(path, new string('b', 150));
            File.WriteAllText(Path.Combine(folder, "cornetta.1.log"), "vecchio");
            Diagnostics.Rotate(path, 200);
            Assert.False(File.Exists(path));
            Assert.Equal(250, new FileInfo(Path.Combine(folder, "cornetta.1.log")).Length);
        }

        [Fact]
        public void TailReadsOnlyTheEndOfTheFile()
        {
            string path = Path.Combine(folder, "cornetta.log");
            File.WriteAllText(path, string.Concat(Enumerable.Range(1, 1000).Select(i => "riga " + i + " è qui\n")));
            var last = Diagnostics.Tail(path, 3, 64 * 1024);
            Assert.Equal(new[] { "riga 998 è qui", "riga 999 è qui", "riga 1000 è qui" }, last);
            // Dalla metà del file: la prima riga, tagliata, non compare.
            var lines = Diagnostics.Tail(path, 1000, 100);
            Assert.All(lines, l => Assert.StartsWith("riga ", l));
            Assert.Equal("riga 1000 è qui", lines.Last());
            Assert.True(lines.Count < 10);
        }
    }
}
