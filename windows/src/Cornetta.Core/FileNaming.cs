using System;
using System.Globalization;
using System.IO;

namespace Cornetta.Core
{
    /// <summary>Cartella e nome dei file registrati. Porta di Sources/CornettaCore/FileNaming.swift.</summary>
    public static class FileNaming
    {
        /// <summary>«Musica\Cornetta» dentro la cartella Musica indicata.</summary>
        public static string DefaultDirectory(string musicFolder) => Path.Combine(musicFolder, "Cornetta");

        /// <summary>
        /// «Chiamata 2026-10-14 09.12.m4a». Se il file esiste aggiunge « (2)», « (3)» e così via.
        /// </summary>
        public static string RecordingPath(string directory, DateTime date, Func<string, bool>? fileExists = null, string extension = ".m4a")
        {
            string stamp = date.ToString("yyyy-MM-dd HH.mm", CultureInfo.InvariantCulture);
            return UniquePath(directory, "Chiamata " + stamp, extension, fileExists);
        }

        /// <summary>«nome.m4a» nella cartella, oppure «nome (2).m4a» e così via se esiste già.</summary>
        public static string UniquePath(string directory, string baseName, string extension, Func<string, bool>? fileExists = null)
        {
            var exists = fileExists ?? File.Exists;
            string candidate = Path.Combine(directory, baseName + extension);
            int counter = 2;
            while (exists(candidate))
            {
                candidate = Path.Combine(directory, baseName + " (" + counter.ToString(CultureInfo.InvariantCulture) + ")" + extension);
                counter++;
            }
            return candidate;
        }
    }
}
