using System.Text.RegularExpressions;

namespace Cornetta.Core
{
    /// <summary>
    /// Toglie il nome utente dai percorsi della diagnostica del feedback, come fa il Mac (Sources/Cornetta/AppInfo.swift):
    /// il nome non serve a capire un guasto. La cartella dell'utente diventa «~», ogni altro C:\Users\nome diventa
    /// C:\Users\&lt;utente&gt;.
    /// </summary>
    public static class PathPrivacy
    {
        private static readonly Regex UsersFolder = new Regex(
            @"\b([A-Za-z]:[\\/]Users[\\/])[^\\/\r\n""<>|:*?]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        public static string Anonymize(string text, string? userProfile)
        {
            if (string.IsNullOrEmpty(text)) return text;
            string profile = (userProfile ?? "").TrimEnd('\\', '/');
            if (profile.Length > 3)
            {
                // Con le barre in tutte e due le direzioni: nei log a volte compare C:/Users/nome.
                string pattern = Regex.Escape(profile).Replace(@"\\", @"[\\/]") + @"(?![\w. -])";
                text = Regex.Replace(text, pattern, "~", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            }
            return UsersFolder.Replace(text, "$1<utente>");
        }
    }
}
