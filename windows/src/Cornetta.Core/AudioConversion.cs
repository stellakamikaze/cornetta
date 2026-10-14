using System;
using NAudio.Dsp;

namespace Cornetta.Core
{
    /// <summary>Formato dei byte che arrivano da un dispositivo WASAPI.</summary>
    public sealed class InputFormat
    {
        public InputFormat(int sampleRate, int channels, int bitsPerSample, bool isFloat)
        {
            SampleRate = sampleRate;
            Channels = channels;
            BitsPerSample = bitsPerSample;
            IsFloat = isFloat;
        }

        public int SampleRate { get; }
        public int Channels { get; }
        public int BitsPerSample { get; }
        public bool IsFloat { get; }
        public int BlockAlign => Channels * BitsPerSample / 8;

        public override string ToString() =>
            SampleRate + "Hz " + Channels + "ch " + BitsPerSample + "bit" + (IsFloat ? " float" : " pcm");
    }

    /// <summary>Conversioni fra i byte dei dispositivi e i campioni float usati dal mixer.</summary>
    public static class AudioConversion
    {
        /// <summary>Byte (float 32, PCM 16/24/32) → campioni float interleaved.</summary>
        public static float[] ToFloat(byte[] buffer, int byteCount, InputFormat format)
        {
            int bytesPerSample = format.BitsPerSample / 8;
            if (bytesPerSample <= 0 || format.Channels <= 0) return new float[0];
            int frames = byteCount / format.BlockAlign;
            int count = frames * format.Channels;
            var output = new float[count];
            if (format.IsFloat && format.BitsPerSample == 32)
            {
                Buffer.BlockCopy(buffer, 0, output, 0, count * 4);
                return output;
            }
            if (format.IsFloat && format.BitsPerSample == 64)
            {
                for (int i = 0; i < count; i++) output[i] = (float)BitConverter.ToDouble(buffer, i * 8);
                return output;
            }
            switch (format.BitsPerSample)
            {
                case 16:
                    for (int i = 0; i < count; i++) output[i] = BitConverter.ToInt16(buffer, i * 2) / 32768f;
                    break;
                case 24:
                    for (int i = 0; i < count; i++)
                    {
                        int o = i * 3;
                        int v = (buffer[o] << 8) | (buffer[o + 1] << 16) | (buffer[o + 2] << 24);
                        output[i] = (v >> 8) / 8388608f;
                    }
                    break;
                case 32:
                    for (int i = 0; i < count; i++) output[i] = BitConverter.ToInt32(buffer, i * 4) / 2147483648f;
                    break;
                case 8:
                    for (int i = 0; i < count; i++) output[i] = (buffer[i] - 128) / 128f;
                    break;
            }
            return output;
        }

        /// <summary>Interleaved con N canali → mono (media dei canali), come Mixer.DownmixToMono.</summary>
        public static float[] ToMono(float[] interleaved, int channels)
        {
            if (channels <= 1) return interleaved;
            int frames = interleaved.Length / channels;
            var output = new float[frames];
            float scale = 1f / channels;
            for (int f = 0; f < frames; f++)
            {
                float sum = 0;
                int o = f * channels;
                for (int c = 0; c < channels; c++) sum += interleaved[o + c];
                output[f] = sum * scale;
            }
            return output;
        }

        /// <summary>Interleaved con N canali → stereo interleaved: mono duplicato, oltre due canali tiene i primi due.</summary>
        public static float[] ToStereo(float[] interleaved, int channels)
        {
            if (channels == 2) return interleaved;
            int frames = channels > 0 ? interleaved.Length / channels : 0;
            var output = new float[frames * 2];
            for (int f = 0; f < frames; f++)
            {
                if (channels == 1)
                {
                    output[f * 2] = interleaved[f];
                    output[f * 2 + 1] = interleaved[f];
                }
                else
                {
                    output[f * 2] = interleaved[f * channels];
                    output[f * 2 + 1] = interleaved[f * channels + 1];
                }
            }
            return output;
        }

        /// <summary>Float stereo interleaved → PCM 16 bit little endian, con saturazione.</summary>
        public static byte[] ToPcm16(float[] interleaved, int sampleCount)
        {
            var bytes = new byte[sampleCount * 2];
            for (int i = 0; i < sampleCount; i++)
            {
                float x = interleaved[i];
                if (x > 1) x = 1; else if (x < -1) x = -1; else if (float.IsNaN(x)) x = 0;
                short v = (short)Math.Round(x * 32767f);
                bytes[i * 2] = (byte)(v & 0xff);
                bytes[i * 2 + 1] = (byte)((v >> 8) & 0xff);
            }
            return bytes;
        }
    }

    /// <summary>
    /// Porta un flusso interleaved a 48 kHz con il resampler WDL di NAudio, a blocchi (modalità «input driven»).
    /// Se la frequenza è già quella giusta, i campioni passano senza copie.
    /// </summary>
    public sealed class StreamResampler
    {
        private readonly WdlResampler? resampler;
        private readonly int channels;
        private readonly double ratio;

        public StreamResampler(int inputRate, int outputRate, int channels)
        {
            this.channels = channels;
            InputRate = inputRate;
            OutputRate = outputRate;
            ratio = (double)outputRate / inputRate;
            if (inputRate == outputRate) return;
            resampler = new WdlResampler();
            resampler.SetMode(true, 2, false);
            resampler.SetFilterParms();
            resampler.SetFeedMode(true);
            resampler.SetRates(inputRate, outputRate);
        }

        public int InputRate { get; }
        public int OutputRate { get; }

        public float[] Process(float[] interleaved)
        {
            if (resampler == null) return interleaved;
            int inFrames = interleaved.Length / channels;
            if (inFrames == 0) return new float[0];
            int needed = resampler.ResamplePrepare(inFrames, channels, out float[] inBuffer, out int inOffset);
            int frames = Math.Min(needed, inFrames);
            Array.Copy(interleaved, 0, inBuffer, inOffset, frames * channels);
            int capacity = (int)Math.Ceiling(frames * ratio) + 32;
            var output = new float[capacity * channels];
            int produced = resampler.ResampleOut(output, 0, frames, capacity, channels);
            if (produced == capacity) return output;
            var trimmed = new float[produced * channels];
            Array.Copy(output, trimmed, trimmed.Length);
            return trimmed;
        }
    }
}
