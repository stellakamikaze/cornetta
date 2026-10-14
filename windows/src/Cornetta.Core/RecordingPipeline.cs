using System;

namespace Cornetta.Core
{
    /// <summary>Dove finisce il mix: file AAC, file WAV o, nei test, la memoria.</summary>
    public interface IAudioSink
    {
        /// <summary>Riceve campioni stereo interleaved a 48 kHz, già limitati fra -1 e 1.</summary>
        void Write(float[] interleavedStereo, int frames);
    }

    /// <summary>
    /// Dalla linea del tempo al file: legge microfono e sistema, livella la voce, mixa e scrive.
    /// È la parte di TrackWriter.swift che non dipende dal sistema operativo.
    /// Va usata da un solo thread (quello del mixer).
    /// </summary>
    public sealed class RecordingPipeline
    {
        public const int SampleRate = 48000;
        /// <summary>Blocchi da 10 ms: il livellatore lavora a passi simili a quelli del Mac.</summary>
        public const int BlockFrames = 480;

        private readonly IAudioSink sink;
        private readonly VoiceLeveler leveler = new VoiceLeveler();
        private long rendered;

        public RecordingPipeline(IAudioSink sink)
        {
            this.sink = sink;
        }

        /// <summary>Microfono mono sulla linea del tempo.</summary>
        public CaptureTimeline Microphone { get; } = new CaptureTimeline(1, SampleRate);
        /// <summary>Audio di sistema stereo sulla linea del tempo.</summary>
        public CaptureTimeline System { get; } = new CaptureTimeline(2, SampleRate);
        /// <summary>Falso se si registra senza microfono: la voce non passa dal livellatore.</summary>
        public bool HasMicrophone { get; set; } = true;

        public LevelMeter Meter { get; } = new LevelMeter();
        public RecordingStats Stats { get; } = new RecordingStats();
        public float MicGain => leveler.Gain;
        public long RenderedFrames => rendered;

        /// <summary>Scrive tutto fino alla posizione <paramref name="upTo"/> (in frame a 48 kHz dall'avvio).</summary>
        public void Render(long upTo)
        {
            while (rendered < upTo)
            {
                int frames = (int)Math.Min(BlockFrames, upTo - rendered);
                long end = rendered + frames;
                float[] mic = Microphone.Read(end);
                float[] system = System.Read(end);
                var left = new float[frames];
                var right = new float[frames];
                for (int i = 0; i < frames; i++)
                {
                    left[i] = system[i * 2];
                    right[i] = system[i * 2 + 1];
                }

                bool hasMic = HasMicrophone;
                float systemRms = Math.Max(Mixer.Rms(left), Mixer.Rms(right));
                Stats.Record(hasMic ? Mixer.Rms(mic) : 0, systemRms, frames, SampleRate, hasMic);

                float[][] leveledMic = hasMic ? new[] { leveler.Process(mic, systemRms, SampleRate) } : new float[0][];
                Meter.Update(leveledMic.Length > 0 ? Mixer.Rms(leveledMic[0]) : 0, systemRms, leveler.Gain);
                var mixed = Mixer.Mix(leveledMic, new[] { left, right }, frames);

                var interleaved = new float[frames * 2];
                for (int i = 0; i < frames; i++)
                {
                    interleaved[i * 2] = mixed.Left[i];
                    interleaved[i * 2 + 1] = mixed.Right[i];
                }
                sink.Write(interleaved, frames);
                rendered = end;
            }
        }
    }
}
