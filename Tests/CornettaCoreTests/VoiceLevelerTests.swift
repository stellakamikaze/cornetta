import Foundation
import Testing
@testable import CornettaCore

struct VoiceLevelerTests {
    let rate = 44_100.0
    let block = 512

    func tone(_ amplitude: Float, count: Int, phase: inout Int) -> [Float] {
        (0..<count).map { _ in
            defer { phase += 1 }
            return amplitude * sin(2 * .pi * 220 * Float(phase) / Float(44_100))
        }
    }

    /// Voce grezza a -45 dBFS circa, l'altra persona in silenzio: dopo 3 s arriva vicino al target.
    @Test func quietVoiceIsBroughtUp() {
        var leveler = VoiceLeveler()
        var phase = 0
        var last: [Float] = []
        for _ in 0..<Int(3 * rate) / block {
            last = leveler.process(tone(0.007, count: block, phase: &phase), systemRMS: 0, sampleRate: rate)
        }
        let rms = Mixer.rms(last)
        #expect(rms > 0.04 && rms < 0.1)
        #expect(leveler.gain > 8)
    }

    /// Mentre parla l'altra persona il microfono non viene amplificato (eco dagli altoparlanti).
    @Test func noBoostWhileOtherPersonTalks() {
        var leveler = VoiceLeveler()
        var phase = 0
        for _ in 0..<Int(2 * rate) / block {
            _ = leveler.process(tone(0.007, count: block, phase: &phase), systemRMS: 0, sampleRate: rate)
        }
        #expect(leveler.gain > 4)
        for _ in 0..<Int(0.2 * rate) / block {
            _ = leveler.process(tone(0.007, count: block, phase: &phase), systemRMS: 0.08, sampleRate: rate)
        }
        #expect(leveler.gain < 1.2)
    }

    /// Il rumore di fondo nelle pause non viene amplificato.
    @Test func backgroundNoiseIsNotBoosted() {
        var leveler = VoiceLeveler()
        var phase = 0
        for _ in 0..<Int(3 * rate) / block {
            _ = leveler.process(tone(0.0002, count: block, phase: &phase), systemRMS: 0, sampleRate: rate)
        }
        #expect(leveler.gain < 1.5)
    }

    /// Una voce già forte non viene toccata.
    @Test func loudVoiceIsLeftAlone() {
        var leveler = VoiceLeveler()
        var phase = 0
        for _ in 0..<Int(3 * rate) / block {
            _ = leveler.process(tone(0.2, count: block, phase: &phase), systemRMS: 0, sampleRate: rate)
        }
        #expect(leveler.gain < 1.05)
    }
}
