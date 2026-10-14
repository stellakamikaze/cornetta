import AVFoundation
import Foundation

/// Durante la registrazione l'audio va in file CAF PCM, che restano leggibili anche dopo un crash.
/// Allo stop (o al riavvio, se l'app si è chiusa male) diventano AAC .m4a e la cartella di lavoro sparisce.
public enum RecordingFinalizer {
    public static let mainName = "registrazione.caf"
    public static let meName = "tu.caf"
    public static let othersName = "altri.caf"

    public struct Result: Sendable {
        public let recording: URL
        public let seconds: Double
    }

    /// Converte la cartella di lavoro: registrazione in `output`, tracce in `tracksDirectory`.
    public static func finalize(workingDirectory: URL, output: URL, tracksDirectory: URL?) throws -> Result {
        let main = workingDirectory.appendingPathComponent(mainName)
        let seconds = try convert(main, to: output, sampleRate: 48_000, channels: 2, bitRate: 160_000)
        if let tracksDirectory {
            try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
            for (source, name) in [(meName, "tu.m4a"), (othersName, "altri.m4a")] {
                let url = workingDirectory.appendingPathComponent(source)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try? convert(url, to: tracksDirectory.appendingPathComponent(name), sampleRate: 16_000, channels: 1, bitRate: 32_000)
                }
            }
        }
        try? FileManager.default.removeItem(at: workingDirectory)
        return Result(recording: output, seconds: seconds)
    }

    /// Cartelle di lavoro rimaste da una sessione interrotta (crash, Mac spento, uscita forzata).
    public static func leftovers(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(mainName).path) }
    }

    /// Ricodifica in AAC a blocchi, senza caricare in memoria tutta la registrazione.
    @discardableResult
    static func convert(_ source: URL, to destination: URL, sampleRate: Double, channels: Int, bitRate: Int) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("parziale")
        try? FileManager.default.removeItem(at: partial)
        do {
            let output = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                throw CoreAudioError("Conversione della registrazione", kAudioHardwareUnspecifiedError)
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        // Il file definitivo compare solo a conversione finita: mai un .m4a a metà nella cartella Musica.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return Double(input.length) / format.sampleRate
    }
}
