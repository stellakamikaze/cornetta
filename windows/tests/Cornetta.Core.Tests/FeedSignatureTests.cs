using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // Firma del feed Windows (#3501). Vettore prodotto da windows/tools/sign-feed.py con una chiave di prova
    // usa e getta: la privata non esiste più, qui servono solo la pubblica e la firma. Lo stesso vettore lo
    // verifica openssl in scripts/tests/test_sign_feed.py, che legge le costanti da questo file.
    public class FeedSignatureTests
    {
        private const string TestPublicKey = "caf0a9707c2d392a0e813222b30f13d459fb62f2dae24d0105eacdec4fc2eafee0440c483eb35d2d350c7bf73983c964f2e799051cc0bdbdb5b1d5802d6de8e7";
        private const string TestFeed = "{\"Assets\":[{\"PackageId\":\"Cornetta\",\"Version\":\"0.4.0\",\"Type\":\"Full\",\"FileName\":\"Cornetta-0.4.0-full.nupkg\",\"SHA1\":\"1111111111111111111111111111111111111111\",\"SHA256\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"Size\":1234567,\"NotesMarkdown\":\"\",\"NotesHtml\":\"\"}]}";
        private const string TestSignature = "YtvxQ+UTyl1M6akrCWXwnhSuo970xiGo9l1YIWnbMopo1s2eKenNf0Kf8LQ0uq/eht+vZKeFEOrb3FRbaYEzYw==";

        private static byte[] Feed => Encoding.UTF8.GetBytes(TestFeed);

        [Fact]
        public void SignatureFromSignFeedIsValid()
        {
            Assert.Null(FeedSignature.Verify(Feed, TestSignature, TestPublicKey));
            Assert.Null(FeedSignature.Verify(Feed, TestSignature + "\n", TestPublicKey));
        }

        [Fact]
        public void ChangedFeedIsRefused()
        {
            byte[] changed = Encoding.UTF8.GetBytes(TestFeed.Replace("1234567", "1234568"));
            Assert.Equal("firma del feed non valida", FeedSignature.Verify(changed, TestSignature, TestPublicKey));
        }

        [Fact]
        public void PlaceholderKeyRefusesEverything()
        {
            Assert.NotNull(FeedSignature.Verify(Feed, TestSignature, FeedSignature.Placeholder));
            Assert.NotNull(FeedSignature.Verify(Feed, TestSignature, ""));
        }

        [Fact]
        public void MissingOrBrokenSignatureIsRefused()
        {
            Assert.NotNull(FeedSignature.Verify(Feed, "", TestPublicKey));
            Assert.NotNull(FeedSignature.Verify(Feed, "non è base64!", TestPublicKey));
            Assert.NotNull(FeedSignature.Verify(Feed, Convert.ToBase64String(new byte[64]), TestPublicKey));
            Assert.NotNull(FeedSignature.Verify(Feed, Convert.ToBase64String(new byte[70]), TestPublicKey));
        }

        [Fact]
        public void AnotherKeyIsRefused()
        {
            string other = TestPublicKey.Substring(0, 126) + (TestPublicKey.EndsWith("00") ? "01" : "00");
            Assert.NotNull(FeedSignature.Verify(Feed, TestSignature, other));
        }

        [Fact]
        public void AssetsAreReadFromTheSignedFeed()
        {
            byte[] withBom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Feed).ToArray();
            var assets = FeedSignature.ParseAssets(withBom);
            Assert.NotNull(assets);
            var asset = Assert.Single(assets!);
            Assert.Equal("Cornetta-0.4.0-full.nupkg", asset.FileName);
            Assert.Equal(1234567L, asset.Size);
            Assert.Equal(new string('2', 64), asset.Sha256);
            Assert.Null(FeedSignature.ParseAssets(Encoding.UTF8.GetBytes("non è json")));
        }

        [Fact]
        public void OnlyPackagesOfTheSignedFeedPass()
        {
            var signed = FeedSignature.ParseAssets(Feed)!;
            var good = new FeedAsset { FileName = "Cornetta-0.4.0-full.nupkg", Size = 1234567, Sha1 = new string('1', 40), Sha256 = new string('2', 64).ToUpperInvariant() };
            Assert.Null(FeedSignature.Covers(signed, good));
            Assert.NotNull(FeedSignature.Covers(signed, new FeedAsset { FileName = good.FileName, Size = good.Size, Sha256 = new string('3', 64) }));
            Assert.NotNull(FeedSignature.Covers(signed, new FeedAsset { FileName = good.FileName, Size = 1, Sha256 = good.Sha256 }));
            Assert.NotNull(FeedSignature.Covers(signed, new FeedAsset { FileName = "Cornetta-6.6.6-full.nupkg", Size = good.Size, Sha256 = good.Sha256 }));
            var noHash = new List<FeedAsset> { new FeedAsset { FileName = good.FileName, Size = good.Size } };
            Assert.NotNull(FeedSignature.Covers(noHash, good));
        }
    }
}
