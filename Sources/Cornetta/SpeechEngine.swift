import AVFoundation
import CornettaCore
import Speech

/// Trascrizione sul Mac con il motore vocale di Apple (macOS 26). Nessun dato esce dal computer.
enum SpeechEngine {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static let engineName = "Apple SpeechTranscriber"

    /// Lingua: quella del Mac se supportata, altrimenti italiano.
    @available(macOS 26.0, *)
    static func locale() async -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return match }
        return Locale(identifier: "it_IT")
    }

    /// Scarica il modello della lingua se manca (succede una volta sola).
    @available(macOS 26.0, *)
    static func prepare(locale: Locale, status: @escaping @Sendable (String) -> Void) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            status("Preparo il modello della lingua…")
            try await request.downloadAndInstall()
        }
    }

    /// Trascrive un file e lo divide in frasi con l'orario di inizio e fine.
    @available(macOS 26.0, *)
    static func transcribe(_ url: URL, speaker: Transcript.Speaker, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Segment] {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        guard duration > 0.3 else { return [] }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Transcript.Segment] in
            var segments: [Transcript.Segment] = []
            for try await result in transcriber.results {
                segments += sentences(in: result.text, speaker: speaker)
                progress(min(result.range.end.seconds / duration, 1))
            }
            return segments
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let segments = try await collector.value
        guard let activity = voiceActivity(of: url) else { return segments }
        return segments.map { segment in
            var refined = segment
            (refined.start, refined.end) = activity.refine(start: segment.start, end: segment.end)
            return refined
        }
    }

    /// Profilo di energia della traccia, per riportare gli orari all'inizio vero della voce.
    /// Legge a blocchi da 1 s: un'ora di chiamata non finisce tutta in memoria.
    private static func voiceActivity(of url: URL) -> VoiceActivity? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let window = VoiceActivity.windowSize(sampleRate: file.processingFormat.sampleRate)
        let chunk = AVAudioFrameCount(window * 50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var levels: [Float] = []
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
            // Il blocco è un multiplo della finestra: le finestre non scavalcano due letture.
            levels += VoiceActivity.levels(count: frames, window: window) { i in
                var mono: Float = 0
                for c in 0..<channels { mono += data[c][i] }
                return mono / Float(channels)
            }
        }
        return VoiceActivity(levels: levels)
    }

    /// Divide il testo riconosciuto in frasi, usando l'orario di ogni parola.
    @available(macOS 26.0, *)
    private static func sentences(in text: AttributedString, speaker: Transcript.Speaker) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var current = ""
        var start: Double?
        var end: Double = 0
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                if start == nil, !piece.trimmingCharacters(in: .whitespaces).isEmpty { start = range.start.seconds }
                end = max(end, range.end.seconds)
            }
            current += piece
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.last, ".?!…".contains(last), trimmed.count > 1 {
                segments.append(.init(speaker: speaker, start: start ?? end, end: end, text: trimmed))
                current = ""
                start = nil
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { segments.append(.init(speaker: speaker, start: start ?? end, end: end, text: rest)) }
        return segments
    }
}
