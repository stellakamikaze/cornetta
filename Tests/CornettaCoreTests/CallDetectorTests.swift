import Testing
@testable import CornettaCore

struct CallDetectorTests {
    @Test func helpersAreMappedToTheirApp() {
        #expect(CallDetector.normalize("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(CallDetector.normalize("com.microsoft.teams2.helper.renderer") == "com.microsoft.teams2")
        #expect(CallDetector.normalize("com.apple.WebKit.GPU") == "com.apple.Safari")
        #expect(CallDetector.normalize("com.apple.avconferenced") == "com.apple.FaceTime")
        #expect(CallDetector.normalize("us.zoom.xos") == "us.zoom.xos")
    }

    @Test func ownProcessAndSystemServicesAreIgnored() {
        let clients = [
            MicrophoneClient(pid: 10, bundleID: "com.stellakamikaze.cornetta"),
            MicrophoneClient(pid: 11, bundleID: "com.apple.siri.embeddedspeech"),
            MicrophoneClient(pid: 12, bundleID: ""),
            MicrophoneClient(pid: 13, bundleID: "net.whatsapp.WhatsApp"),
            MicrophoneClient(pid: 14, bundleID: "com.google.Chrome.helper"),
            MicrophoneClient(pid: 15, bundleID: "com.google.Chrome.helper"),
        ]
        #expect(CallDetector.callApps(from: clients, ownPID: 10) == ["net.whatsapp.WhatsApp", "com.google.Chrome"])
    }
}
