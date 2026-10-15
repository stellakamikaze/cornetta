import CornettaCore
import Foundation

/// `Cornetta --transcribe <file.m4a> [--tracks <cartella con tu.m4a e altri.m4a>]`:
/// trascrive senza interfaccia e stampa il Markdown. Serve per le prove.
enum HeadlessTranscription {
    static func run(file: String, tracks: String?) {
        guard #available(macOS 26.0, *) else {
            print("La trascrizione richiede macOS 26.")
            exit(2)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let locale = await SpeechEngine.locale()
                try await SpeechEngine.prepare(locale: locale) { print($0) }
                let url = URL(fileURLWithPath: file)
                let segments: [Transcript.Segment]
                if let tracks {
                    let dir = URL(fileURLWithPath: tracks, isDirectory: true)
                    let theirs = try await SpeechEngine.transcribe(dir.appendingPathComponent(RecordingFinalizer.othersTrack), speaker: .others, locale: locale) { _ in }
                    let mine = try await SpeechEngine.transcribe(dir.appendingPathComponent(RecordingFinalizer.meTrack), speaker: .me, locale: locale) { _ in }
                    print("frasi Tu: \(mine.count), frasi Altri: \(theirs.count)")
                    segments = TranscriptMerger.merge(me: mine, others: theirs)
                } else {
                    segments = try await SpeechEngine.transcribe(url, speaker: .mixed, locale: locale) { _ in }
                }
                let transcript = Transcript(recording: url.lastPathComponent, engine: SpeechEngine.engineName,
                                            language: locale.identifier, segments: segments)
                print(TranscriptFormatter.markdown(transcript, title: url.deletingPathExtension().lastPathComponent, duration: nil))
            } catch {
                print("Errore: \(error.localizedDescription)")
                code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(code)
    }
}
