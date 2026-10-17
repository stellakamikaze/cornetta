using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using Cornetta.Core;
using Microsoft.Win32;

namespace Cornetta.App
{
    internal static class AppInfo
    {
        /// <summary>Indirizzo del servizio (feedback, download, aggiornamenti).</summary>
        public const string ServiceUrl = "https://cornetta.stellakamikaze.org";
        public const string FeedbackUrl = ServiceUrl + "/api/feedback";
        public const string UpdateFeedUrl = ServiceUrl + "/windows/";

        /// <summary>
        /// Chiave pubblica ECDSA P-256 che firma il feed (releases.win.json.sig), in esadecimale: X||Y, 128 cifre.
        /// Come si genera e dove sta la privata: docs/SERVIZIO.md, «Chiave del feed Windows». windows/tools/sign-feed.py
        /// legge questa riga e la CI dei tag si ferma finché vale FeedSignature.Placeholder.
        /// </summary>
        public const string UpdateFeedPublicKey = FeedSignature.Placeholder;

        public static string Version
        {
            get
            {
                var info = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
                if (string.IsNullOrEmpty(info)) return "dev";
                int plus = info!.IndexOf('+');
                return plus > 0 ? info.Substring(0, plus) : info;
            }
        }

        public static string Build =>
            Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(a => a.Key == "CornettaBuild")?.Value ?? "dev";

        public static string ExecutablePath => Assembly.GetExecutingAssembly().Location;

        /// <summary>%LOCALAPPDATA%\Cornetta: log e impostazioni tecniche.</summary>
        public static string DataDirectory =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cornetta");

        public static string LogPath => Path.Combine(DataDirectory, "cornetta.log");

        /// <summary>Musica\Cornetta (la cartella Musica dell'utente, anche se spostata su OneDrive).</summary>
        public static string RecordingsDirectory
        {
            get
            {
                string music = Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);
                if (string.IsNullOrEmpty(music))
                {
                    music = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music");
                }
                return FileNaming.DefaultDirectory(music);
            }
        }

        public static string Arch
        {
            get
            {
                string os = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
                string process = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
                return os == process ? os : os + " (processo " + process + ")";
            }
        }

        /// <summary>«Windows 11 23H2 (build 22631.4317)».</summary>
        public static string Os
        {
            get
            {
                try
                {
                    using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                    {
                        string build = key?.GetValue("CurrentBuild") as string ?? "";
                        string display = key?.GetValue("DisplayVersion") as string ?? key?.GetValue("ReleaseId") as string ?? "";
                        string product = key?.GetValue("ProductName") as string ?? "Windows";
                        object? ubr = key?.GetValue("UBR");
                        int.TryParse(build, NumberStyles.Integer, CultureInfo.InvariantCulture, out int buildNumber);
                        // ProductName dice «Windows 10» anche su Windows 11: decide il numero di build.
                        if (buildNumber >= 22000) product = product.Replace("Windows 10", "Windows 11");
                        string full = ubr is int u ? build + "." + u.ToString(CultureInfo.InvariantCulture) : build;
                        return (product + " " + display).Trim() + " (build " + full + ")";
                    }
                }
                catch (Exception)
                {
                    return Environment.OSVersion.VersionString;
                }
            }
        }

        public static FeedbackAppInfo FeedbackInfo(string? microphone) => new FeedbackAppInfo
        {
            Version = Version,
            Build = Build,
            Os = Os,
            Arch = Arch,
            Microphone = microphone ?? "",
        };

        /// <summary>Informazioni tecniche allegate al feedback. Niente audio, niente contenuti delle chiamate.</summary>
        public static string DiagnosticsText(string? microphone)
        {
            var devices = AudioDevices.Describe();
            var lines = new List<string>
            {
                "Cornetta " + Version + " (" + Build + ") · " + Os + " · " + Arch,
                "App: " + ExecutablePath,
                "Microfono: " + (microphone ?? devices.Input ?? "nessuno"),
                "Uscita: " + (devices.Output ?? "nessuna"),
            };
            if (devices.GeneralInput != null && devices.GeneralInput != devices.Input)
                lines.Add("Ingresso predefinito generale (non usato): " + devices.GeneralInput);
            if (devices.GeneralOutput != null && devices.GeneralOutput != devices.Output)
                lines.Add("Uscita predefinita generale (non usata): " + devices.GeneralOutput);
            lines.Add("Permesso microfono: " + (MicrophonePrivacy.IsAllowed() ? "sì" : "no"));
            lines.Add("App che usano il microfono: " + string.Join(", ", CallDetector.CallApps(MicrophoneUsage.Read()).Select(a => a.Name)));
            lines.Add("Registrazioni: " + RecordingsDirectory);
            lines.Add("");
            lines.Add("--- ultime righe del log ---");
            lines.AddRange(Diagnostics.Tail(120));
            // Il nome utente nei percorsi non serve a capire un guasto (come sul Mac).
            return PathPrivacy.Anonymize(string.Join(Environment.NewLine, lines),
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        }
    }

    /// <summary>Preferenze in HKCU\Software\Cornetta.</summary>
    internal static class Settings
    {
        private const string KeyPath = @"Software\Cornetta";

        public static bool ShowOverlay
        {
            get => GetBool("ShowOverlay", true);
            set => Set("ShowOverlay", value ? 1 : 0);
        }

        /// <summary>Telemetria di funzionamento (vedi Telemetry): accesa di default, si spegne dal menu.</summary>
        public static bool TelemetryEnabled
        {
            get => GetBool("TelemetryEnabled", true);
            set => Set("TelemetryEnabled", value ? 1 : 0);
        }

        public static string TelemetryInstallId
        {
            get => GetString("TelemetryInstallId");
            set => Set("TelemetryInstallId", value);
        }

        public static string TelemetryLastVersion
        {
            get => GetString("TelemetryLastVersion");
            set => Set("TelemetryLastVersion", value);
        }

        public static bool ProposeOnCall
        {
            get => GetBool("ProposeOnCall", true);
            set => Set("ProposeOnCall", value ? 1 : 0);
        }

        public static string FeedbackName
        {
            get => GetString("FeedbackName");
            set => Set("FeedbackName", value);
        }

        public static string FeedbackEmail
        {
            get => GetString("FeedbackEmail");
            set => Set("FeedbackEmail", value);
        }

        /// <summary>Solo per le prove: un altro indirizzo per gli aggiornamenti (come CornettaFeedOverride sul Mac).</summary>
        public static string? FeedOverride
        {
            get { string value = GetString("FeedOverride"); return value.Length > 0 ? value : null; }
        }

        public static (int X, int Y)? OverlayPosition
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(KeyPath))
                {
                    if (key?.GetValue("OverlayX") is int x && key.GetValue("OverlayY") is int y) return (x, y);
                    return null;
                }
            }
            set
            {
                if (value == null) return;
                Set("OverlayX", value.Value.X);
                Set("OverlayY", value.Value.Y);
            }
        }

        private static bool GetBool(string name, bool fallback)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(KeyPath))
                {
                    return key?.GetValue(name) is int v ? v != 0 : fallback;
                }
            }
            catch (Exception) { return fallback; }
        }

        private static string GetString(string name)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(KeyPath))
                {
                    return key?.GetValue(name) as string ?? "";
                }
            }
            catch (Exception) { return ""; }
        }

        private static void Set(string name, object value)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(KeyPath))
                {
                    key?.SetValue(name, value);
                }
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Impostazione non salvata (" + name + "): " + ex.Message);
            }
        }
    }
}
