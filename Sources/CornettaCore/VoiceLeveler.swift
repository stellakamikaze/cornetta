import Foundation

/// Porta la voce di chi registra a un livello simile a quella della chiamata.
///
/// Durante le chiamate l'app di chiamata elabora il microfono per sé, e Cornetta riceve il segnale
/// grezzo, anche 25 dB più basso della voce in arrivo. Il livellatore:
/// - misura il livello del parlato (solo quando parli tu) e calcola il guadagno verso `target`;
/// - non amplifica il rumore di fondo nelle pause;
/// - spegne l'amplificazione mentre parla l'altra persona, perché il microfono riprende anche
///   gli altoparlanti e l'eco amplificata raddoppierebbe la sua voce.
public struct VoiceLeveler {
    public var target: Float = 0.1
    public var maxGain: Float = 16
    /// Sopra questo livello l'audio di sistema conta come «sta parlando l'altra persona».
    public var systemActiveThreshold: Float = 0.01
    /// Quanto resta spenta l'amplificazione dopo che l'altra persona ha smesso di parlare.
    public var systemHoldSeconds: Double = 0.3

    public private(set) var gain: Float = 1
    private var speechLevel: Float = 0.01
    private var noiseFloor: Float = 0.0002
    private var systemHoldRemaining: Double = 0

    public init() {}

    /// Elabora un blocco del microfono (mono) e restituisce il blocco livellato.
    public mutating func process(_ mic: [Float], systemRMS: Float, sampleRate: Double) -> [Float] {
        guard !mic.isEmpty, sampleRate > 0 else { return mic }
        let blockSeconds = Double(mic.count) / sampleRate
        let level = Mixer.rms(mic)

        // Rumore di fondo: scende subito, sale molto piano (il parlato ha pause che lo riportano giù).
        noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * Float(min(1, blockSeconds / 20))
        noiseFloor = max(noiseFloor, 0.00005)

        let systemActive = systemRMS > systemActiveThreshold
        if systemActive {
            systemHoldRemaining = systemHoldSeconds
        } else {
            systemHoldRemaining = max(0, systemHoldRemaining - blockSeconds)
        }
        let otherIsTalking = systemActive || systemHoldRemaining > 0
        let isSpeech = level > max(noiseFloor * 3, 0.0004)

        // Il livello del parlato si aggiorna solo quando parli tu (costante di tempo ~1 s).
        if isSpeech && !otherIsTalking {
            speechLevel += (level - speechLevel) * Float(min(1, blockSeconds / 1.0))
        }

        let desired: Float
        if otherIsTalking || !isSpeech {
            desired = 1
        } else {
            desired = min(max(target / max(speechLevel, 0.0001), 1), maxGain)
        }

        // Sale in 200 ms. Scende in 10 ms se parla l'altra persona, in 50 ms se la tua voce è già forte.
        // Nelle pause fra le parole scende piano (1,5 s), così le sillabe deboli non vengono tagliate.
        let tau: Double
        if desired >= gain { tau = 0.2 } else if otherIsTalking { tau = 0.01 } else if isSpeech { tau = 0.05 } else { tau = 1.5 }
        let next = gain + (desired - gain) * Float(min(1, blockSeconds / tau))
        var out = [Float](repeating: 0, count: mic.count)
        let step = (next - gain) / Float(mic.count)
        var g = gain
        for i in 0..<mic.count {
            g += step
            out[i] = mic[i] * g
        }
        gain = next
        return out
    }
}
