import AVFoundation
import Foundation
import Testing
@testable import CornettaCore

/// Nomi dei file, recupero dopo un crash e installazione in Applicazioni: tutto su cartelle temporanee.
struct RecoveryTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cornetta-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Un CAF come quelli di `TrackWriter`: `seconds` di sinusoide.
    func writeCAF(_ url: URL, seconds: Double, sampleRate: Double, channels: Int) throws {
        let file = try AVAudioFile(forWriting: url, settings: TrackWriter.pcmSettings(sampleRate: sampleRate, channels: channels),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<channels {
            for i in 0..<Int(frames) { data[channel][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        }
        try file.write(from: buffer)
    }

    // MARK: - FileNaming

    @Test func uniqueNameAddsACounterWhenTaken() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["Chiamata.m4a", "Chiamata (2).m4a"]
        let url = FileNaming.uniqueURL(in: dir, baseName: "Chiamata") { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Chiamata (3).m4a")
    }

    @Test func recordingNameUsesDateAndCounter() throws {
        let components = DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 12)
        let date = try #require(Calendar.current.date(from: components))
        let dir = URL(fileURLWithPath: "/tmp/x")
        let first = FileNaming.recordingURL(in: dir, date: date) { _ in false }
        #expect(first.lastPathComponent == "Chiamata 2026-10-15 09.12.m4a")
        let second = FileNaming.recordingURL(in: dir, date: date) { $0 == first }
        #expect(second.lastPathComponent == "Chiamata 2026-10-15 09.12 (2).m4a")
        #expect(FileNaming.date(fromFileName: second.lastPathComponent) == date)
    }

    /// Una registrazione dello stesso minuto in attesa di recupero ha solo la cartella di lavoro, nessun .m4a:
    /// il nome nuovo la salta, altrimenti la registrazione nuova scriverebbe nei suoi CAF.
    @Test func newRecordingSkipsNamesTakenByAWorkingFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let components = DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 12)
        let date = try #require(Calendar.current.date(from: components))
        let recordings = root.appendingPathComponent("Registrazioni"), working = root.appendingPathComponent("In corso")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working.appendingPathComponent("Chiamata 2026-10-15 09.12"),
                                                withIntermediateDirectories: true)

        let url = FileNaming.newRecordingURL(in: recordings, workingRoot: working, date: date)
        #expect(url.lastPathComponent == "Chiamata 2026-10-15 09.12 (2).m4a")
        #expect(FileNaming.workingDirectory(for: url, in: working).lastPathComponent == "Chiamata 2026-10-15 09.12 (2)")

        // Anche un .m4a.parziale (conversione in corso) tiene occupato il nome.
        try Data().write(to: url.appendingPathExtension("parziale"))
        let next = FileNaming.newRecordingURL(in: recordings, workingRoot: working, date: date)
        #expect(next.lastPathComponent == "Chiamata 2026-10-15 09.12 (3).m4a")
    }

    // MARK: - RecordingFinalizer

    @Test func leftoversAreOnlyFoldersWithARecording() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = root.appendingPathComponent("interrotta")
        let empty = root.appendingPathComponent("vuota")
        // Uscita dopo la conversione della registrazione: il CAF principale non c'è più, le tracce sì.
        let converted = root.appendingPathComponent("convertita")
        for folder in [interrupted, empty, converted] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try writeCAF(interrupted.appendingPathComponent(RecordingFinalizer.mainName), seconds: 0.1, sampleRate: 48_000, channels: 2)
        try writeCAF(converted.appendingPathComponent(RecordingFinalizer.othersName), seconds: 0.1, sampleRate: 16_000, channels: 1)
        let found = RecordingFinalizer.leftovers(in: root).map(\.lastPathComponent)
        #expect(found == ["interrotta"])
    }

    /// Una copia dal disco di installazione accanto a quella in Applicazioni: il recupero salta la cartella
    /// della registrazione viva dell'altra (lock tenuto) e due recuperi non prendono la stessa cartella.
    @Test func claimLeftoversSkipsLockedFolders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("viva"), interrupted = root.appendingPathComponent("interrotta")
        for folder in [live, interrupted] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeCAF(folder.appendingPathComponent(RecordingFinalizer.mainName), seconds: 0.1, sampleRate: 48_000, channels: 2)
        }
        let recording = try #require(WorkingFolderLock(folder: live))

        let first = RecordingFinalizer.claimLeftovers(in: root)
        #expect(first.map(\.folder.lastPathComponent) == ["interrotta"])
        // Un secondo recupero in parallelo non trova niente.
        #expect(RecordingFinalizer.claimLeftovers(in: root).isEmpty)
        #expect(WorkingFolderLock(folder: live) == nil)

        // Registrazione chiusa e recupero finito: la cartella torna recuperabile.
        recording.release()
        first.forEach { $0.lock.release() }
        #expect(RecordingFinalizer.claimLeftovers(in: root).map(\.folder.lastPathComponent).sorted() == ["interrotta", "viva"])
        // Il file del lock non fa di una cartella vuota una registrazione da recuperare.
        let empty = root.appendingPathComponent("vuota")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = WorkingFolderLock(folder: empty)
        #expect(!RecordingFinalizer.leftovers(in: root).contains { $0.lastPathComponent == "vuota" })
        #expect(WorkingFolderLock(folder: root.appendingPathComponent("non-esiste")) == nil)
    }

    @Test func finalizeConvertsRecordingAndTracksAndCleansUp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("in-corso")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try writeCAF(working.appendingPathComponent(RecordingFinalizer.mainName), seconds: 1, sampleRate: 48_000, channels: 2)
        try writeCAF(working.appendingPathComponent(RecordingFinalizer.meName), seconds: 1, sampleRate: 16_000, channels: 1)
        let output = root.appendingPathComponent("Chiamata.m4a")
        let tracks = root.appendingPathComponent("Tracce")

        let result = try RecordingFinalizer.finalize(workingDirectory: working, output: output, tracksDirectory: tracks)

        #expect(abs(result.seconds - 1) < 0.01)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathExtension("parziale").path))
        #expect(FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.meTrack).path))
        // La traccia degli altri non c'era: niente file vuoto al suo posto.
        #expect(!FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.othersTrack).path))
        #expect(!FileManager.default.fileExists(atPath: working.path))
        let converted = try AVAudioFile(forReading: output)
        #expect(converted.fileFormat.channelCount == 2)
    }

    /// Una traccia che non si converte non sparisce con la cartella di lavoro: il CAF resta fra le tracce.
    @Test func failedTrackConversionKeepsItsCAF() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("in-corso")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try writeCAF(working.appendingPathComponent(RecordingFinalizer.mainName), seconds: 1, sampleRate: 48_000, channels: 2)
        try Data("non è audio".utf8).write(to: working.appendingPathComponent(RecordingFinalizer.othersName))
        let tracks = root.appendingPathComponent("Tracce")

        _ = try RecordingFinalizer.finalize(workingDirectory: working, output: root.appendingPathComponent("Chiamata.m4a"),
                                            tracksDirectory: tracks)

        #expect(FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.othersName).path))
        #expect(!FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.othersTrack).path))
        #expect(!FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.othersTrack + ".parziale").path))
        #expect(!FileManager.default.fileExists(atPath: working.path))
    }

    /// Uscita a metà conversione: le tracce sono pronte, la registrazione no. Il recupero riprende
    /// con lo stesso nome e la stessa cartella delle tracce, senza creare « (2)».
    @Test func interruptedFinalizeResumesWithTheSameName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("in-corso")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let main = working.appendingPathComponent(RecordingFinalizer.mainName)
        try Data("non ancora leggibile".utf8).write(to: main)
        try writeCAF(working.appendingPathComponent(RecordingFinalizer.meName), seconds: 1, sampleRate: 16_000, channels: 1)
        let tracks = root.appendingPathComponent("Tracce")
        let first = FileNaming.uniqueURL(in: root, baseName: "Chiamata")

        // La registrazione si converte per ultima: se fallisce, le tracce ci sono già e il .m4a no.
        #expect(throws: (any Error).self) {
            try RecordingFinalizer.finalize(workingDirectory: working, output: first, tracksDirectory: tracks)
        }
        #expect(FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.meTrack).path))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(RecordingFinalizer.leftovers(in: root).map(\.lastPathComponent) == ["in-corso"])

        try FileManager.default.removeItem(at: main)
        try writeCAF(main, seconds: 1, sampleRate: 48_000, channels: 2)
        let output = FileNaming.uniqueURL(in: root, baseName: "Chiamata")
        #expect(output == first)
        _ = try RecordingFinalizer.finalize(workingDirectory: working, output: output, tracksDirectory: tracks)
        let recordings = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".m4a") }
        #expect(recordings == ["Chiamata.m4a"])
        #expect(FileManager.default.fileExists(atPath: tracks.appendingPathComponent(RecordingFinalizer.meTrack).path))
    }

    /// Il recupero dopo un crash conta su questo: un CAF mai chiuso (header non riscritto) resta leggibile.
    @Test func unclosedCAFIsRecoverable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("interrotta")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: working.appendingPathComponent(RecordingFinalizer.mainName),
                                   settings: TrackWriter.pcmSettings(sampleRate: 48_000, channels: 2),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for i in 0..<4_800 { data[channel][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        }
        for _ in 0..<20 { try file.write(from: buffer) }
        // Il file non si chiude mai: il deinit non riscrive l'header, come in un processo ucciso.
        _ = Unmanaged.passRetained(file)
        // Prova che lo stato è quello di un crash: il chunk dei dati ha ancora dimensione -1 (sconosciuta).
        let bytes = try [UInt8](Data(contentsOf: working.appendingPathComponent(RecordingFinalizer.mainName)))
        let chunk = try #require((0..<bytes.count - 12).first { bytes[$0..<$0 + 4].elementsEqual("data".utf8) })
        #expect(bytes[chunk + 4..<chunk + 12].allSatisfy { $0 == 0xFF })

        let result = try RecordingFinalizer.finalize(workingDirectory: working, output: root.appendingPathComponent("Chiamata.m4a"),
                                                     tracksDirectory: nil)
        #expect(result.seconds >= 1.9)
    }

    @Test func finalizeWithoutRecordingKeepsTheWorkingFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("in-corso")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try RecordingFinalizer.finalize(workingDirectory: working, output: root.appendingPathComponent("x.m4a"), tracksDirectory: nil)
        }
        #expect(FileManager.default.fileExists(atPath: working.path))
    }

    // MARK: - VoiceActivity

    @Test func levelsReadInBlocksMatchLevelsFromSamples() {
        let samples = (0..<10_000).map { Float(sin(Double($0) * 0.01)) * Float($0 % 7) * 0.01 }
        let window = VoiceActivity.windowSize(sampleRate: 16_000)
        let whole = VoiceActivity.levels(count: samples.count, window: window) { samples[$0] }
        // Come SpeechEngine: blocchi da 50 finestre, l'ultimo più corto.
        var blocks: [Float] = []
        var start = 0
        while start < samples.count {
            let count = min(window * 50, samples.count - start)
            let offset = start
            blocks += VoiceActivity.levels(count: count, window: window) { samples[offset + $0] }
            start += count
        }
        #expect(whole == blocks)
        let fromLevels = VoiceActivity(levels: whole)
        let fromSamples = VoiceActivity(samples: samples, sampleRate: 16_000)
        #expect(fromLevels.levels == fromSamples.levels)
        #expect(fromLevels.threshold == fromSamples.threshold)
    }

    // MARK: - AppInstaller

    @Test func installReplacesTheOldCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("disco/Cornetta.app")
        let destination = root.appendingPathComponent("Applications/Cornetta.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("nuova".utf8).write(to: source.appendingPathComponent("versione"))
        try Data("vecchia".utf8).write(to: destination.appendingPathComponent("versione"))
        try Data("x".utf8).write(to: destination.appendingPathComponent("solo-nella-vecchia"))

        try AppInstaller.install(source, at: destination)

        #expect(try String(contentsOf: destination.appendingPathComponent("versione"), encoding: .utf8) == "nuova")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("solo-nella-vecchia").path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedCopyLeavesTheOldCopyInPlace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications/Cornetta.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("vecchia".utf8).write(to: destination.appendingPathComponent("versione"))

        #expect(throws: (any Error).self) {
            try AppInstaller.install(root.appendingPathComponent("non-esiste.app"), at: destination)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("versione"), encoding: .utf8) == "vecchia")
    }
}
