using System;
using System.Collections.Generic;
using Cornetta.Core;
using Microsoft.Win32;
using NAudio.CoreAudioApi;

namespace Cornetta.App
{
    /// <summary>Dispositivi audio che Cornetta usa, e i loro nomi per il pannello e la diagnosi.</summary>
    internal static class AudioDevices
    {
        /// <summary>
        /// Il ruolo «Comunicazioni» è quello che usano Teams, Zoom, WhatsApp e il browser in chiamata. Può essere
        /// diverso dal predefinito generale: su un PC con «Stereo Mix» come ingresso predefinito il microfono vero
        /// sta solo lì, e col predefinito generale Cornetta registrerebbe due volte gli altri e mai te.
        /// Senza un dispositivo per le comunicazioni si usa il predefinito generale.
        /// </summary>
        public const Role CallRole = Role.Communications;

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
                    summary.Input = Name(enumerator, DataFlow.Capture, CallRole) ?? Name(enumerator, DataFlow.Capture, Role.Console);
                    summary.Output = Name(enumerator, DataFlow.Render, CallRole) ?? Name(enumerator, DataFlow.Render, Role.Console);
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
                foreach (var role in new[] { CallRole, Role.Console })
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

    /// <summary>Legge dal registro quali app usano il microfono (vedi CallDetector).</summary>
    internal static class MicrophoneUsage
    {
        private const string Path = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

        public static List<MicrophoneUse> Read()
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
