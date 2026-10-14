using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using Cornetta.Core;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace Cornetta.App
{
    /// <summary>File di uscita: AAC .m4a con Media Foundation, oppure WAV se l'AAC manca (Windows N senza Media Feature Pack).</summary>
    internal abstract class AudioFileSink : IAudioSink, IDisposable
    {
        public const int SampleRate = 48000;
        public const int BitRate = 160_000;
        protected static readonly WaveFormat PcmFormat = new WaveFormat(SampleRate, 16, 2);

        protected AudioFileSink(string path) { Path = path; }

        public string Path { get; }
        public abstract bool IsAac { get; }
        /// <summary>Errore di scrittura, se c'è stato. Il mixer lo controlla e ferma la registrazione.</summary>
        public Exception? Error { get; protected set; }

        public abstract void Write(float[] interleavedStereo, int frames);
        public abstract void Close();
        public void Dispose() => Close();

        private static bool? aacAvailable;

        /// <summary>Vero se Windows ha l'encoder AAC di Media Foundation a 48 kHz stereo.</summary>
        public static bool AacAvailable
        {
            get
            {
                if (aacAvailable.HasValue) return aacAvailable.Value;
                try
                {
                    MediaFoundationApi.Startup();
                    aacAvailable = MediaFoundationEncoder.SelectMediaType(AudioSubtypes.MFAudioFormat_AAC, PcmFormat, BitRate) != null;
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Media Foundation non disponibile: " + ex.Message);
                    aacAvailable = false;
                }
                return aacAvailable.Value;
            }
        }

        /// <summary>Estensione del file in base all'encoder disponibile.</summary>
        public static string Extension => AacAvailable ? ".m4a" : ".wav";

        public static AudioFileSink Create(string path)
        {
            string? dir = System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            if (path.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase) && AacAvailable) return new AacFileSink(path);
            return new WavFileSink(path);
        }
    }

    /// <summary>
    /// AAC 160 kbit/s in un contenitore MPEG-4. MediaFoundationEncoder legge da un IWaveProvider finché
    /// riceve zero byte: un thread dedicato lo alimenta da una coda e lo chiude a fine registrazione.
    /// </summary>
    internal sealed class AacFileSink : AudioFileSink
    {
        private readonly BlockingPcmProvider provider = new BlockingPcmProvider(PcmFormat);
        private readonly Thread thread;
        private bool closed;

        public AacFileSink(string path) : base(path)
        {
            thread = new Thread(Encode) { IsBackground = true, Name = "Cornetta AAC" };
            thread.Start();
        }

        public override bool IsAac => true;

        private void Encode()
        {
            try
            {
                MediaFoundationEncoder.EncodeToAac(provider, Path, BitRate);
            }
            catch (Exception ex)
            {
                Error = ex;
                provider.Abort();
                Diagnostics.Log("Encoder AAC: " + ex.Message);
            }
        }

        public override void Write(float[] interleavedStereo, int frames)
        {
            if (Error != null || closed) return;
            provider.Add(AudioConversion.ToPcm16(interleavedStereo, frames * 2));
        }

        public override void Close()
        {
            if (closed) return;
            closed = true;
            provider.Complete();
            if (!thread.Join(TimeSpan.FromSeconds(60)))
            {
                Diagnostics.Log("L'encoder AAC non ha chiuso il file entro 60 s");
            }
        }
    }

    internal sealed class WavFileSink : AudioFileSink
    {
        private WaveFileWriter? writer;

        public WavFileSink(string path) : base(path)
        {
            writer = new WaveFileWriter(path, PcmFormat);
        }

        public override bool IsAac => false;

        public override void Write(float[] interleavedStereo, int frames)
        {
            if (writer == null || Error != null) return;
            try
            {
                var bytes = AudioConversion.ToPcm16(interleavedStereo, frames * 2);
                writer.Write(bytes, 0, bytes.Length);
            }
            catch (Exception ex)
            {
                Error = ex;
            }
        }

        public override void Close()
        {
            writer?.Dispose();
            writer = null;
        }
    }

    /// <summary>Coda di PCM che si comporta come uno stream: Read aspetta i dati e restituisce 0 solo alla fine.</summary>
    internal sealed class BlockingPcmProvider : IWaveProvider
    {
        private readonly object gate = new object();
        private readonly Queue<byte[]> chunks = new Queue<byte[]>();
        private int headOffset;
        private long queued;
        private bool completed;
        private bool aborted;
        private readonly int minimumRead;

        public BlockingPcmProvider(WaveFormat format)
        {
            WaveFormat = format;
            // Mezzo secondo per campione Media Foundation: pochi campioni grandi, latenza trascurabile.
            minimumRead = format.AverageBytesPerSecond / 2;
        }

        public WaveFormat WaveFormat { get; }

        public void Add(byte[] data)
        {
            lock (gate)
            {
                if (completed || aborted) return;
                chunks.Enqueue(data);
                queued += data.Length;
                Monitor.PulseAll(gate);
            }
        }

        public void Complete()
        {
            lock (gate)
            {
                completed = true;
                Monitor.PulseAll(gate);
            }
        }

        public void Abort()
        {
            lock (gate)
            {
                aborted = true;
                chunks.Clear();
                queued = 0;
                Monitor.PulseAll(gate);
            }
        }

        public int Read(byte[] buffer, int offset, int count)
        {
            lock (gate)
            {
                int want = Math.Min(count, minimumRead);
                while (!completed && !aborted && queued < want) Monitor.Wait(gate, 250);
                int read = 0;
                while (read < count && chunks.Count > 0)
                {
                    var head = chunks.Peek();
                    int take = Math.Min(count - read, head.Length - headOffset);
                    Buffer.BlockCopy(head, headOffset, buffer, offset + read, take);
                    read += take;
                    headOffset += take;
                    if (headOffset == head.Length)
                    {
                        chunks.Dequeue();
                        headOffset = 0;
                    }
                }
                queued -= read;
                return read;
            }
        }
    }
}
