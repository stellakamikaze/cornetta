using System;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // Porta di Tests/CornettaCoreTests/MixerTests.swift.
    public class MixerTests
    {
        [Fact]
        public void MonoMicGoesToBothChannels()
        {
            var output = Mixer.Mix(new[] { new[] { 0.5f, -0.25f } }, new float[0][], 2);
            Assert.Equal(new[] { 0.5f, -0.25f }, output.Left);
            Assert.Equal(new[] { 0.5f, -0.25f }, output.Right);
        }

        [Fact]
        public void SystemStereoStaysStereo()
        {
            var output = Mixer.Mix(new float[0][], new[] { new[] { 0.1f, 0.1f }, new[] { 0.2f, 0.2f } }, 2);
            Assert.Equal(new[] { 0.1f, 0.1f }, output.Left);
            Assert.Equal(new[] { 0.2f, 0.2f }, output.Right);
        }

        [Fact]
        public void MicAndSystemAreSummed()
        {
            var output = Mixer.Mix(new[] { new[] { 0.3f } }, new[] { new[] { 0.2f }, new[] { 0.4f } }, 1);
            Assert.True(Math.Abs(output.Left[0] - 0.5f) < 1e-6);
            Assert.True(Math.Abs(output.Right[0] - 0.7f) < 1e-6);
        }

        [Fact]
        public void MultichannelMicIsAveraged()
        {
            var mono = Mixer.DownmixToMono(new[] { new[] { 1f, 0f }, new[] { 0f, 1f } }, 2);
            Assert.Equal(new[] { 0.5f, 0.5f }, mono);
        }

        [Fact]
        public void LimiterNeverClips()
        {
            var output = Mixer.Mix(new[] { new[] { 1f, -1f, 5f } }, new[] { new[] { 1f, -1f, 5f }, new[] { 1f, -1f, 5f } }, 3);
            foreach (var sample in output.Left) Assert.True(Math.Abs(sample) <= 1);
            foreach (var sample in output.Right) Assert.True(Math.Abs(sample) <= 1);
            Assert.Equal(0.5f, Mixer.SoftLimit(0.5f));
            Assert.True(Mixer.SoftLimit(-0.95f) < -0.9f);
        }

        [Fact]
        public void ShortChannelsArePaddedWithSilence()
        {
            var output = Mixer.Mix(new[] { new[] { 0.1f } }, new[] { new[] { 0.1f, 0.1f, 0.1f } }, 3);
            Assert.Equal(3, output.Left.Length);
            Assert.True(Math.Abs(output.Left[2] - 0.1f) < 1e-6);
        }

        [Fact]
        public void RmsOfSilenceIsZero()
        {
            Assert.Equal(0f, Mixer.Rms(new[] { 0f, 0f, 0f }));
            Assert.True(Math.Abs(Mixer.Rms(new[] { 1f, -1f }) - 1) < 1e-6);
        }
    }

    // Porta di FileNamingTests (in MixerTests.swift).
    public class FileNamingTests
    {
        private static readonly DateTime Date = new DateTime(2026, 10, 14, 9, 5, 0);

        [Fact]
        public void NameContainsDateAndTime()
        {
            string path = FileNaming.RecordingPath("x", Date, _ => false);
            Assert.Equal("Chiamata 2026-10-14 09.05.m4a", System.IO.Path.GetFileName(path));
        }

        [Fact]
        public void ExistingFileIsNotOverwritten()
        {
            var taken = new[] { "a.m4a", "Chiamata 2026-10-14 09.05.m4a", "Chiamata 2026-10-14 09.05 (2).m4a" };
            string path = FileNaming.RecordingPath("x", Date, p => Array.IndexOf(taken, System.IO.Path.GetFileName(p)) >= 0);
            Assert.Equal("Chiamata 2026-10-14 09.05 (3).m4a", System.IO.Path.GetFileName(path));
        }

        [Fact]
        public void WavFallbackKeepsTheSameName()
        {
            string path = FileNaming.RecordingPath("x", Date, _ => false, ".wav");
            Assert.Equal("Chiamata 2026-10-14 09.05.wav", System.IO.Path.GetFileName(path));
        }

        [Fact]
        public void ElapsedTextMatchesTheMac()
        {
            Assert.Equal("00:00", TimeText.Elapsed(TimeSpan.Zero));
            Assert.Equal("04:07", TimeText.Elapsed(TimeSpan.FromSeconds(247.9)));
            Assert.Equal("1:04:07", TimeText.Elapsed(TimeSpan.FromSeconds(3847)));
        }
    }
}
