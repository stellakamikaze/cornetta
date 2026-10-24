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
    @Published private(set) var transcripts: [String: Transcript] = [:] {
        didSet { searchText = [:]; turnsCache = [:] }
    }
    @Published private(set) var statuses: [String: Status] = [:]
    @AppStorage("autoTranscribe") var autoTranscribe = true
    @AppStorage("saveMarkdown") var saveMarkdown = true

    /// Chiamato quando una trascrizione è pronta (per l'avviso).
    var onTranscriptReady: ((Recording) -> Void)?

    private var queue: [URL] = []
    /// Registrazione in trascrizione: non è più in coda, ma non deve rientrarci.
    private var current: URL?
    /// Durata per file, con la data di modifica: si rilegge solo un file nuovo o cambiato.
    private var durations: [URL: (modified: Date, seconds: Double)] = [:]
    private var measuring: Set<URL> = []
    /// Titolo e testo in minuscolo per la ricerca, e battute: si ricalcolano solo quando cambia una trascrizione.
    private var searchText: [String: String] = [:]
    private var turnsCache: [String: [Transcript.Segment]] = [:]
    private var orphansCheckedAt = Date.distantPast
    /// Avvii in cui una trascrizione fallita riparte da sola; poi resta «Errore» con «Riprova».
    private static let automaticAttempts = 2
    /// Recuperi falliti dopo i quali la cartella di lavoro va accanto alle registrazioni così com'è.
    private static let recoveryAttempts = 3
    /// Giorni senza audio prima che tracce e trascrizione vadano nel Cestino.
    private static let orphanGrace: TimeInterval = 7 * 24 * 3600

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
    var workingRoot: URL { support.appendingPathComponent("In corso", isDirectory: true) }

    func workingDirectory(for recording: URL) -> URL {
        FileNaming.workingDirectory(for: recording, in: workingRoot)
    }

    /// Registrazioni interrotte da un crash o da uno spegnimento: le converte e le rimette in libreria.
    /// `onRecoveryFailed` riceve la cartella con l'audio grezzo quando il recupero viene abbandonato.
    func recoverInterruptedRecordings(onRecovered: @escaping (String) -> Void,
                                      onRecoveryFailed: @escaping (URL) -> Void) {
        // Il lock salta le cartelle che un'altra Cornetta sta registrando o recuperando, e si tiene fino alla fine.
        let leftovers = RecordingFinalizer.claimLeftovers(in: workingRoot)
        guard !leftovers.isEmpty else { return }
        let folder = recordingsFolder
        for (working, lock) in leftovers {
            let name = working.lastPathComponent
            let output = FileNaming.uniqueURL(in: folder, baseName: name)
            let tracks = tracksDirectory(for: output)
            Diagnostics.log("Recupero la registrazione interrotta: \(name)")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try RecordingFinalizer.finalize(workingDirectory: working, output: output, tracksDirectory: tracks) }
                DispatchQueue.main.async {
                    defer { lock.release() }
                    switch result {
                    case .success(let r):
                        Diagnostics.log(String(format: "Recuperata: %@ (%.0f s)", output.lastPathComponent, r.seconds))
                        self.recordingFinished(output)
                        onRecovered(output.lastPathComponent)
                    case .failure(let error):
                        Diagnostics.log("Recupero non riuscito per \(name): \(error.localizedDescription)")
                        if let kept = self.recoveryFailed(working, name: name) { onRecoveryFailed(kept) }
                    }
                }
            }
        }
    }

    /// Conta i recuperi falliti in un file della cartella di lavoro. Al terzo la cartella, con l'audio grezzo
    /// (CAF, si apre con QuickTime), va in ~/Music/Cornetta come «<nome> (da recuperare)» e non si riprova più.
    /// Restituisce la cartella spostata, nil finché si riprova.
    private func recoveryFailed(_ working: URL, name: String) -> URL? {
        let counter = working.appendingPathComponent("tentativi")
        let attempts = ((try? String(contentsOf: counter, encoding: .utf8)).flatMap { Int($0) } ?? 0) + 1
        if attempts >= Self.recoveryAttempts {
            let kept = recordingsFolder.appendingPathComponent("\(name) (da recuperare)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: working, to: kept)
                try? FileManager.default.removeItem(at: kept.appendingPathComponent(WorkingFolderLock.fileName))
                Diagnostics.log("Recupero abbandonato dopo \(attempts) tentativi: audio grezzo in \(kept.lastPathComponent)")
                return kept
            } catch {
                Diagnostics.log("Non riesco a spostare la registrazione interrotta \(name): \(error.localizedDescription)")
            }
        }
        try? String(attempts).write(to: counter, atomically: true, encoding: .utf8)
        return nil
    }

    private var tracksRoot: URL { support.appendingPathComponent("Tracce", isDirectory: true) }
    private var transcriptsRoot: URL { support.appendingPathComponent("Trascrizioni", isDirectory: true) }

    func tracksDirectory(for recording: URL) -> URL {
        tracksRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Traccia vocale convertita oppure, se la conversione è fallita, il CAF tenuto da RecordingFinalizer.
    private func track(_ converted: String, raw: String, of recording: URL) -> URL? {
        let folder = tracksDirectory(for: recording)
        return [converted, raw].map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func transcriptURL(for recording: URL) -> URL {
        transcriptsRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".json")
    }

    /// Trascrizione non riuscita: tentativi e ultimo errore, così non riparte a ogni avvio.
    private struct Failure: Codable {
        var count: Int
        var error: String
    }

    private func failureURL(for recording: URL) -> URL {
        transcriptsRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".failed.json")
    }

    private func failure(for recording: URL) -> Failure? {
        (try? Data(contentsOf: failureURL(for: recording))).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
    }

    func markdownURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("md")
    }

    // MARK: - Caricamento

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let listing = try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])
        var unmeasured: [URL] = []
        recordings = (listing ?? [])
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = FileNaming.date(fromFileName: url.lastPathComponent) ?? values?.creationDate ?? .distantPast
                let modified = values?.contentModificationDate ?? .distantPast
                let duration = durations[url].flatMap { $0.modified == modified ? $0.seconds : nil }
                if duration == nil { unmeasured.append(url) }
                let tracks = track(RecordingFinalizer.othersTrack, raw: RecordingFinalizer.othersName, of: url) != nil
                return Recording(url: url, date: date, duration: duration ?? 0, hasTracks: tracks)
            }
            .sorted { $0.date > $1.date }

        // File cancellati o rinominati dal Finder: il loro stato non resta in memoria.
        let ids = Set(recordings.map(\.id))
        for id in transcripts.keys where !ids.contains(id) { transcripts[id] = nil }
        for id in statuses.keys where !ids.contains(id) { statuses[id] = nil }
        durations = durations.filter { ids.contains($0.key.lastPathComponent) }

        for recording in recordings where transcripts[recording.id] == nil {
            if let data = try? Data(contentsOf: transcriptURL(for: recording.url)),
               let transcript = try? Transcript.decoder.decode(Transcript.self, from: data) {
                transcripts[recording.id] = transcript
                statuses[recording.id] = .done
            } else if statuses[recording.id] == nil {
                statuses[recording.id] = failure(for: recording.url).map { .failed($0.error) } ?? .notTranscribed
            }
        }
        measure(unmeasured)
        if listing != nil { cleanOrphans(present: Set(recordings.map { $0.url.deletingPathExtension().lastPathComponent })) }
    }

    /// Durate dei file nuovi o cambiati, lette fuori dal thread principale: poi l'elenco si aggiorna.
    private func measure(_ urls: [URL]) {
        let urls = urls.filter { !measuring.contains($0) }
        guard !urls.isEmpty else { return }
        measuring.formUnion(urls)
        Task.detached(priority: .userInitiated) {
            let measured = urls.map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                return (url, modified, seconds)
            }
            await MainActor.run {
                for (url, modified, seconds) in measured { self.durations[url] = (modified, seconds) }
                self.measuring.subtract(urls)
                let updated = self.recordings.map { recording in
                    Recording(url: recording.url, date: recording.date,
                              duration: self.durations[recording.url]?.seconds ?? recording.duration, hasTracks: recording.hasTracks)
                }
                if updated != self.recordings { self.recordings = updated }
            }
        }
    }

    /// Una registrazione cancellata o rinominata dal Finder lascia in Application Support le tracce con le voci
    /// e il testo della chiamata. Dopo 7 giorni senza audio vanno nel Cestino: il margine copre un file
    /// che torna al suo posto. Mai con una registrazione o un recupero in corso (cartella di lavoro piena).
    private func cleanOrphans(present: Set<String>) {
        guard Date().timeIntervalSince(orphansCheckedAt) > 3600,
              RecordingFinalizer.leftovers(in: workingRoot).isEmpty else { return }
        orphansCheckedAt = Date()
        let fm = FileManager.default
        var items: [String: [URL]] = [:]
        for url in (try? fm.contentsOfDirectory(at: tracksRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            items[url.lastPathComponent, default: []].append(url)
        }
        for url in (try? fm.contentsOfDirectory(at: transcriptsRoot, includingPropertiesForKeys: nil)) ?? [] {
            let file = url.lastPathComponent
            guard let suffix = [".failed.json", ".json"].first(where: { file.hasSuffix($0) }) else { continue }
            items[String(file.dropLast(suffix.count)), default: []].append(url)
        }
        let working = Set((try? fm.contentsOfDirectory(atPath: workingRoot.path)) ?? [])
        let orphans = items.filter { !present.contains($0.key) && !working.contains($0.key) }

        let ledger = support.appendingPathComponent("Orfane.json")
        var since = ((try? Data(contentsOf: ledger)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:])
            .filter { orphans[$0.key] != nil }
        let now = Date()
        for (name, urls) in orphans {
            guard let first = since[name] else { since[name] = now; continue }
            guard now.timeIntervalSince(first) >= Self.orphanGrace else { continue }
            let trashed = urls.map { (try? fm.trashItem(at: $0, resultingItemURL: nil)) != nil }
            guard trashed.allSatisfy({ $0 }) else { continue }
            since[name] = nil
            Diagnostics.log("Tracce e trascrizione senza registrazione da 7 giorni, nel Cestino: \(name)")
        }
        if since.isEmpty {
            try? fm.removeItem(at: ledger)
        } else if let data = try? JSONEncoder().encode(since) {
            try? data.write(to: ledger, options: .atomic)
        }
    }

    /// Ricerca su titolo e trascrizione; `query` è già in minuscolo.
    func matches(_ recording: Recording, query: String) -> Bool {
        if let text = searchText[recording.id] { return text.contains(query) }
        let text = (title(for: recording) + "\n" + (transcripts[recording.id]?.plainText ?? "")).lowercased()
        searchText[recording.id] = text
        return text.contains(query)
    }

    /// Battute della trascrizione: il dettaglio si ridisegna a ogni passo del lettore, il calcolo resta uno.
    func turns(for recording: Recording) -> [Transcript.Segment] {
        if let turns = turnsCache[recording.id] { return turns }
        let turns = transcripts[recording.id].map { TranscriptFormatter.turns($0.segments) } ?? []
        turnsCache[recording.id] = turns
        return turns
    }

    func status(_ recording: Recording) -> Status { statuses[recording.id] ?? .notTranscribed }

    // MARK: - Trascrizione

    /// Registrazioni con tracce ma senza trascrizione (app chiusa a metà): tornano in coda.
    /// Quelle già fallite due volte no: un errore che si ripete non si rifà a ogni accensione.
    func resumePendingTranscriptions() {
        guard autoTranscribe, SpeechEngine.isAvailable else { return }
        for recording in recordings where recording.hasTracks && transcripts[recording.id] == nil
            && (failure(for: recording.url)?.count ?? 0) < Self.automaticAttempts {
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
        guard url != current, !queue.contains(url) else { return }
        queue.append(url)
        statuses[url.lastPathComponent] = .queued
        processNext()
    }

    private func processNext() {
        guard current == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        current = url
        Task {
            await transcribe(url)
            current = nil
            processNext()
        }
    }

    private func transcribe(_ url: URL) async {
        guard #available(macOS 26.0, *) else { return }
        let id = url.lastPathComponent
        let me = track(RecordingFinalizer.meTrack, raw: RecordingFinalizer.meName, of: url)
        let others = track(RecordingFinalizer.othersTrack, raw: RecordingFinalizer.othersName, of: url)
        Diagnostics.log("Trascrizione avviata: \(id) (tracce separate: \(others != nil))")
        let started = Date()
        do {
            let locale = await SpeechEngine.locale()
            try await SpeechEngine.prepare(locale: locale) { [weak self] message in
                Task { @MainActor in self?.report(id, 0, message) }
            }
            statuses[id] = .transcribing(0, "Trascrivo…")
            let segments: [Transcript.Segment]
            if let others {
                let theirs = try await SpeechEngine.transcribe(others, speaker: .others, locale: locale) { [weak self] p in
                    Task { @MainActor in self?.report(id, p * 0.5, "Trascrivo la voce degli altri…") }
                }
                var mine: [Transcript.Segment] = []
                if let me {
                    mine = try await SpeechEngine.transcribe(me, speaker: .me, locale: locale) { [weak self] p in
                        Task { @MainActor in self?.report(id, 0.5 + p * 0.5, "Trascrivo la tua voce…") }
                    }
                }
                segments = TranscriptMerger.merge(me: mine, others: theirs)
            } else {
                segments = try await SpeechEngine.transcribe(url, speaker: .mixed, locale: locale) { [weak self] p in
                    Task { @MainActor in self?.report(id, p, "Trascrivo…") }
                }
            }
            guard recordings.contains(where: { $0.id == id }) else { return }   // eliminata nel frattempo
            let transcript = Transcript(recording: id, engine: SpeechEngine.engineName, language: locale.identifier, segments: segments)
            try save(transcript, for: url)
            try? FileManager.default.removeItem(at: failureURL(for: url))
            transcripts[id] = transcript
            statuses[id] = .done
            Telemetry.send(.trascrizione, outcome: "ok")
            Diagnostics.log(String(format: "Trascrizione pronta: %@, %d frasi in %.1f s", id, segments.count, Date().timeIntervalSince(started)))
            if let recording = recordings.first(where: { $0.id == id }) { onTranscriptReady?(recording) }
        } catch {
            statuses[id] = .failed(error.localizedDescription)
            if recordings.contains(where: { $0.id == id }) {
                let failed = Failure(count: (failure(for: url)?.count ?? 0) + 1, error: error.localizedDescription)
                try? FileManager.default.createDirectory(at: transcriptsRoot, withIntermediateDirectories: true)
                try? JSONEncoder().encode(failed).write(to: failureURL(for: url), options: .atomic)
            }
            Telemetry.send(.trascrizione, outcome: "errore", code: TelemetryFields.errorCode(error))
            Diagnostics.log("Trascrizione non riuscita: \(id): \(error.localizedDescription)")
        }
    }

    /// Avanzamento: si pubblica quando cambia la percentuale intera o il messaggio, non a ogni risultato del motore.
    private func report(_ id: String, _ progress: Double, _ message: String) {
        if case .transcribing(let shown, let text) = statuses[id], Int(shown * 100) == Int(progress * 100), text == message { return }
        statuses[id] = .transcribing(progress, message)
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

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return formatter
    }()

    func title(for recording: Recording) -> String {
        "Chiamata di " + Self.titleFormatter.string(from: recording.date)
    }

    func markdown(for recording: Recording) -> String? {
        transcripts[recording.id].map { TranscriptFormatter.markdown($0, title: title(for: recording), duration: recording.duration) }
    }

    /// Sposta nel Cestino audio e trascrizione Markdown, e cancella tracce e JSON interni.
    func delete(_ recording: Recording) {
        // Il lettore tiene il file aperto: senza stop la chiamata eliminata continua a suonare.
        if AudioPlayer.shared.playingID == recording.id { AudioPlayer.shared.stop() }
        queue.removeAll { $0 == recording.url }
        let fm = FileManager.default
        try? fm.trashItem(at: recording.url, resultingItemURL: nil)
        if fm.fileExists(atPath: markdownURL(for: recording.url).path) {
            try? fm.trashItem(at: markdownURL(for: recording.url), resultingItemURL: nil)
        }
        try? fm.removeItem(at: tracksDirectory(for: recording.url))
        try? fm.removeItem(at: transcriptURL(for: recording.url))
        try? fm.removeItem(at: failureURL(for: recording.url))
        transcripts[recording.id] = nil
        statuses[recording.id] = nil
        Diagnostics.log("Registrazione eliminata: \(recording.id)")
        reload()
    }
}
