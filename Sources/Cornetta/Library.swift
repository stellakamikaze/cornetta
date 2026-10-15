import AppKit
import AVFoundation
import CornettaCore
import SwiftUI

/// Le registrazioni in ~/Music/Cornetta con le loro trascrizioni.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    enum Status: Equatable {
        case notTranscribed
        case queued
        case transcribing(Double, String)
        case done
        case failed(String)
    }

    struct Recording: Identifiable, Equatable {
        let url: URL
        let date: Date
        let duration: Double
        var id: String { url.lastPathComponent }
        var hasTracks: Bool
    }

    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var transcripts: [String: Transcript] = [:]
    @Published private(set) var statuses: [String: Status] = [:]
    @AppStorage("autoTranscribe") var autoTranscribe = true
    @AppStorage("saveMarkdown") var saveMarkdown = true

    /// Chiamato quando una trascrizione è pronta (per l'avviso).
    var onTranscriptReady: ((Recording) -> Void)?

    private var queue: [URL] = []
    private var working = false

    private var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cornetta", isDirectory: true)
    private var recordingsFolder = FileNaming.defaultDirectory

    /// Solo per `--demo-library`: libreria in una cartella separata, le registrazioni vere non si toccano.
    func useDemoFolders(recordings: URL, support: URL) {
        recordingsFolder = recordings
        self.support = support
        transcripts = [:]
        statuses = [:]
        reload()
    }
    private var workingRoot: URL { support.appendingPathComponent("In corso", isDirectory: true) }

    func workingDirectory(for recording: URL) -> URL {
        workingRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Registrazioni interrotte da un crash o da uno spegnimento: le converte e le rimette in libreria.
    func recoverInterruptedRecordings(onRecovered: @escaping (String) -> Void) {
        let leftovers = RecordingFinalizer.leftovers(in: workingRoot)
        guard !leftovers.isEmpty else { return }
        let folder = recordingsFolder
        for working in leftovers {
            let name = working.lastPathComponent
            let output = FileNaming.uniqueURL(in: folder, baseName: name)
            let tracks = tracksDirectory(for: output)
            Diagnostics.log("Recupero la registrazione interrotta: \(name)")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try RecordingFinalizer.finalize(workingDirectory: working, output: output, tracksDirectory: tracks) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        Diagnostics.log(String(format: "Recuperata: %@ (%.0f s)", output.lastPathComponent, r.seconds))
                        self.recordingFinished(output)
                        onRecovered(output.lastPathComponent)
                    case .failure(let error):
                        Diagnostics.log("Recupero non riuscito per \(name): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private var tracksRoot: URL { support.appendingPathComponent("Tracce", isDirectory: true) }
    private var transcriptsRoot: URL { support.appendingPathComponent("Trascrizioni", isDirectory: true) }

    func tracksDirectory(for recording: URL) -> URL {
        tracksRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func transcriptURL(for recording: URL) -> URL {
        transcriptsRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".json")
    }

    func markdownURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("md")
    }

    // MARK: - Caricamento

    func reload() {
        let folder = recordingsFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        recordings = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map { url in
                let date = FileNaming.date(fromFileName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                let tracks = FileManager.default.fileExists(atPath: tracksDirectory(for: url).appendingPathComponent(RecordingFinalizer.othersTrack).path)
                return Recording(url: url, date: date, duration: duration, hasTracks: tracks)
            }
            .sorted { $0.date > $1.date }

        for recording in recordings where transcripts[recording.id] == nil {
            if let data = try? Data(contentsOf: transcriptURL(for: recording.url)),
               let transcript = try? Transcript.decoder.decode(Transcript.self, from: data) {
                transcripts[recording.id] = transcript
                statuses[recording.id] = .done
            } else if statuses[recording.id] == nil {
                statuses[recording.id] = .notTranscribed
            }
        }
    }

    func status(_ recording: Recording) -> Status { statuses[recording.id] ?? .notTranscribed }

    // MARK: - Trascrizione

    /// Registrazioni con tracce ma senza trascrizione (app chiusa a metà): tornano in coda.
    func resumePendingTranscriptions() {
        guard autoTranscribe, SpeechEngine.isAvailable else { return }
        for recording in recordings where recording.hasTracks && transcripts[recording.id] == nil {
            enqueue(recording.url)
        }
    }

    /// Dopo lo stop: la registrazione entra nella libreria e, se l'opzione è attiva, in coda.
    func recordingFinished(_ url: URL) {
        reload()
        if autoTranscribe { enqueue(url) }
    }

    func enqueue(_ url: URL) {
        guard SpeechEngine.isAvailable else { return }
        guard !queue.contains(url) else { return }
        queue.append(url)
        statuses[url.lastPathComponent] = .queued
        processNext()
    }

    private func processNext() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let url = queue.removeFirst()
        Task {
            await transcribe(url)
            working = false
            processNext()
        }
    }

    private func transcribe(_ url: URL) async {
        guard #available(macOS 26.0, *) else { return }
        let id = url.lastPathComponent
        let tracks = tracksDirectory(for: url)
        let me = tracks.appendingPathComponent(RecordingFinalizer.meTrack), others = tracks.appendingPathComponent(RecordingFinalizer.othersTrack)
        let separate = FileManager.default.fileExists(atPath: others.path)
        Diagnostics.log("Trascrizione avviata: \(id) (tracce separate: \(separate))")
        let started = Date()
        do {
            let locale = await SpeechEngine.locale()
            try await SpeechEngine.prepare(locale: locale) { [weak self] message in
                Task { @MainActor in self?.statuses[id] = .transcribing(0, message) }
            }
            statuses[id] = .transcribing(0, "Trascrivo…")
            let segments: [Transcript.Segment]
            if separate {
                let theirs = try await SpeechEngine.transcribe(others, speaker: .others, locale: locale) { [weak self] p in
                    Task { @MainActor in self?.statuses[id] = .transcribing(p * 0.5, "Trascrivo la voce degli altri…") }
                }
                let mine = FileManager.default.fileExists(atPath: me.path)
                    ? try await SpeechEngine.transcribe(me, speaker: .me, locale: locale) { [weak self] p in
                        Task { @MainActor in self?.statuses[id] = .transcribing(0.5 + p * 0.5, "Trascrivo la tua voce…") }
                    }
                    : []
                segments = TranscriptMerger.merge(me: mine, others: theirs)
            } else {
                segments = try await SpeechEngine.transcribe(url, speaker: .mixed, locale: locale) { [weak self] p in
                    Task { @MainActor in self?.statuses[id] = .transcribing(p, "Trascrivo…") }
                }
            }
            guard recordings.contains(where: { $0.id == id }) else { return }   // eliminata nel frattempo
            let transcript = Transcript(recording: id, engine: SpeechEngine.engineName, language: locale.identifier, segments: segments)
            try save(transcript, for: url)
            transcripts[id] = transcript
            statuses[id] = .done
            Telemetry.send(.trascrizione, outcome: "ok")
            Diagnostics.log(String(format: "Trascrizione pronta: %@, %d frasi in %.1f s", id, segments.count, Date().timeIntervalSince(started)))
            if let recording = recordings.first(where: { $0.id == id }) { onTranscriptReady?(recording) }
        } catch {
            statuses[id] = .failed(error.localizedDescription)
            Telemetry.send(.trascrizione, outcome: "errore", code: TelemetryFields.errorCode(error))
            Diagnostics.log("Trascrizione non riuscita: \(id): \(error.localizedDescription)")
        }
    }

    private func save(_ transcript: Transcript, for url: URL) throws {
        try FileManager.default.createDirectory(at: transcriptsRoot, withIntermediateDirectories: true)
        try Transcript.encoder.encode(transcript).write(to: transcriptURL(for: url), options: .atomic)
        if saveMarkdown, let recording = recordings.first(where: { $0.url == url }) {
            let markdown = TranscriptFormatter.markdown(transcript, title: title(for: recording), duration: recording.duration)
            try markdown.write(to: markdownURL(for: url), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Azioni

    func title(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return "Chiamata di " + formatter.string(from: recording.date)
    }

    func markdown(for recording: Recording) -> String? {
        transcripts[recording.id].map { TranscriptFormatter.markdown($0, title: title(for: recording), duration: recording.duration) }
    }

    /// Sposta nel Cestino audio e trascrizione Markdown, e cancella tracce e JSON interni.
    func delete(_ recording: Recording) {
        queue.removeAll { $0 == recording.url }
        let fm = FileManager.default
        try? fm.trashItem(at: recording.url, resultingItemURL: nil)
        if fm.fileExists(atPath: markdownURL(for: recording.url).path) {
            try? fm.trashItem(at: markdownURL(for: recording.url), resultingItemURL: nil)
        }
        try? fm.removeItem(at: tracksDirectory(for: recording.url))
        try? fm.removeItem(at: transcriptURL(for: recording.url))
        transcripts[recording.id] = nil
        statuses[recording.id] = nil
        Diagnostics.log("Registrazione eliminata: \(recording.id)")
        reload()
    }
}
