using System;
using System.Globalization;

namespace Cornetta.Core
{
    /// <summary>Livelli correnti per gli indicatori dell'interfaccia (aggiornati dal mixer, letti dalla UI).</summary>
    public sealed class LevelMeter
    {
        private readonly object gate = new object();
        private float micLevel;
        private float systemLevel;
        private float gain = 1;

        public void Update(float mic, float system, float micGain)
        {
            lock (gate)
            {
                // Discesa lenta: l'indicatore non sfarfalla.
                micLevel = Math.Max(mic, micLevel * 0.85f);
                systemLevel = Math.Max(system, systemLevel * 0.85f);
                gain = micGain;
            }
        }

        /// <summary>Livelli 0...1 su scala in dB (da -50 dB a 0 dB).</summary>
        public (float Mic, float System) Levels
        {
            get { lock (gate) return (Scale(micLevel), Scale(systemLevel)); }
        }

        public float MicGain
        {
            get { lock (gate) return gain; }
        }

        public static float Scale(float rms)
        {
            if (!(rms > 0)) return 0;
            float db = 20 * (float)Math.Log10(rms);
            return Math.Min(Math.Max((db + 50) / 50, 0), 1);
        }
    }

    /// <summary>Statistiche di una sessione di registrazione.</summary>
    public sealed class RecordingStats
    {
        public float MicPeakRms { get; private set; }
        public float SystemPeakRms { get; private set; }
        public double Seconds { get; private set; }
        public bool HadMicrophone { get; private set; }
        /// <summary>Da quanti secondi l'audio di sistema è zero esatto (vedi SilenceWatch).</summary>
        public double SystemSilentSeconds { get; private set; }

        public void Record(float micRms, float systemRms, int frames, double sampleRate, bool hasMicrophone)
        {
            MicPeakRms = Math.Max(MicPeakRms, micRms);
            SystemPeakRms = Math.Max(SystemPeakRms, systemRms);
            Seconds += frames / sampleRate;
            SystemSilentSeconds = systemRms > 0 ? 0 : SystemSilentSeconds + frames / sampleRate;
            HadMicrophone = HadMicrophone || hasMicrophone;
        }

        public string ToJson()
        {
            var c = CultureInfo.InvariantCulture;
            return "{\"micPeakRMS\":" + MicPeakRms.ToString("R", c)
                + ",\"systemPeakRMS\":" + SystemPeakRms.ToString("R", c)
                + ",\"seconds\":" + Seconds.ToString("R", c)
                + ",\"hadMicrophone\":" + (HadMicrophone ? "true" : "false") + "}";
        }
    }

    /// <summary>Testi con il tempo trascorso, come nel pannello del Mac.</summary>
    public static class TimeText
    {
        /// <summary>«04:07» sotto l'ora, «1:04:07» sopra.</summary>
        public static string Elapsed(TimeSpan elapsed)
        {
            int total = (int)Math.Max(0, elapsed.TotalSeconds);
            int hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60;
            var c = CultureInfo.InvariantCulture;
            return hours > 0
                ? string.Format(c, "{0}:{1:00}:{2:00}", hours, minutes, seconds)
                : string.Format(c, "{0:00}:{1:00}", minutes, seconds);
        }
    }
}
