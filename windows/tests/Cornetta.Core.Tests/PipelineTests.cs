using System;
using System.Collections.Generic;
using System.Linq;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    public class CaptureTimelineTests
    {
        private static float[] Ones(int frames, int channels = 1, float value = 1) =>
            Enumerable.Repeat(value, frames * channels).ToArray();

        [Fact]
        public void BlocksArrivingOnTimeAreContiguous()
        {
            var timeline = new CaptureTimeline(1);
            timeline.Write(480, Ones(480));
            timeline.Write(960 + 200, Ones(480)); // 4 ms in ritardo: resta attaccato al precedente
            var data = timeline.Read(960);
            Assert.Equal(960, data.Length);
            Assert.All(data, s => Assert.Equal(1f, s));
            Assert.Equal(0, timeline.GapsFilled);
        }

        [Fact]
        public void SilenceOfTheSourceBecomesZerosAtTheRightPlace()
        {
            // Il loopback tace per un secondo, poi riprende: il blocco cade a 1,0 s, non subito dopo il precedente.
            var timeline = new CaptureTimeline(2);
            timeline.Write(480, Ones(480, 2));
            timeline.Write(48_000 + 480, Ones(480, 2, 0.5f));
            var data = timeline.Read(48_000 + 480);
            Assert.Equal((48_000 + 480) * 2, data.Length);
            Assert.Equal(1f, data[0]);
            Assert.Equal(0f, data[480 * 2]);
            Assert.Equal(0f, data[(48_000 - 1) * 2]);
            Assert.Equal(0.5f, data[48_000 * 2]);
            Assert.Equal(1, timeline.GapsFilled);
        }

        [Fact]
        public void FirstBlockIsPlacedByTheClock()
        {
            var timeline = new CaptureTimeline(1);
            timeline.Write(24_000, Ones(480));
            var data = timeline.Read(24_000);
            Assert.Equal(0f, data[0]);
            Assert.Equal(1f, data[24_000 - 1]);
        }

        [Fact]
        public void MissingDataReadsAsSilence()
        {
            var timeline = new CaptureTimeline(1);
            var data = timeline.Read(1000);
            Assert.Equal(1000, data.Length);
            Assert.All(data, s => Assert.Equal(0f, s));
            Assert.Equal(1000, timeline.WritePosition);
        }

        [Fact]
        public void SourceRunningAheadIsRealigned()
        {
            var timeline = new CaptureTimeline(1);
            timeline.Write(480, Ones(480));
            // Il dispositivo ha consegnato 0,2 s in più di quanto dica l'orologio.
            timeline.Write(960, Ones(9600));
            Assert.Equal(960, timeline.WritePosition);
            Assert.Equal(9600 - 480, timeline.FramesDropped);
        }

        [Fact]
        public void MicAndSystemStayAlignedAcrossASilentSystem()
        {
            // Microfono continuo, sistema solo fra 2,0 e 2,5 s: il clic del sistema cade a 2,0 s anche nel mix.
            var sink = new MemorySink();
            var pipeline = new RecordingPipeline(sink);
            for (long t = 480; t <= 3 * 48_000; t += 480)
            {
                pipeline.Microphone.Write(t, new float[480]);
                if (t > 2 * 48_000 && t <= 2.5 * 48_000) pipeline.System.Write(t, Ones(480, 2, 0.5f));
            }
            pipeline.Render(3 * 48_000);
            var left = sink.Left;
            Assert.Equal(3 * 48_000, left.Count);
            int firstSound = left.FindIndex(s => s != 0);
            Assert.Equal(2 * 48_000, firstSound);
        }
    }

    public class AudioConversionTests
    {
        [Fact]
        public void Pcm16IsConvertedToFloat()
        {
            var bytes = new byte[] { 0x00, 0x40, 0x00, 0xC0 }; // 16384, -16384
            var f = AudioConversion.ToFloat(bytes, 4, new InputFormat(48000, 1, 16, false));
            Assert.Equal(new[] { 0.5f, -0.5f }, f);
        }

        [Fact]
        public void Float32PassesThrough()
        {
            var source = new[] { 0.25f, -0.75f };
            var bytes = new byte[8];
            Buffer.BlockCopy(source, 0, bytes, 0, 8);
            Assert.Equal(source, AudioConversion.ToFloat(bytes, 8, new InputFormat(48000, 2, 32, true)));
        }

        [Fact]
        public void Pcm24IsConvertedToFloat()
        {
            var bytes = new byte[] { 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 };
            var f = AudioConversion.ToFloat(bytes, 6, new InputFormat(48000, 1, 24, false));
            Assert.Equal(new[] { 0.5f, -0.5f }, f);
        }

        [Fact]
        public void ChannelLayoutsFollowTheMixer()
        {
            Assert.Equal(new[] { 0.5f }, AudioConversion.ToMono(new[] { 1f, 0f }, 2));
            Assert.Equal(new[] { 0.3f, 0.3f }, AudioConversion.ToStereo(new[] { 0.3f }, 1));
            Assert.Equal(new[] { 1f, 2f, 5f, 6f }, AudioConversion.ToStereo(new[] { 1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f }, 4));
        }

        [Fact]
        public void Pcm16OutputSaturates()
        {
            var bytes = AudioConversion.ToPcm16(new[] { 2f, -2f, 0f }, 3);
            Assert.Equal(32767, BitConverter.ToInt16(bytes, 0));
            Assert.Equal(-32767, BitConverter.ToInt16(bytes, 2));
            Assert.Equal(0, BitConverter.ToInt16(bytes, 4));
        }

        [Fact]
        public void ResamplerKeepsDurationAndLevel()
        {
            var resampler = new StreamResampler(44_100, 48_000, 1);
            var output = new List<float>();
            int phase = 0;
            for (int block = 0; block < 100; block++)
            {
                var input = new float[441];
                for (int i = 0; i < input.Length; i++, phase++) input[i] = 0.5f * (float)Math.Sin(2 * Math.PI * 440 * phase / 44_100.0);
                output.AddRange(resampler.Process(input));
            }
            // Un secondo in ingresso = circa 48.000 campioni in uscita (meno la latenza del filtro).
            Assert.InRange(output.Count, 47_000, 48_100);
            float rms = Mixer.Rms(output.Skip(2000).ToArray());
            Assert.InRange(rms, 0.33f, 0.38f);
        }

        [Fact]
        public void SameRateIsUntouched()
        {
            var resampler = new StreamResampler(48_000, 48_000, 2);
            var input = new[] { 0.1f, 0.2f };
            Assert.Same(input, resampler.Process(input));
        }
    }

    public class FeedbackPayloadTests
    {
        [Fact]
        public void PayloadMatchesTheMacSchemaWithPlatform()
        {
            var app = new FeedbackAppInfo { Version = "0.3.0", Build = "12", Os = "Windows 11 23H2", Arch = "x64", Microphone = "Microfono (Realtek)" };
            string json = FeedbackPayload.ToJson("Ciao \"Federico\"\nriga due", "Liliana", "", "log", app);
            Assert.Equal(
                "{\"message\":\"Ciao \\\"Federico\\\"\\nriga due\",\"name\":\"Liliana\",\"email\":\"\",\"diagnostics\":\"log\",\"platform\":\"windows\"," +
                "\"app\":{\"version\":\"0.3.0\",\"build\":\"12\",\"os\":\"Windows 11 23H2\",\"arch\":\"x64\",\"microphone\":\"Microfono (Realtek)\"}}",
                json);
        }

        [Fact]
        public void ControlCharactersAreEscaped()
        {
            Assert.Equal("\"a\\u0001b\\\\c\"", FeedbackPayload.Quote("a\u0001b\\c"));
            Assert.Equal("\"perché è così\"", FeedbackPayload.Quote("perché è così"));
        }

        [Fact]
        public void ResponsesAreUnderstood()
        {
            Assert.Null(FeedbackResponse.ErrorFor(200, "{\"ok\":true,\"id\":\"fb:1\"}"));
            Assert.Equal("Troppi invii, riprova tra un'ora", FeedbackResponse.ErrorFor(429, "{\"ok\":false,\"error\":\"Troppi invii, riprova tra un'ora\"}"));
            Assert.Equal(FeedbackResponse.GenericError, FeedbackResponse.ErrorFor(502, "<html>Bad gateway</html>"));
            Assert.Equal(FeedbackResponse.GenericError, FeedbackResponse.ErrorFor(200, ""));
        }
    }

    internal sealed class MemorySink : IAudioSink
    {
        public List<float> Left { get; } = new List<float>();
        public List<float> Right { get; } = new List<float>();

        public void Write(float[] interleavedStereo, int frames)
        {
            for (int i = 0; i < frames; i++)
            {
                Left.Add(interleavedStereo[i * 2]);
                Right.Add(interleavedStereo[i * 2 + 1]);
            }
        }
    }
}
