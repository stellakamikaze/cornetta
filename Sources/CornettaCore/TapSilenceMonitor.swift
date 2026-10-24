import Foundation

/// Riconosce il guasto #3820: le callback arrivano regolari ma l'audio di sistema è fatto solo di 0.0 esatti.
/// Decide quando ricreare tap e dispositivo aggregato. Firefox manda zeri esatti anche nelle pause
/// (buchi fino a 7 s): il primo reset è dopo 20 s, il secondo dopo altri 40. Poi si avvisa una volta e si
/// riprova ogni 5 minuti finché il segnale non torna: ogni reset toglie 0,1-0,3 s anche alla voce del microfono.
struct TapSilenceMonitor {
    static let firstThreshold: Double = 20
    /// Dopo un reset, entro quanti secondi si guarda se il segnale torna.
    static let checkDelay: Double = 10
    /// Reset per serie di zeri. Dopo l'ultimo, se gli zeri restano, si avvisa l'utente.
    static let maxResets = 2
    /// Dopo `maxResets`, un tentativo ogni tanto: se il guasto passa da solo, la traccia riparte.
    static let slowRetry: Double = 300
    /// Secondi di segnale di fila perché contino: una notifica breve fra gli zeri non arma né chiude una serie.
    static let minSignal: Double = 1

    enum Outcome: Equatable {
        /// Zeri oltre la soglia: ricrea tap e dispositivo. `count` = reset di fila senza segnale.
        case reset(count: Int, zeroSeconds: Double)
        /// `checkDelay` secondi dopo il reset ancora zeri. `warn` = finiti i reset ravvicinati, avvisa l'utente (una volta).
        case stillSilent(count: Int, warn: Bool)
        /// Il segnale torna dopo almeno un reset. `warn` = era partito l'avviso, ora va tolto.
        case back(secondsAfterReset: Double, warn: Bool)
    }

    private(set) var zeroSeconds: Double = 0
    private(set) var threshold = firstThreshold
    private(set) var resets = 0
    /// Prima di un secondo di segnale gli zeri non contano: può non esserci nulla da sentire.
    private var heardSignal = false
    private var signalSeconds: Double = 0
    private var sinceReset: Double?
    private var warned = false

    /// Un blocco dell'audio di sistema: `allZero` se tutti i campioni sono 0.0 esatti.
    mutating func record(allZero: Bool, seconds: Double) -> Outcome? {
        guard allZero else {
            signalSeconds += seconds
            guard signalSeconds >= Self.minSignal else { return nil }
            heardSignal = true
            defer { zeroSeconds = 0; threshold = Self.firstThreshold; resets = 0; sinceReset = nil; warned = false }
            guard let sinceReset else { return nil }
            return .back(secondsAfterReset: sinceReset, warn: warned)
        }
        signalSeconds = 0
        guard heardSignal else { return nil }
        zeroSeconds += seconds
        if let before = sinceReset {
            sinceReset = before + seconds
            if before < Self.checkDelay, before + seconds >= Self.checkDelay {
                let warn = resets >= Self.maxResets && !warned
                warned = warned || warn
                return .stillSilent(count: resets, warn: warn)
            }
        }
        guard zeroSeconds >= threshold else { return nil }
        resets += 1
        defer { zeroSeconds = 0; threshold = resets >= Self.maxResets ? Self.slowRetry : threshold * 2; sinceReset = 0 }
        return .reset(count: resets, zeroSeconds: zeroSeconds)
    }

    /// Un reset scartato (nessuna app di chiamata): la serie riparte da capo, come se il reset non fosse
    /// avvenuto. Senza, una chiamata che parte dopo un minuto di zeri troverebbe la soglia lenta (5 minuti)
    /// e l'avviso già consumato. Il segnale già sentito resta: gli zeri continuano a contare.
    mutating func restartSeries() {
        zeroSeconds = 0
        threshold = Self.firstThreshold
        resets = 0
        sinceReset = nil
        warned = false
    }

    /// true se tutti i canali sono 0.0 esatti. Si ferma al primo campione diverso da zero.
    static func isDigitalSilence(_ channels: [[Float]]) -> Bool {
        !channels.isEmpty && channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
    }
}

/// Misura il buco lasciato da una ricostruzione della cattura, dagli orari dei blocchi audio:
/// il buco diventa silenzio e la registrazione resta allineata all'ora reale.
struct CaptureGap {
    static let minimum: Double = 0.05
    /// Come le ricostruzioni fallite di fila prima dello stop (15 x 2 s), con margine.
    static let maximum: Double = 60

    private var lastEnd: Double?
    private var rebuilt = false

    mutating func markRebuild() { rebuilt = true }

    /// Secondi di silenzio da scrivere prima del blocco. Zero se non c'è stata una ricostruzione
    /// o se l'orario del blocco non è valido (`start` nil).
    mutating func silenceBefore(start: Double?, duration: Double) -> Double {
        defer { lastEnd = start.map { $0 + duration }; rebuilt = false }
        guard rebuilt, let start, let lastEnd else { return 0 }
        let gap = start - lastEnd
        return gap > Self.minimum ? min(gap, Self.maximum) : 0
    }
}
