using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Cornetta.Core
{
    /// <summary>Log tecnico: su Windows sta in %LOCALAPPDATA%\Cornetta\cornetta.log (il precedente in cornetta.1.log).</summary>
    public static class Diagnostics
    {
        private static readonly object Gate = new object();
        /// <summary>Oltre questa dimensione il log passa a cornetta.1.log, che sostituisce il precedente.</summary>
        public const long MaxFileBytes = 2 * 1024 * 1024;
        /// <summary>Tail legge solo la coda del file: il feedback non rilegge mesi di log.</summary>
        public const int TailBytes = 64 * 1024;

        /// <summary>Percorso del file di log. Lo imposta l'app all'avvio.</summary>
        public static string? FilePath { get; set; }

        /// <summary>Scrive una riga con l'orario ISO 8601 in UTC, come il Mac.</summary>
        public static void Log(string message)
        {
            string line = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture) + " " + message + "\n";
            System.Diagnostics.Debug.Write(line);
            string? path = FilePath;
            if (path == null) return;
            lock (Gate)
            {
                try
                {
                    string? dir = Path.GetDirectoryName(path);
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                // Un file tenuto aperto da un altro programma (antivirus, editor) blocca la rotazione, non la riga.
                try { Rotate(path, MaxFileBytes); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                try { File.AppendAllText(path, line, new UTF8Encoding(false)); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        /// <summary>Le ultime righe del log, per il feedback.</summary>
        public static IEnumerable<string> Tail(int count)
        {
            string? path = FilePath;
            if (path == null || !File.Exists(path)) return Enumerable.Empty<string>();
            try
            {
                lock (Gate) return Tail(path, count, TailBytes);
            }
            catch (IOException) { return Enumerable.Empty<string>(); }
            catch (UnauthorizedAccessException) { return Enumerable.Empty<string>(); }
        }

        /// <summary>Le ultime <paramref name="count"/> righe fra gli ultimi <paramref name="maxBytes"/> byte del file.</summary>
        public static List<string> Tail(string path, int count, int maxBytes)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long start = Math.Max(0, stream.Length - maxBytes);
                stream.Seek(start, SeekOrigin.Begin);
                var bytes = new byte[stream.Length - start];
                int read = 0, n;
                while (read < bytes.Length && (n = stream.Read(bytes, read, bytes.Length - read)) > 0) read += n;
                var lines = Encoding.UTF8.GetString(bytes, 0, read).Split('\n').Select(l => l.TrimEnd('\r')).ToList();
                // Da metà file la prima riga è tagliata; l'ultimo «\n» lascia una riga vuota.
                if (start > 0 && lines.Count > 0) lines.RemoveAt(0);
                if (lines.Count > 0 && lines[lines.Count - 1].Length == 0) lines.RemoveAt(lines.Count - 1);
                return lines.Skip(Math.Max(0, lines.Count - count)).ToList();
            }
        }

        /// <summary>Se il file supera <paramref name="maxBytes"/>, lo sposta in cornetta.1.log (sovrascrivendo il precedente).</summary>
        public static void Rotate(string path, long maxBytes)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length < maxBytes) return;
            string old = RotatedPath(path);
            File.Delete(old);
            File.Move(path, old);
        }

        /// <summary>cornetta.log → cornetta.1.log.</summary>
        public static string RotatedPath(string path) => Path.ChangeExtension(path, ".1" + Path.GetExtension(path));

        /// <summary>Formatta i numeri col punto, come il Mac («%.2f»).</summary>
        public static string F(double value, int decimals) =>
            value.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
    }
}
