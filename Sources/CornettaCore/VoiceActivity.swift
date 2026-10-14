import Foundation

/// Trova dove la voce si sente davvero, per correggere gli orari delle frasi.
/// Il riconoscimento vocale restituisce blocchi che includono il silenzio prima della frase.
public struct VoiceActivity {
    public let windowSeconds: Double
    let levels: [Float]
    let threshold: Float

    /// `samples` mono, `sampleRate` in Hz. Finestre da 20 ms.
    public init(samples: [Float], sampleRate: Double, windowSeconds: Double = 0.02) {
        self.windowSeconds = windowSeconds
        let size = max(1, Int(sampleRate * windowSeconds))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / size + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            levels.append(sqrt(sum / Float(end - index)))
            index = end
        }
        self.levels = levels
        // Soglia: 15% del livello tipico del parlato (90° percentile), mai sotto il rumore di fondo.
        let sorted = levels.sorted()
        let speech = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let floor = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.2)]
        threshold = max(speech * 0.15, floor * 3, 0.002)
    }

    /// Restringe l'intervallo [start, end] alla parte in cui c'è voce. Se non trova voce, lo lascia com'è.
    public func refine(start: Double, end: Double) -> (start: Double, end: Double) {
        guard !levels.isEmpty, end > start else { return (start, end) }
        let first = max(0, Int(start / windowSeconds)), last = min(levels.count - 1, Int(end / windowSeconds))
        guard first <= last else { return (start, end) }
        guard let on = (first...last).first(where: { levels[$0] > threshold }),
              let off = (first...last).last(where: { levels[$0] > threshold }) else { return (start, end) }
        return (Double(on) * windowSeconds, Double(off + 1) * windowSeconds)
    }
}
