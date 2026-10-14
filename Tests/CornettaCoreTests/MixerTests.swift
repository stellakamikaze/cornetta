import Foundation
import Testing
@testable import CornettaCore

struct MixerTests {
    @Test func monoMicGoesToBothChannels() {
        let out = Mixer.mix(mic: [[0.5, -0.25]], system: [], frameCount: 2)
        #expect(out.left == [0.5, -0.25])
        #expect(out.right == [0.5, -0.25])
    }

    @Test func systemStereoStaysStereo() {
        let out = Mixer.mix(mic: [], system: [[0.1, 0.1], [0.2, 0.2]], frameCount: 2)
        #expect(out.left == [0.1, 0.1])
        #expect(out.right == [0.2, 0.2])
    }

    @Test func micAndSystemAreSummed() {
        let out = Mixer.mix(mic: [[0.3]], system: [[0.2], [0.4]], frameCount: 1)
        #expect(abs(out.left[0] - 0.5) < 1e-6)
        #expect(abs(out.right[0] - 0.7) < 1e-6)
    }

    @Test func multichannelMicIsAveraged() {
        let mono = Mixer.downmixToMono([[1, 0], [0, 1]], frameCount: 2)
        #expect(mono == [0.5, 0.5])
    }

    @Test func limiterNeverClips() {
        let out = Mixer.mix(mic: [[1, -1, 5]], system: [[1, -1, 5], [1, -1, 5]], frameCount: 3)
        for sample in out.left + out.right {
            #expect(abs(sample) <= 1)
        }
        #expect(Mixer.softLimit(0.5) == 0.5)
        #expect(Mixer.softLimit(-0.95) < -0.9)
    }

    @Test func shortChannelsArePaddedWithSilence() {
        let out = Mixer.mix(mic: [[0.1]], system: [[0.1, 0.1, 0.1]], frameCount: 3)
        #expect(out.left.count == 3)
        #expect(abs(out.left[2] - 0.1) < 1e-6)
    }

    @Test func rmsOfSilenceIsZero() {
        #expect(Mixer.rms([0, 0, 0]) == 0)
        #expect(abs(Mixer.rms([1, -1]) - 1) < 1e-6)
    }
}

struct FileNamingTests {
    @Test func nameContainsDateAndTime() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 14; parts.hour = 9; parts.minute = 5
        let date = Calendar.current.date(from: parts)!
        let url = FileNaming.recordingURL(in: URL(fileURLWithPath: "/tmp/x"), date: date, fileExists: { _ in false })
        #expect(url.lastPathComponent == "Chiamata 2026-10-14 09.05.m4a")
    }

    @Test func dateIsReadBackFromTheFileName() {
        let date = FileNaming.date(fromFileName: "Chiamata 2026-10-14 09.05 (2).m4a")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 14 && parts.hour == 9 && parts.minute == 5)
        #expect(FileNaming.date(fromFileName: "intervista.m4a") == nil)
    }

    @Test func existingFileIsNotOverwritten() {
        let taken: Set<String> = ["a.m4a", "Chiamata 2026-10-14 09.05.m4a", "Chiamata 2026-10-14 09.05 (2).m4a"]
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 14; parts.hour = 9; parts.minute = 5
        let date = Calendar.current.date(from: parts)!
        let url = FileNaming.recordingURL(in: URL(fileURLWithPath: "/tmp/x"), date: date,
                                          fileExists: { taken.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "Chiamata 2026-10-14 09.05 (3).m4a")
    }
}
