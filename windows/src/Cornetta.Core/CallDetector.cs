using System;
using System.Collections.Generic;
using System.Linq;

namespace Cornetta.Core
{
    /// <summary>
    /// Una voce del registro di Windows sull'uso del microfono:
    /// HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone.
    /// Le app packaged hanno la sottochiave col nome del pacchetto, le altre stanno sotto NonPackaged
    /// col percorso dell'eseguibile (le barre diventano #).
    /// </summary>
    public sealed class MicrophoneUse
    {
        public MicrophoneUse(string key, bool packaged, long lastUsedTimeStart, long lastUsedTimeStop)
        {
            Key = key;
            Packaged = packaged;
            LastUsedTimeStart = lastUsedTimeStart;
            LastUsedTimeStop = lastUsedTimeStop;
        }

        public string Key { get; }
        public bool Packaged { get; }
        /// <summary>FILETIME UTC dell'ultimo avvio dell'uso.</summary>
        public long LastUsedTimeStart { get; }
        /// <summary>FILETIME UTC dell'ultimo stop. Zero vuol dire «in uso adesso».</summary>
        public long LastUsedTimeStop { get; }

        public bool InUse => LastUsedTimeStop == 0 && LastUsedTimeStart > 0;

        /// <summary>Da quando l'app usa il microfono, se Windows lo sa.</summary>
        public DateTime? Since
        {
            get
            {
                if (LastUsedTimeStart <= 0) return null;
                try { return DateTime.FromFileTimeUtc(LastUsedTimeStart); }
                catch (ArgumentOutOfRangeException) { return null; }
            }
        }
    }

    /// <summary>Un'app che probabilmente è in chiamata.</summary>
    public sealed class CallApp
    {
        public CallApp(string name, DateTime? since)
        {
            Name = name;
            Since = since;
        }

        public string Name { get; }
        public DateTime? Since { get; }

        public override string ToString() => Name;
    }

    /// <summary>Capisce se è in corso una chiamata guardando quali app usano il microfono.</summary>
    public static class CallDetector
    {
        /// <summary>Eseguibile di Cornetta: non è mai una chiamata.</summary>
        public const string OwnExecutable = "cornetta.exe";

        /// <summary>App di sistema che usano il microfono senza essere una chiamata (registratore, Cortana, digitazione vocale…).</summary>
        static readonly string[] IgnoredPackages =
        {
            "Microsoft.WindowsSoundRecorder", "Microsoft.549981C3F5F10", "Microsoft.Windows.Cortana",
            "MicrosoftWindows.Client.CBS", "Microsoft.Windows.ShellExperienceHost", "MicrosoftWindows.Client.Core",
            "Microsoft.ScreenSketch", "Microsoft.WindowsCamera",
        };

        /// <summary>Nomi riconoscibili delle app più comuni. L'ordine conta: «msedge» prima di «edge».</summary>
        static readonly (string Marker, string Name)[] KnownApps =
        {
            ("whatsapp", "WhatsApp"),
            ("msteams", "Teams"),
            ("microsoftteams", "Teams"),
            ("ms-teams", "Teams"),
            ("teams", "Teams"),
            ("zoom", "Zoom"),
            ("chrome", "Chrome"),
            ("msedge", "Edge"),
            ("microsoftedge", "Edge"),
            ("firefox", "Firefox"),
            ("skype", "Skype"),
            ("discord", "Discord"),
            ("telegram", "Telegram"),
            ("slack", "Slack"),
            ("webex", "Webex"),
            ("ciscocollabhost", "Webex"),
            ("signal", "Signal"),
            ("brave", "Brave"),
            ("opera", "Opera"),
            ("facetime", "FaceTime"),
        };

        /// <summary>
        /// Le app che stanno usando il microfono adesso, con il nome che l'utente riconosce.
        /// Esclude Cornetta e le app di sistema, unisce i doppioni tenendo l'inizio più vecchio.
        /// </summary>
        public static List<CallApp> CallApps(IEnumerable<MicrophoneUse> uses)
        {
            var apps = new List<CallApp>();
            foreach (var use in uses)
            {
                if (!use.InUse) continue;
                string? name = DisplayName(use.Key, use.Packaged);
                if (name == null) continue;
                int index = apps.FindIndex(a => a.Name == name);
                if (index < 0)
                {
                    apps.Add(new CallApp(name, use.Since));
                }
                else if (use.Since.HasValue && (!apps[index].Since.HasValue || use.Since < apps[index].Since))
                {
                    apps[index] = new CallApp(name, use.Since);
                }
            }
            return apps;
        }

        /// <summary>
        /// Nome mostrato per una voce del registro. Null se la voce va ignorata (Cornetta, app di sistema).
        /// </summary>
        public static string? DisplayName(string key, bool packaged)
        {
            if (string.IsNullOrEmpty(key)) return null;
            if (packaged)
            {
                if (IgnoredPackages.Any(p => key.StartsWith(p, StringComparison.OrdinalIgnoreCase))) return null;
                // «5319275A.WhatsAppDesktop_cv1g1gvanyjgm» → «5319275A.WhatsAppDesktop»
                int underscore = key.IndexOf('_');
                string family = underscore > 0 ? key.Substring(0, underscore) : key;
                string? known = Known(family);
                if (known != null) return known;
                string last = family.Split('.').Last();
                return string.IsNullOrEmpty(last) ? family : last;
            }
            else
            {
                // «C:#Program Files#Google#Chrome#Application#chrome.exe» → «chrome.exe»
                string file = key.Split('#', '\\', '/').Last();
                if (file.Equals(OwnExecutable, StringComparison.OrdinalIgnoreCase)) return null;
                string? known = Known(file);
                if (known != null) return known;
                string stem = file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? file.Substring(0, file.Length - 4) : file;
                if (stem.Length == 0) return null;
                return char.ToUpperInvariant(stem[0]) + stem.Substring(1);
            }
        }

        private static string? Known(string text)
        {
            foreach (var (marker, name) in KnownApps)
            {
                if (text.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0) return name;
            }
            return null;
        }
    }

    /// <summary>Cosa deve fare l'interfaccia dopo un controllo delle chiamate.</summary>
    public sealed class CallPollResult
    {
        /// <summary>App per cui proporre la registrazione («Chiamata in corso su …»).</summary>
        public string? PromptApp { get; internal set; }
        /// <summary>Chiude l'avviso di chiamata: l'app ha lasciato il microfono.</summary>
        public bool CloseCallNotice { get; internal set; }
        /// <summary>Durante la registrazione: la chiamata sembra finita.</summary>
        public bool CallEnded { get; internal set; }
        /// <summary>Durante la registrazione: la chiamata è ripresa, via il banner.</summary>
        public bool CallResumed { get; internal set; }
    }

    /// <summary>
    /// Logica del rilevamento chiamate, senza registro né timer: la stessa di RecorderModel.pollCalls del Mac.
    /// Si chiama ogni 2 secondi con l'elenco delle app che usano il microfono.
    /// </summary>
    public sealed class CallMonitor
    {
        /// <summary>Avviso solo se l'app usa il microfono da almeno 4 secondi (niente falsi allarmi da dettatura).</summary>
        public TimeSpan PromptAfter { get; set; } = TimeSpan.FromSeconds(4);
        /// <summary>Durante la registrazione, oltre questo tempo senza app sul microfono la chiamata sembra finita.</summary>
        public TimeSpan EndedAfter { get; set; } = TimeSpan.FromSeconds(6);

        private readonly Dictionary<string, DateTime> firstSeen = new Dictionary<string, DateTime>();
        private readonly HashSet<string> prompted = new HashSet<string>();
        private DateTime? lastCallAppSeenAt;

        public bool CallEndedSuggested { get; private set; }

        /// <summary>Le app viste all'ultimo controllo.</summary>
        public IReadOnlyList<CallApp> CurrentApps { get; private set; } = new List<CallApp>();

        public CallPollResult Poll(DateTime nowUtc, IReadOnlyList<CallApp> apps, bool isRecording, bool proposeOnCall, bool noticeOpen, bool callNoticeOpen)
        {
            var result = new CallPollResult();
            CurrentApps = apps;
            foreach (var app in apps)
            {
                if (!firstSeen.ContainsKey(app.Name)) firstSeen[app.Name] = nowUtc;
            }
            foreach (var name in firstSeen.Keys.ToList())
            {
                if (apps.Any(a => a.Name == name)) continue;
                firstSeen.Remove(name);
                prompted.Remove(name);
            }

            if (isRecording)
            {
                if (apps.Count > 0)
                {
                    lastCallAppSeenAt = nowUtc;
                    if (CallEndedSuggested)
                    {
                        CallEndedSuggested = false;
                        result.CallResumed = true;
                    }
                }
                else if (lastCallAppSeenAt.HasValue && nowUtc - lastCallAppSeenAt.Value > EndedAfter && !CallEndedSuggested)
                {
                    // L'app di chiamata ha lasciato il microfono: probabilmente la chiamata è finita.
                    CallEndedSuggested = true;
                    result.CallEnded = true;
                }
                return result;
            }

            if (callNoticeOpen && apps.Count == 0)
            {
                result.CloseCallNotice = true;
                noticeOpen = false;
            }
            if (!proposeOnCall || noticeOpen) return result;

            foreach (var app in apps)
            {
                if (prompted.Contains(app.Name)) continue;
                DateTime since = Earliest(app.Since, firstSeen[app.Name]);
                if (nowUtc - since < PromptAfter) continue;
                prompted.Add(app.Name);
                result.PromptApp = app.Name;
                break;
            }
            return result;
        }

        /// <summary>All'avvio della registrazione: il banner «sembra finita» parte solo se c'era una chiamata.</summary>
        public void RecordingStarted(DateTime nowUtc)
        {
            lastCallAppSeenAt = CurrentApps.Count == 0 ? (DateTime?)null : nowUtc;
            CallEndedSuggested = false;
        }

        /// <summary>«Continua»: l'utente vuole registrare ancora.</summary>
        public void DismissCallEnded()
        {
            CallEndedSuggested = false;
            lastCallAppSeenAt = null;
        }

        private static DateTime Earliest(DateTime? registry, DateTime seen)
        {
            // Il registro dice da quando l'app usa il microfono. Se l'orario è nel futuro (orologio spostato), vale quello visto.
            if (registry.HasValue && registry.Value <= seen) return registry.Value;
            return seen;
        }
    }
}
