using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // La diagnostica del feedback non deve portare il nome utente di Windows (#3503).
    public class PathPrivacyTests
    {
        [Fact]
        public void OwnProfileBecomesTilde()
        {
            string text = @"App: C:\Users\Mario.Rossi\AppData\Local\Cornetta\current\Cornetta.exe" + "\n" +
                          @"Registrazioni: c:\users\mario.rossi\Music\Cornetta";
            string clean = PathPrivacy.Anonymize(text, @"C:\Users\Mario.Rossi");
            Assert.Equal(@"App: ~\AppData\Local\Cornetta\current\Cornetta.exe" + "\n" + @"Registrazioni: ~\Music\Cornetta", clean);
        }

        [Fact]
        public void ProfileOutsideUsersAndForwardSlashes()
        {
            string clean = PathPrivacy.Anonymize(@"log D:/Profili/anna/OneDrive - Studio/Musica", @"D:\Profili\anna");
            Assert.Equal(@"log ~/OneDrive - Studio/Musica", clean);
        }

        [Fact]
        public void OtherUsersFoldersLoseTheName()
        {
            string clean = PathPrivacy.Anonymize(@"Errore su C:\Users\giulia bianchi\Music\x.m4a", @"C:\Users\mario");
            Assert.Equal(@"Errore su C:\Users\<utente>\Music\x.m4a", clean);
            Assert.DoesNotContain("giulia", clean);
        }

        [Fact]
        public void LongerNameWithSamePrefixIsNotCutInHalf()
        {
            string clean = PathPrivacy.Anonymize(@"C:\Users\mariolina\Music", @"C:\Users\mario");
            Assert.Equal(@"C:\Users\<utente>\Music", clean);
            string other = PathPrivacy.Anonymize(@"C:\Users\mario rossi\Music", @"C:\Users\mario");
            Assert.Equal(@"C:\Users\<utente>\Music", other);
        }

        [Fact]
        public void DiagnosticsAreOffByDefault()
        {
            Assert.False(FeedbackPayload.DiagnosticsByDefault);
        }

        [Fact]
        public void TextWithoutPathsStaysTheSame()
        {
            Assert.Equal("Microfono: Brio 300", PathPrivacy.Anonymize("Microfono: Brio 300", @"C:\Users\mario"));
            Assert.Equal("", PathPrivacy.Anonymize("", null));
        }
    }
}
