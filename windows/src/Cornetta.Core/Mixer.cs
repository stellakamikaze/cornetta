using System;

namespace Cornetta.Core
{
    /// <summary>
    /// Unisce la voce del microfono e l'audio di sistema in un segnale stereo.
    /// Porta 1:1 di Sources/CornettaCore/Mixer.swift.
    /// </summary>
    public static class Mixer
    {
        /// <summary>Soglia oltre la quale il limitatore comprime il segnale.</summary>
        public const float LimiterThreshold = 0.9f;

        /// <summary>Riduce N canali a uno solo con la media. Zero canali = silenzio.</summary>
        public static float[] DownmixToMono(float[][] channels, int frameCount)
        {
            var output = new float[frameCount];
            if (channels.Length == 0) return output;
            float scale = 1f / channels.Length;
            foreach (var channel in channels)
            {
                int n = Math.Min(frameCount, channel.Length);
                for (int i = 0; i < n; i++) output[i] += channel[i] * scale;
            }
            return output;
        }

        /// <summary>Porta N canali a stereo: mono duplicato, oltre due canali tiene i primi due.</summary>
        public static (float[] Left, float[] Right) ToStereo(float[][] channels, int frameCount)
        {
            switch (channels.Length)
            {
                case 0: return (new float[frameCount], new float[frameCount]);
                case 1: return (Padded(channels[0], frameCount), Padded(channels[0], frameCount));
                default: return (Padded(channels[0], frameCount), Padded(channels[1], frameCount));
            }
        }

        /// <summary>Mix finale: microfono al centro (su L e R) più audio di sistema stereo, con limitatore.</summary>
        public static (float[] Left, float[] Right) Mix(float[][] mic, float[][] system, int frameCount, float micGain = 1, float systemGain = 1)
        {
            var micMono = DownmixToMono(mic, frameCount);
            var sys = ToStereo(system, frameCount);
            var left = new float[frameCount];
            var right = new float[frameCount];
            for (int i = 0; i < frameCount; i++)
            {
                float m = micMono[i] * micGain;
                left[i] = SoftLimit(m + sys.Left[i] * systemGain);
                right[i] = SoftLimit(m + sys.Right[i] * systemGain);
            }
            return (left, right);
        }

        /// <summary>Lascia intatto il segnale sotto soglia, sopra lo comprime verso 1 senza mai superarlo.</summary>
        public static float SoftLimit(float x)
        {
            const float t = LimiterThreshold;
            float magnitude = Math.Abs(x);
            if (!(magnitude > t)) return x;
            float compressed = t + (1 - t) * (float)Math.Tanh((magnitude - t) / (1 - t));
            return x < 0 ? -compressed : compressed;
        }

        /// <summary>Valore efficace di un segnale: serve a misurare se una traccia contiene audio.</summary>
        public static float Rms(float[] samples)
        {
            if (samples.Length == 0) return 0;
            float sum = 0;
            foreach (var s in samples) sum += s * s;
            return (float)Math.Sqrt(sum / samples.Length);
        }

        private static float[] Padded(float[] channel, int frameCount)
        {
            var output = new float[frameCount];
            Array.Copy(channel, output, Math.Min(channel.Length, frameCount));
            return output;
        }
    }
}
