using System;
using System.IO;
using System.Linq;
using System.Text;
using NAudio.Wave;

namespace Cornetta.Core
{
    /// <summary>
    /// Il file di lavoro durante la registrazione: PCM 16 bit stereo a 48 kHz in un WAV, che resta leggibile anche se
    /// l'app muore (crash, chiusura da Gestione attività, PC spento). Ogni 5 s aggiorna l'intestazione e scrive su disco;
    /// dopo un crash WavRepair ricava la durata dalla dimensione del file. Allo stop l'app lo converte in AAC.
    /// Porta dei CAF di lavoro del Mac (RecordingFinalizer.swift). Va usato da un solo thread (quello del mixer).
    /// </summary>
    public sealed class WavRecordingSink : IAudioSink, IDisposable
    {
        public static readonly WaveFormat Format = new WaveFormat(RecordingPipeline.SampleRate, 16, 2);
        public const int FlushSeconds = 5;

        private readonly FileStream stream;
        private WaveFileWriter? writer;
        private long framesSinceFlush;

        public WavRecordingSink(string path)
        {
            Path = path;
            string? dir = System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            writer = new WaveFileWriter(stream, Format);
        }

        public string Path { get; }
        /// <summary>Errore di scrittura, se c'è stato. Il mixer lo controlla e ferma la registrazione.</summary>
        public Exception? Error { get; private set; }
        /// <summary>Il WAV ha lunghezze a 32 bit: oltre circa 6 ore la registrazione si ferma e si salva.</summary>
        public long MaxDataBytes { get; set; } = (uint.MaxValue - 1024L) / 4 * 4;

        public void Write(float[] interleavedStereo, int frames)
        {
            if (writer == null || Error != null) return;
            try
            {
                var bytes = AudioConversion.ToPcm16(interleavedStereo, frames * 2);
                if (writer.Length + bytes.Length > MaxDataBytes)
                {
                    Error = new IOException("Raggiunto il limite di 6 ore per registrazione.");
                    return;
                }
                writer.Write(bytes, 0, bytes.Length);
                framesSinceFlush += frames;
                if (framesSinceFlush >= FlushSeconds * RecordingPipeline.SampleRate)
                {
                    framesSinceFlush = 0;
                    writer.Flush();
                    stream.Flush(true);
                }
            }
            catch (Exception ex)
            {
                Error = ex;
            }
        }

        /// <summary>Scrive l'intestazione definitiva e chiude il file.</summary>
        public void Close()
        {
            writer?.Dispose();
            writer = null;
        }

        public void Dispose() => Close();
    }

    /// <summary>Intestazione WAV dopo un crash: le lunghezze dicono quanto audio c'era all'ultimo aggiornamento, o zero.</summary>
    public static class WavRepair
    {
        /// <summary>
        /// Riscrive le lunghezze di RIFF e data dalla dimensione del file e toglie un frame scritto a metà.
        /// Restituisce i byte di audio, oppure -1 se il file non è un WAV leggibile.
        /// </summary>
        public static long Repair(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            using (var reader = new BinaryReader(stream, Encoding.ASCII, true))
            using (var writer = new BinaryWriter(stream, Encoding.ASCII, true))
            {
                if (stream.Length < 12 || Id(reader) != "RIFF") return -1;
                reader.ReadUInt32();
                if (Id(reader) != "WAVE") return -1;
                int blockAlign = 0;
                while (stream.Position + 8 <= stream.Length)
                {
                    string id = Id(reader);
                    uint size = reader.ReadUInt32();
                    long body = stream.Position;
                    if (id == "fmt " && size >= 16)
                    {
                        stream.Position = body + 12;
                        blockAlign = reader.ReadUInt16();
                    }
                    if (id == "data")
                    {
                        if (blockAlign <= 0) return -1;
                        long bytes = (stream.Length - body) / blockAlign * blockAlign;
                        stream.SetLength(body + bytes);
                        stream.Position = 4;
                        writer.Write((uint)(stream.Length - 8));
                        stream.Position = body - 4;
                        writer.Write((uint)bytes);
                        writer.Flush();
                        return bytes;
                    }
                    stream.Position = body + size + (size & 1);
                }
                return -1;
            }
        }

        private static string Id(BinaryReader reader) => Encoding.ASCII.GetString(reader.ReadBytes(4));
    }

    /// <summary>Dove stanno i file di lavoro: %LOCALAPPDATA%\Cornetta Dati\In corso\«nome della registrazione».wav.</summary>
    public static class WorkingFiles
    {
        /// <summary>Il packId di Velopack (.github/workflows/windows.yml): la radice d'installazione è %LOCALAPPDATA%\Cornetta.</summary>
        public const string InstallRootName = "Cornetta";

        /// <summary>
        /// La cartella dei file di lavoro, fuori dalla radice d'installazione: la disinstallazione e la riparazione da
        /// CornettaSetup.exe la cancellano per intero, con le registrazioni interrotte che aspettano il recupero.
        /// </summary>
        public static string DefaultDirectory(string localAppData) => Path.Combine(localAppData, InstallRootName + " Dati", "In corso");

        public static string PathFor(string workingDirectory, string recordingPath) =>
            Path.Combine(workingDirectory, Path.GetFileNameWithoutExtension(recordingPath) + ".wav");

        /// <summary>Il marcatore accanto a un WAV già salvato nella cartella delle registrazioni ma non cancellato.</summary>
        public static string SavedMarkerFor(string workingFile) => Path.ChangeExtension(workingFile, ".salvato");

        /// <summary>
        /// Il WAV è già salvato in <paramref name="savedPath"/> ma non si cancella (antivirus, app chiusa a metà): il marcatore
        /// dice al recupero di non salvarlo una seconda volta. Crearlo non richiede accesso al WAV bloccato.
        /// </summary>
        public static void MarkSaved(string workingFile, string savedPath) =>
            File.WriteAllText(SavedMarkerFor(workingFile), savedPath, Encoding.UTF8);

        /// <summary>
        /// File di lavoro rimasti da una sessione interrotta. Va letto all'avvio, prima di qualunque registrazione.
        /// I WAV col marcatore sono già salvati: li cancella, se adesso si può, e non li restituisce.
        /// </summary>
        public static string[] Leftovers(string workingDirectory)
        {
            if (!Directory.Exists(workingDirectory)) return new string[0];
            foreach (string marker in Directory.GetFiles(workingDirectory, "*.salvato"))
            {
                try
                {
                    File.Delete(Path.ChangeExtension(marker, ".wav"));
                    File.Delete(marker);
                }
                catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
                {
                    // Ancora bloccato: resta col marcatore, si riprova al prossimo avvio.
                }
            }
            return Directory.GetFiles(workingDirectory, "*.wav")
                .Where(p => !File.Exists(SavedMarkerFor(p)))
                .OrderBy(p => p, StringComparer.Ordinal).ToArray();
        }

        /// <summary>Dove va una registrazione recuperata: stesso nome nella cartella delle registrazioni, con « (2)» se esiste già.</summary>
        public static string RecoveredPath(string workingFile, string recordingsDirectory, string extension, Func<string, bool>? fileExists = null) =>
            FileNaming.UniquePath(recordingsDirectory, Path.GetFileNameWithoutExtension(workingFile), extension, fileExists);
    }
}
