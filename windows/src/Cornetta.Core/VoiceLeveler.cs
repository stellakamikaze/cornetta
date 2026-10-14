using System;

namespace Cornetta.Core
{
    /// <summary>
    /// Porta la voce di chi registra a un livello simile a quella della chiamata.
    /// Porta 1:1 di Sources/CornettaCore/VoiceLeveler.swift: stessi parametri, stessa logica.
    ///
    /// Durante le chiamate l'app di chiamata elabora il microfono per sé, e Cornetta riceve il segnale
    /// grezzo, anche 25 dB più basso della voce in arrivo. Il livellatore:
    /// - misura il livello del parlato (solo quando parli tu) e calcola il guadagno verso Target;
    /// - non amplifica il rumore di fondo nelle pause;
    /// - spegne l'amplificazione mentre parla l'altra persona, perché il microfono riprende anche
    ///   gli altoparlanti e l'eco amplificata raddoppierebbe la sua voce.
    /// </summary>
    public sealed class VoiceLeveler
    {
        public float Target { get; set; } = 0.1f;
        public float MaxGain { get; set; } = 16;
        /// <summary>Sopra questo livello l'audio di sistema conta come «sta parlando l'altra persona».</summary>
        public float SystemActiveThreshold { get; set; } = 0.01f;
        /// <summary>Quanto resta spenta l'amplificazione dopo che l'altra persona ha smesso di parlare.</summary>
        public double SystemHoldSeconds { get; set; } = 0.3;

        public float Gain { get; private set; } = 1;
        private float speechLevel = 0.01f;
        private float noiseFloor = 0.0002f;
        private double systemHoldRemaining;

        /// <summary>Elabora un blocco del microfono (mono) e restituisce il blocco livellato.</summary>
        public float[] Process(float[] mic, float systemRms, double sampleRate)
        {
            if (mic.Length == 0 || !(sampleRate > 0)) return mic;
            double blockSeconds = mic.Length / sampleRate;
            float level = Mixer.Rms(mic);

            // Rumore di fondo: scende subito, sale molto piano (il parlato ha pause che lo riportano giù).
            noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * (float)Math.Min(1, blockSeconds / 20);
            noiseFloor = Math.Max(noiseFloor, 0.00005f);

            bool systemActive = systemRms > SystemActiveThreshold;
            if (systemActive)
            {
                systemHoldRemaining = SystemHoldSeconds;
            }
            else
            {
                systemHoldRemaining = Math.Max(0, systemHoldRemaining - blockSeconds);
            }
            bool otherIsTalking = systemActive || systemHoldRemaining > 0;
            bool isSpeech = level > Math.Max(noiseFloor * 3, 0.0004f);

            // Il livello del parlato si aggiorna solo quando parli tu (costante di tempo ~1 s).
            if (isSpeech && !otherIsTalking)
            {
                speechLevel += (level - speechLevel) * (float)Math.Min(1, blockSeconds / 1.0);
            }

            float desired;
            if (otherIsTalking || !isSpeech)
            {
                desired = 1;
            }
            else
            {
                desired = Math.Min(Math.Max(Target / Math.Max(speechLevel, 0.0001f), 1), MaxGain);
            }

            // Sale in 200 ms. Scende in 10 ms se parla l'altra persona, in 50 ms se la tua voce è già forte.
            // Nelle pause fra le parole scende piano (1,5 s), così le sillabe deboli non vengono tagliate.
            double tau;
            if (desired >= Gain) tau = 0.2;
            else if (otherIsTalking) tau = 0.01;
            else if (isSpeech) tau = 0.05;
            else tau = 1.5;
            float next = Gain + (desired - Gain) * (float)Math.Min(1, blockSeconds / tau);
            var output = new float[mic.Length];
            float step = (next - Gain) / mic.Length;
            float g = Gain;
            for (int i = 0; i < mic.Length; i++)
            {
                g += step;
                output[i] = mic[i] * g;
            }
            Gain = next;
            return output;
        }
    }
}
