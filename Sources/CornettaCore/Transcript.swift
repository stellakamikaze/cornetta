import Foundation

/// Trascrizione di una registrazione, salvata in JSON accanto alla libreria.
public struct Transcript: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable {
        /// Chi registra (traccia del microfono).
        case me
        /// Le altre persone (traccia dell'audio di sistema).
        case others
        /// Registrazioni vecchie senza tracce separate: voce non attribuita.
        case mixed

        public var label: String {
            switch self {
            case .me: return "Tu"
            case .others: return "Altri"
            case .mixed: return "Voce"
            }
        }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var speaker: Speaker
        public var start: Double
        public var end: Double
        public var text: String

        public init(speaker: Speaker, start: Double, end: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var recording: String
    public var createdAt: Date
    public var engine: String
    public var language: String
    public var segments: [Segment]

    public init(recording: String, createdAt: Date = Date(), engine: String, language: String, segments: [Segment]) {
        self.recording = recording
        self.createdAt = createdAt
        self.engine = engine
        self.language = language
        self.segments = segments
    }

    /// Formato su disco: lo stesso per scrivere e per rileggere.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public var plainText: String {
        segments.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }
}

public enum TranscriptMerger {
    /// Unisce le frasi delle due tracce in ordine di tempo.
    /// Senza cuffie il microfono riprende anche gli altoparlanti: una frase della traccia «Tu» che si
    /// sovrappone nel tempo a una frase degli «Altri» con parole quasi uguali è eco, e viene scartata.
    public static func merge(me: [Transcript.Segment], others: [Transcript.Segment]) -> [Transcript.Segment] {
        let others = others.filter(isSpeech)
        let kept = me.filter(isSpeech).filter { mine in
            !others.contains { theirs in
                overlapRatio(mine, theirs) >= 0.5 && isEcho(mine.text, of: theirs.text)
            }
        }
        .map { removeEchoPhrases(from: $0, others: others) }
        .filter(isSpeech)
        return (kept + others).sorted { ($0.start, $0.speaker == .others ? 1 : 0) < ($1.start, $1.speaker == .others ? 1 : 0) }
    }

    /// Toglie da una frase «Tu» i pezzi di almeno `minWords` parole consecutive uguali a una frase
    /// degli «Altri» che si sovrappone nel tempo: è l'eco degli altoparlanti dentro un discorso più lungo.
    static func removeEchoPhrases(from mine: Transcript.Segment, others: [Transcript.Segment], minWords: Int = 4) -> Transcript.Segment {
        var tokens = mine.text.split(separator: " ").map(String.init)
        for theirs in others where max(0, min(mine.end, theirs.end) - max(mine.start, theirs.start)) > 0 {
            let reference = words(theirs.text)
            guard reference.count >= minWords else { continue }
            var changed = true
            while changed {
                changed = false
                let normalized = tokens.map { words($0).joined() }
                if let run = longestSharedRun(normalized, reference), run.count >= minWords {
                    tokens.removeSubrange(run)
                    changed = true
                }
            }
        }
        var cleaned = mine
        cleaned.text = tokens.joined(separator: " ")
        return cleaned
    }

    /// Il tratto più lungo di `tokens` che compare identico, parola per parola, dentro `reference`.
    static func longestSharedRun(_ tokens: [String], _ reference: [String]) -> Range<Int>? {
        var best: Range<Int>?
        for i in tokens.indices {
            for j in reference.indices {
                var length = 0
                while i + length < tokens.count, j + length < reference.count,
                      !tokens[i + length].isEmpty, tokens[i + length] == reference[j + length] {
                    length += 1
                }
                if length > (best?.count ?? 0) { best = i..<(i + length) }
            }
        }
        return best
    }

    /// Un frammento senza almeno due lettere (un «I» nato dal rumore) non è parlato.
    static func isSpeech(_ segment: Transcript.Segment) -> Bool {
        segment.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
    }

    /// Quota della frase `a` che cade dentro `b` (0...1).
    static func overlapRatio(_ a: Transcript.Segment, _ b: Transcript.Segment) -> Double {
        let length = max(a.end - a.start, 0.001)
        let overlap = max(0, min(a.end, b.end) - max(a.start, b.start))
        return overlap / length
    }

    /// Eco: la stessa sequenza di parole, nello stesso ordine, copre almeno il 60% della frase
    /// (e almeno 3 parole). Parole comuni in ordine diverso, come «va bene per me», non contano.
    static func isEcho(_ mine: String, of theirs: String) -> Bool {
        let a = words(mine), b = words(theirs)
        guard let run = longestSharedRun(a, b) else { return false }
        return run.count >= min(3, a.count) && Double(run.count) >= Double(a.count) * 0.6
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

public enum TranscriptFormatter {
    /// 75 → «01:15», 3725 → «1:02:05».
    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Markdown leggibile, con le battute consecutive della stessa voce unite.
    public static func markdown(_ transcript: Transcript, title: String, duration: Double?) -> String {
        var lines = ["# \(title)", ""]
        var meta: [String] = []
        if let duration { meta.append("Durata \(timestamp(duration))") }
        meta.append("Trascrizione locale di Cornetta")
        lines.append(meta.joined(separator: " · "))
        lines.append("")
        for turn in turns(transcript.segments) {
            lines.append("**\(turn.speaker.label)** (\(timestamp(turn.start))): \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Unisce le frasi consecutive della stessa voce in un unico turno.
    public static func turns(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        var result: [Transcript.Segment] = []
        for segment in segments {
            if var last = result.last, last.speaker == segment.speaker, segment.start - last.end < 2.5 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
