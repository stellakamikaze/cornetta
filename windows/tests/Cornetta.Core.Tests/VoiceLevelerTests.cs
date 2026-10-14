using System;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // Porta di Tests/CornettaCoreTests/VoiceLevelerTests.swift: stessi segnali, stesse soglie.
    public class VoiceLevelerTests
    {
        private const double Rate = 44_100.0;
        private const int Block = 512;

        private static float[] Tone(float amplitude, int count, ref int phase)
        {
            var output = new float[count];
            for (int i = 0; i < count; i++)
            {
                output[i] = amplitude * (float)Math.Sin(2 * (float)Math.PI * 220 * (float)phase / 44_100f);
                phase++;
            }
            return output;
        }

        /// <summary>Voce grezza a -45 dBFS circa, l'altra persona in silenzio: dopo 3 s arriva vicino al target.</summary>
        [Fact]
        public void QuietVoiceIsBroughtUp()
        {
            var leveler = new VoiceLeveler();
            int phase = 0;
            float[] last = new float[0];
            for (int i = 0; i < (int)(3 * Rate) / Block; i++)
            {
                last = leveler.Process(Tone(0.007f, Block, ref phase), 0, Rate);
            }
            float rms = Mixer.Rms(last);
            Assert.True(rms > 0.04f && rms < 0.1f, "rms " + rms);
            Assert.True(leveler.Gain > 8, "gain " + leveler.Gain);
        }

        /// <summary>Mentre parla l'altra persona il microfono non viene amplificato (eco dagli altoparlanti).</summary>
        [Fact]
        public void NoBoostWhileOtherPersonTalks()
        {
            var leveler = new VoiceLeveler();
            int phase = 0;
            for (int i = 0; i < (int)(2 * Rate) / Block; i++)
            {
                leveler.Process(Tone(0.007f, Block, ref phase), 0, Rate);
            }
            Assert.True(leveler.Gain > 4);
            for (int i = 0; i < (int)(0.2 * Rate) / Block; i++)
            {
                leveler.Process(Tone(0.007f, Block, ref phase), 0.08f, Rate);
            }
            Assert.True(leveler.Gain < 1.2f, "gain " + leveler.Gain);
        }

        /// <summary>Il rumore di fondo nelle pause non viene amplificato.</summary>
        [Fact]
        public void BackgroundNoiseIsNotBoosted()
        {
            var leveler = new VoiceLeveler();
            int phase = 0;
            for (int i = 0; i < (int)(3 * Rate) / Block; i++)
            {
                leveler.Process(Tone(0.0002f, Block, ref phase), 0, Rate);
            }
            Assert.True(leveler.Gain < 1.5f, "gain " + leveler.Gain);
        }

        /// <summary>Una voce già forte non viene toccata.</summary>
        [Fact]
        public void LoudVoiceIsLeftAlone()
        {
            var leveler = new VoiceLeveler();
            int phase = 0;
            for (int i = 0; i < (int)(3 * Rate) / Block; i++)
            {
                leveler.Process(Tone(0.2f, Block, ref phase), 0, Rate);
            }
            Assert.True(leveler.Gain < 1.05f, "gain " + leveler.Gain);
        }

        /// <summary>Su Windows il livellatore lavora a 48 kHz con blocchi da 10 ms: il comportamento resta lo stesso.</summary>
        [Fact]
        public void SameBehaviourAtTheWindowsBlockSize()
        {
            var leveler = new VoiceLeveler();
            float[] last = new float[0];
            int phase = 0;
            for (int i = 0; i < 300; i++)
            {
                var block = new float[RecordingPipeline.BlockFrames];
                for (int j = 0; j < block.Length; j++, phase++) block[j] = 0.007f * (float)Math.Sin(2 * Math.PI * 220 * phase / 48_000.0);
                last = leveler.Process(block, 0, 48_000);
            }
            float rms = Mixer.Rms(last);
            Assert.True(rms > 0.04f && rms < 0.1f, "rms " + rms);
        }
    }
}
