import Foundation

/// Unisce la voce del microfono e l'audio di sistema in un segnale stereo.
public enum Mixer {
    /// Soglia oltre la quale il limitatore comprime il segnale.
    public static let limiterThreshold: Float = 0.9

    /// Riduce N canali a uno solo con la media. Zero canali = silenzio.
    public static func downmixToMono(_ channels: [[Float]], frameCount: Int) -> [Float] {
        guard !channels.isEmpty else { return [Float](repeating: 0, count: frameCount) }
        var out = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channels.count)
        for channel in channels {
            for i in 0..<min(frameCount, channel.count) {
                out[i] += channel[i] * scale
            }
        }
        return out
    }

    /// Porta N canali a stereo: mono duplicato, oltre due canali tiene i primi due.
    public static func toStereo(_ channels: [[Float]], frameCount: Int) -> (left: [Float], right: [Float]) {
        let silence = [Float](repeating: 0, count: frameCount)
        switch channels.count {
        case 0: return (silence, silence)
        case 1: return (padded(channels[0], frameCount), padded(channels[0], frameCount))
        default: return (padded(channels[0], frameCount), padded(channels[1], frameCount))
        }
    }

    /// Mix finale: microfono al centro (su L e R) più audio di sistema stereo, con limitatore.
    public static func mix(mic: [[Float]], system: [[Float]], frameCount: Int, micGain: Float = 1, systemGain: Float = 1) -> (left: [Float], right: [Float]) {
        let micMono = downmixToMono(mic, frameCount: frameCount)
        let sys = toStereo(system, frameCount: frameCount)
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let m = micMono[i] * micGain
            left[i] = softLimit(m + sys.left[i] * systemGain)
            right[i] = softLimit(m + sys.right[i] * systemGain)
        }
        return (left, right)
    }

    /// Lascia intatto il segnale sotto soglia, sopra lo comprime verso 1 senza mai superarlo.
    public static func softLimit(_ x: Float) -> Float {
        let t = limiterThreshold
        let magnitude = abs(x)
        guard magnitude > t else { return x }
        let compressed = t + (1 - t) * tanh((magnitude - t) / (1 - t))
        return x < 0 ? -compressed : compressed
    }

    /// Valore efficace di un segnale: serve a misurare se una traccia contiene audio.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private static func padded(_ channel: [Float], _ frameCount: Int) -> [Float] {
        if channel.count >= frameCount { return Array(channel.prefix(frameCount)) }
        return channel + [Float](repeating: 0, count: frameCount - channel.count)
    }
}
