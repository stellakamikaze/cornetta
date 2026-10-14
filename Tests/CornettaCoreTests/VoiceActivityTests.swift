import Foundation
import Testing
@testable import CornettaCore

struct VoiceActivityTests {
    /// 2 s di silenzio, 1 s di voce, 1 s di silenzio a 16 kHz.
    func signal() -> [Float] {
        var s = [Float](repeating: 0.0005, count: 32_000)
        s += (0..<16_000).map { Float(sin(Double($0) * 0.2)) * 0.2 }
        s += [Float](repeating: 0.0005, count: 16_000)
        return s
    }

    @Test func startMovesToWhereTheVoiceBegins() {
        let vad = VoiceActivity(samples: signal(), sampleRate: 16_000)
        let refined = vad.refine(start: 0, end: 4)
        #expect(abs(refined.start - 2.0) < 0.05)
        #expect(abs(refined.end - 3.0) < 0.05)
    }

    @Test func silentRangeIsLeftAlone() {
        let vad = VoiceActivity(samples: signal(), sampleRate: 16_000)
        let refined = vad.refine(start: 0.2, end: 1.5)
        #expect(refined.start == 0.2 && refined.end == 1.5)
    }
}
