using System;
using System.Collections.Generic;
using System.Linq;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // Porta di Tests/CornettaCoreTests/CallDetectorTests.swift, con le chiavi del registro di Windows.
    public class CallDetectorTests
    {
        private static readonly DateTime Now = new DateTime(2026, 10, 14, 9, 0, 0, DateTimeKind.Utc);

        private static MicrophoneUse InUse(string key, bool packaged, DateTime since) =>
            new MicrophoneUse(key, packaged, since.ToFileTimeUtc(), 0);

        [Fact]
        public void HelpersAreMappedToTheirApp()
        {
            Assert.Equal("Chrome", CallDetector.DisplayName(@"C:#Program Files#Google#Chrome#Application#chrome.exe", false));
            Assert.Equal("Edge", CallDetector.DisplayName(@"C:#Program Files (x86)#Microsoft#Edge#Application#msedge.exe", false));
            Assert.Equal("Firefox", CallDetector.DisplayName(@"C:#Program Files#Mozilla Firefox#firefox.exe", false));
            Assert.Equal("Zoom", CallDetector.DisplayName(@"C:#Users#liliana#AppData#Roaming#Zoom#bin#Zoom.exe", false));
            Assert.Equal("Discord", CallDetector.DisplayName(@"C:#Users#liliana#AppData#Local#Discord#app-1.0.9#Discord.exe", false));
            Assert.Equal("Teams", CallDetector.DisplayName("MSTeams_8wekyb3d8bbwe", true));
            Assert.Equal("WhatsApp", CallDetector.DisplayName("5319275A.WhatsAppDesktop_cv1g1gvanyjgm", true));
            Assert.Equal("Skype", CallDetector.DisplayName("Microsoft.SkypeApp_kzf8qxf38zg5c", true));
            Assert.Equal("Telegram", CallDetector.DisplayName("TelegramMessengerLLP.TelegramDesktop_t4vj0pshhgkwm", true));
            Assert.Equal("Telegram", CallDetector.DisplayName(@"D:#Telegram Desktop#Telegram.exe", false));
        }

        [Fact]
        public void UnknownAppsKeepAReadableName()
        {
            Assert.Equal("Jitsi", CallDetector.DisplayName(@"C:#Apps#jitsi.exe", false));
            Assert.Equal("SuperCall", CallDetector.DisplayName("Contoso.SuperCall_abc123", true));
        }

        [Fact]
        public void OwnProcessAndSystemServicesAreIgnored()
        {
            var uses = new List<MicrophoneUse>
            {
                InUse(@"C:#Users#liliana#AppData#Local#Cornetta#current#Cornetta.exe", false, Now),
                InUse("Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe", true, Now),
                InUse("MicrosoftWindows.Client.CBS_cw5n1h2txyewy", true, Now),
                InUse("5319275A.WhatsAppDesktop_cv1g1gvanyjgm", true, Now),
                InUse(@"C:#Program Files#Google#Chrome#Application#chrome.exe", false, Now),
                InUse(@"C:#Program Files (x86)#Google#Chrome#Application#chrome.exe", false, Now.AddSeconds(-30)),
                new MicrophoneUse(@"C:#Program Files#Mozilla Firefox#firefox.exe", false, Now.AddMinutes(-5).ToFileTimeUtc(), Now.AddMinutes(-4).ToFileTimeUtc()),
            };
            var apps = CallDetector.CallApps(uses);
            Assert.Equal(new[] { "WhatsApp", "Chrome" }, apps.Select(a => a.Name).ToArray());
            // Due voci di Chrome: vale l'inizio più vecchio.
            Assert.Equal(Now.AddSeconds(-30), apps[1].Since);
        }

        [Fact]
        public void StopZeroMeansInUse()
        {
            Assert.True(new MicrophoneUse("x", true, Now.ToFileTimeUtc(), 0).InUse);
            Assert.False(new MicrophoneUse("x", true, Now.ToFileTimeUtc(), Now.AddSeconds(5).ToFileTimeUtc()).InUse);
            Assert.False(new MicrophoneUse("x", true, 0, 0).InUse);
        }
    }

    public class CallMonitorTests
    {
        private static readonly DateTime T0 = new DateTime(2026, 10, 14, 9, 0, 0, DateTimeKind.Utc);
        private static readonly IReadOnlyList<CallApp> None = new List<CallApp>();

        private static IReadOnlyList<CallApp> Apps(params string[] names) => names.Select(n => new CallApp(n, null)).ToList();

        [Fact]
        public void PromptsOnlyAfterFourSeconds()
        {
            var monitor = new CallMonitor();
            Assert.Null(monitor.Poll(T0, Apps("Teams"), false, true, false, false).PromptApp);
            Assert.Null(monitor.Poll(T0.AddSeconds(2), Apps("Teams"), false, true, false, false).PromptApp);
            Assert.Equal("Teams", monitor.Poll(T0.AddSeconds(4), Apps("Teams"), false, true, false, false).PromptApp);
            // Una volta sola per chiamata.
            Assert.Null(monitor.Poll(T0.AddSeconds(6), Apps("Teams"), false, true, false, false).PromptApp);
        }

        [Fact]
        public void RegistryStartTimeCountsToo()
        {
            var monitor = new CallMonitor();
            var apps = new List<CallApp> { new CallApp("Zoom", T0.AddSeconds(-10)) };
            Assert.Equal("Zoom", monitor.Poll(T0, apps, false, true, false, false).PromptApp);
        }

        [Fact]
        public void NoPromptWhenTheOptionIsOffOrANoticeIsOpen()
        {
            var monitor = new CallMonitor();
            var apps = new List<CallApp> { new CallApp("Zoom", T0.AddSeconds(-10)) };
            Assert.Null(monitor.Poll(T0, apps, false, false, false, false).PromptApp);
            Assert.Null(monitor.Poll(T0, apps, false, true, true, false).PromptApp);
        }

        [Fact]
        public void NewCallOfTheSameAppPromptsAgain()
        {
            var monitor = new CallMonitor();
            monitor.Poll(T0, Apps("Teams"), false, true, false, false);
            Assert.Equal("Teams", monitor.Poll(T0.AddSeconds(4), Apps("Teams"), false, true, false, false).PromptApp);
            monitor.Poll(T0.AddSeconds(60), None, false, true, false, false);
            monitor.Poll(T0.AddSeconds(120), Apps("Teams"), false, true, false, false);
            Assert.Equal("Teams", monitor.Poll(T0.AddSeconds(124), Apps("Teams"), false, true, false, false).PromptApp);
        }

        [Fact]
        public void CallNoticeClosesWhenTheAppLeavesTheMicrophone()
        {
            var monitor = new CallMonitor();
            var result = monitor.Poll(T0, None, false, true, true, true);
            Assert.True(result.CloseCallNotice);
        }

        [Fact]
        public void CallEndedAfterSixSecondsWithoutApps()
        {
            var monitor = new CallMonitor();
            monitor.Poll(T0, Apps("WhatsApp"), false, true, false, false);
            monitor.RecordingStarted(T0);
            Assert.False(monitor.Poll(T0.AddSeconds(2), Apps("WhatsApp"), true, true, false, false).CallEnded);
            Assert.False(monitor.Poll(T0.AddSeconds(4), None, true, true, false, false).CallEnded);
            Assert.False(monitor.Poll(T0.AddSeconds(8), None, true, true, false, false).CallEnded);
            Assert.True(monitor.Poll(T0.AddSeconds(10), None, true, true, false, false).CallEnded);
            Assert.True(monitor.CallEndedSuggested);
            // Una volta sola.
            Assert.False(monitor.Poll(T0.AddSeconds(12), None, true, true, false, false).CallEnded);
            // La chiamata riprende: via il banner.
            Assert.True(monitor.Poll(T0.AddSeconds(14), Apps("WhatsApp"), true, true, false, false).CallResumed);
            Assert.False(monitor.CallEndedSuggested);
        }

        [Fact]
        public void NoEndedBannerIfRecordingStartedWithoutACall()
        {
            var monitor = new CallMonitor();
            monitor.Poll(T0, None, false, true, false, false);
            monitor.RecordingStarted(T0);
            Assert.False(monitor.Poll(T0.AddSeconds(30), None, true, true, false, false).CallEnded);
        }

        [Fact]
        public void ContinueSilencesTheBannerUntilTheNextCall()
        {
            var monitor = new CallMonitor();
            monitor.Poll(T0, Apps("Zoom"), false, true, false, false);
            monitor.RecordingStarted(T0);
            Assert.True(monitor.Poll(T0.AddSeconds(8), None, true, true, false, false).CallEnded);
            monitor.DismissCallEnded();
            Assert.False(monitor.Poll(T0.AddSeconds(30), None, true, true, false, false).CallEnded);
            monitor.Poll(T0.AddSeconds(32), Apps("Zoom"), true, true, false, false);
            Assert.True(monitor.Poll(T0.AddSeconds(40), None, true, true, false, false).CallEnded);
        }
    }
}
