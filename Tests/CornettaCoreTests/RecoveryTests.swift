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

    // MARK: - RecordingFinalizer

    @Test func leftoversAreOnlyFoldersWithARecording() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = root.appendingPathComponent("interrotta")
        let empty = root.appendingPathComponent("vuota")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try writeCAF(interrupted.appendingPathComponent(RecordingFinalizer.mainName), seconds: 0.1, sampleRate: 48_000, channels: 2)
        let found = RecordingFinalizer.leftovers(in: root).map(\.lastPathComponent)
        #expect(found == ["interrotta"])
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
