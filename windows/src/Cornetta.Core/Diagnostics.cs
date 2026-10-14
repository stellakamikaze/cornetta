using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Cornetta.Core
{
    /// <summary>Log tecnico: su Windows sta in %LOCALAPPDATA%\Cornetta\cornetta.log.</summary>
    public static class Diagnostics
    {
        private static readonly object Gate = new object();

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
                    File.AppendAllText(path, line, new UTF8Encoding(false));
                }
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
                lock (Gate)
                {
                    var lines = File.ReadAllLines(path, Encoding.UTF8);
                    return lines.Skip(Math.Max(0, lines.Length - count)).ToList();
                }
            }
            catch (IOException) { return Enumerable.Empty<string>(); }
            catch (UnauthorizedAccessException) { return Enumerable.Empty<string>(); }
        }

        /// <summary>Formatta i numeri col punto, come il Mac («%.2f»).</summary>
        public static string F(double value, int decimals) =>
            value.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
    }
}
