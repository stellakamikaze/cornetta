using System;
using System.Collections.Generic;
using Cornetta.Core;
using Microsoft.Win32;
using NAudio.CoreAudioApi;

namespace Cornetta.App
{
    /// <summary>Nomi dei dispositivi audio predefiniti, per il pannello e la diagnosi.</summary>
    internal static class AudioDevices
    {
        public sealed class Summary
        {
            public string? Input { get; set; }
            public string? Output { get; set; }
            public string? CommunicationsInput { get; set; }
            public string? CommunicationsOutput { get; set; }
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
                    summary.Input = Name(enumerator, DataFlow.Capture, Role.Console);
                    summary.Output = Name(enumerator, DataFlow.Render, Role.Console);
                    summary.CommunicationsInput = Name(enumerator, DataFlow.Capture, Role.Communications);
                    summary.CommunicationsOutput = Name(enumerator, DataFlow.Render, Role.Communications);
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

        public static MMDevice? Default(MMDeviceEnumerator enumerator, DataFlow flow)
        {
            try
            {
                if (!enumerator.HasDefaultAudioEndpoint(flow, Role.Console)) return null;
                return enumerator.GetDefaultAudioEndpoint(flow, Role.Console);
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
