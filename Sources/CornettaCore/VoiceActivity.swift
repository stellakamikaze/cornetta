import Foundation

/// Trova dove la voce si sente davvero, per correggere gli orari delle frasi.
/// Il riconoscimento vocale restituisce blocchi che includono il silenzio prima della frase.
public struct VoiceActivity {
    public let windowSeconds: Double
    let levels: [Float]
    let threshold: Float

    /// Livelli RMS già calcolati, una voce ogni `windowSeconds` (lettura a blocchi di file lunghi).
    public init(levels: [Float], windowSeconds: Double = 0.02) {
        self.windowSeconds = windowSeconds
        self.levels = levels
        self.threshold = Self.threshold(for: levels)
    }

    /// Soglia: 15% del livello tipico del parlato (90° percentile), mai sotto il rumore di fondo.
    static func threshold(for levels: [Float]) -> Float {
        let sorted = levels.sorted()
        let speech = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let floor = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.2)]
        return max(speech * 0.15, floor * 3, 0.002)
    }

    /// `samples` mono, `sampleRate` in Hz. Finestre da 20 ms.
    public init(samples: [Float], sampleRate: Double, windowSeconds: Double = 0.02) {
        let window = Self.windowSize(sampleRate: sampleRate, windowSeconds: windowSeconds)
        self.init(levels: Self.levels(count: samples.count, window: window) { samples[$0] }, windowSeconds: windowSeconds)
    }

    /// Campioni per finestra di analisi (20 ms di default).
    public static func windowSize(sampleRate: Double, windowSeconds: Double = 0.02) -> Int {
        max(1, Int(sampleRate * windowSeconds))
    }

    /// RMS a finestre di `window` campioni; l'ultima finestra può essere più corta.
    /// `sample(i)` dà il campione mono `i`: chi legge un file a blocchi lo chiama blocco per blocco.
    public static func levels(count: Int, window: Int, sample: (Int) -> Float) -> [Float] {
        var levels: [Float] = []
        levels.reserveCapacity(count / max(1, window) + 1)
        var start = 0
        while start < count {
            let end = min(start + window, count)
            var sum: Float = 0
            for i in start..<end {
                let value = sample(i)
                sum += value * value
            }
            levels.append(sqrt(sum / Float(end - start)))
            start = end
        }
        return levels
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
