using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Cornetta.Core;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Cornetta.App
{
    /// <summary>Dispositivi audio che Cornetta usa, e i loro nomi per il pannello e la diagnosi.</summary>
    internal static class AudioDevices
    {
        /// <summary>
        /// Il ruolo «Comunicazioni» è quello che usano Teams, Zoom e WhatsApp in chiamata. Può essere diverso dal
        /// predefinito generale: su un PC con «Stereo Mix» come ingresso predefinito il microfono vero sta solo lì,
        /// e col predefinito generale Cornetta registrerebbe due volte gli altri e mai te.
        /// Senza un dispositivo per le comunicazioni si usa il predefinito generale. Per l'uscita Cornetta ascolta anche
        /// il predefinito generale, se è un altro (GeneralOutput): lì suona il browser finché il sito non sceglie un'uscita.
        /// </summary>
        public const Role CallRole = Role.Communications;

        /// <summary>I ruoli in ordine di preferenza: prima quello delle chiamate, poi il predefinito generale.</summary>
        private static readonly Role[] Roles = { CallRole, Role.Console };

        public sealed class Summary
        {
            /// <summary>Quelli che Cornetta usa (ruolo delle chiamate).</summary>
            public string? Input { get; set; }
            public string? Output { get; set; }
            /// <summary>I predefiniti generali di Windows, per la diagnosi quando sono diversi.</summary>
            public string? GeneralInput { get; set; }
            public string? GeneralOutput { get; set; }
            public int ActiveInputs { get; set; }
            public int ActiveOutputs { get; set; }
        }

        public static Summary Describe()
        {
            var summary = new Summary();
            try
            {
                using (var enumerator = new MMDeviceEnumerator())
                {
                    summary.Input = Name(enumerator, DataFlow.Capture);
                    summary.Output = Name(enumerator, DataFlow.Render);
                    summary.GeneralInput = Name(enumerator, DataFlow.Capture, Role.Console);
                    summary.GeneralOutput = Name(enumerator, DataFlow.Render, Role.Console);
                    summary.ActiveInputs = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).Count;
                    summary.ActiveOutputs = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active).Count;
                }
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Dispositivi audio non leggibili: " + ex.Message);
            }
            return summary;
        }

        /// <summary>Il dispositivo delle chiamate, o il predefinito generale se manca.</summary>
        public static MMDevice? Default(MMDeviceEnumerator enumerator, DataFlow flow)
        {
            try
            {
                foreach (var role in Roles)
                {
                    if (enumerator.HasDefaultAudioEndpoint(flow, role)) return enumerator.GetDefaultAudioEndpoint(flow, role);
                }
                return null;
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Dispositivo predefinito non disponibile (" + flow + "): " + ex.Message);
                return null;
            }
        }

        /// <summary>L'uscita predefinita generale, se è diversa da <paramref name="callOutput"/>. Altrimenti null.</summary>
        public static MMDevice? GeneralOutput(MMDeviceEnumerator enumerator, MMDevice callOutput)
        {
            try
            {
                if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console)) return null;
                var general = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
                if (general.ID != callOutput.ID) return general;
                general.Dispose();
                return null;
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Uscita predefinita generale non disponibile: " + ex.Message);
                return null;
            }
        }

        /// <summary>
        /// Un flusso sul dispositivo delle chiamate per Windows è una chiamata: con l'impostazione predefinita abbassa
        /// dell'80% gli altri suoni (anche una chiamata nel browser). Cornetta chiede di non farlo, prima di aprire i flussi.
        /// La sessione resta in vita col dispositivo, che la cattura tiene finché registra.
        /// </summary>
        public static void OptOutOfDucking(MMDevice device)
        {
            try
            {
                var control = device.AudioSessionManager.AudioSessionControl;
                // NAudio 2.2.1 non espone SetDuckingPreference: si usa l'interfaccia COM che il wrapper tiene in un campo privato.
                var field = typeof(AudioSessionControl).GetField("audioSessionControlInterface2", BindingFlags.Instance | BindingFlags.NonPublic);
                if (!(field?.GetValue(control) is IAudioSessionControl2 session))
                {
                    Diagnostics.Log("Attenuazione degli altri suoni: interfaccia non trovata");
                    return;
                }
                Marshal.ThrowExceptionForHR(session.SetDuckingPreference(true));
                Diagnostics.Log("Attenuazione degli altri suoni esclusa: " + device.FriendlyName);
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Attenuazione degli altri suoni non esclusa: " + ex.Message);
            }
        }

        /// <summary>Vero se Windows ha un dispositivo per le chiamate o un predefinito generale.</summary>
        public static bool Exists(MMDeviceEnumerator enumerator, DataFlow flow)
        {
            try
            {
                foreach (var role in Roles)
                {
                    if (enumerator.HasDefaultAudioEndpoint(flow, role)) return true;
                }
                return false;
            }
            catch (Exception) { return false; }
        }

        /// <summary>Il nome del dispositivo che Default sceglierebbe.</summary>
        private static string? Name(MMDeviceEnumerator enumerator, DataFlow flow)
        {
            foreach (var role in Roles)
            {
                string? name = Name(enumerator, flow, role);
                if (name != null) return name;
            }
            return null;
        }

        private static string? Name(MMDeviceEnumerator enumerator, DataFlow flow, Role role)
        {
            try
            {
                if (!enumerator.HasDefaultAudioEndpoint(flow, role)) return null;
                using (var device = enumerator.GetDefaultAudioEndpoint(flow, role))
                {
                    return device.FriendlyName;
                }
            }
            catch (Exception) { return null; }
        }
    }

    /// <summary>Permesso del microfono in Impostazioni → Privacy e sicurezza → Microfono.</summary>
    internal static class MicrophonePrivacy
    {
        private const string Path = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

        /// <summary>Falso se Windows nega il microfono a tutti o alle app desktop.</summary>
        public static bool IsAllowed()
        {
            return !IsDenied(Registry.LocalMachine, Path)
                && !IsDenied(Registry.CurrentUser, Path)
                && !IsDenied(Registry.CurrentUser, Path + @"\NonPackaged");
        }

        private static bool IsDenied(RegistryKey root, string path)
        {
            try
            {
                using (var key = root.OpenSubKey(path))
                {
                    return string.Equals(key?.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch (Exception) { return false; }
        }
    }

    /// <summary>
    /// Quali app usano il microfono (vedi CallDetector): il registro più le sessioni audio attive.
    /// Su Windows 24H2 il registro può restare fermo: le sessioni audio bastano da sole.
    /// </summary>
    internal static class MicrophoneUsage
    {
        private const string Path = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

        public static List<MicrophoneUse> Read()
        {
            var uses = ReadRegistry();
            // Le interfacce audio di Windows vanno usate su un thread MTA, non su quello dell'interfaccia.
            try { uses.AddRange(Task.Run(() => ReadSessions()).GetAwaiter().GetResult()); }
            catch (Exception ex) { Diagnostics.Log("Sessioni audio non leggibili: " + ex.Message); }
            return uses;
        }

        /// <summary>I processi con una sessione audio attiva su un microfono qualsiasi, Cornetta esclusa.</summary>
        private static List<MicrophoneUse> ReadSessions()
        {
            var uses = new List<MicrophoneUse>();
            int own = System.Diagnostics.Process.GetCurrentProcess().Id;
            using (var enumerator = new MMDeviceEnumerator())
            {
                foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                {
                    using (device)
                    {
                        var sessions = device.AudioSessionManager.Sessions;
                        for (int i = 0; i < sessions.Count; i++)
                        {
                            using (var session = sessions[i])
                            {
                                if (session.State != NAudio.CoreAudioApi.Interfaces.AudioSessionState.AudioSessionStateActive) continue;
                                if (session.IsSystemSoundsSession) continue;
                                int pid = (int)session.GetProcessID;
                                if (pid == 0 || pid == own) continue;
                                string? path = ExecutablePath(pid);
                                if (path != null) uses.Add(MicrophoneUse.FromProcess(path));
                            }
                        }
                    }
                }
            }
            return uses;
        }

        /// <summary>Percorso dell'eseguibile di un processo, anche a 32 bit o elevato. Null se non leggibile.</summary>
        private static string? ExecutablePath(int pid)
        {
            IntPtr handle = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (handle == IntPtr.Zero) return null;
            try
            {
                var name = new StringBuilder(1024);
                int size = name.Capacity;
                return NativeMethods.QueryFullProcessImageName(handle, 0, name, ref size) ? name.ToString() : null;
            }
            finally { NativeMethods.CloseHandle(handle); }
        }

        private static List<MicrophoneUse> ReadRegistry()
        {
            var uses = new List<MicrophoneUse>();
            try
            {
                using (var root = Registry.CurrentUser.OpenSubKey(Path))
                {
                    if (root == null) return uses;
                    foreach (string name in root.GetSubKeyNames())
                    {
                        if (name.Equals("NonPackaged", StringComparison.OrdinalIgnoreCase))
                        {
                            using (var nonPackaged = root.OpenSubKey(name))
                            {
                                if (nonPackaged == null) continue;
                                foreach (string exe in nonPackaged.GetSubKeyNames()) Add(uses, nonPackaged, exe, false);
                            }
                        }
                        else
                        {
                            Add(uses, root, name, true);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Uso del microfono non leggibile: " + ex.Message);
            }
            return uses;
        }

        private static void Add(List<MicrophoneUse> uses, RegistryKey parent, string name, bool packaged)
        {
            using (var key = parent.OpenSubKey(name))
            {
                if (key == null) return;
                long start = ToLong(key.GetValue("LastUsedTimeStart"));
                long stop = ToLong(key.GetValue("LastUsedTimeStop"));
                uses.Add(new MicrophoneUse(name, packaged, start, stop));
            }
        }

        private static long ToLong(object? value)
        {
            switch (value)
            {
                case long l: return l;
                case int i: return i;
                case byte[] bytes when bytes.Length >= 8: return BitConverter.ToInt64(bytes, 0);
                default: return 0;
            }
        }
    }
}
