import AVFoundation
import Foundation

/// Durante la registrazione l'audio va in file CAF PCM, che restano leggibili anche dopo un crash.
/// Allo stop (o al riavvio, se l'app si è chiusa male) diventano AAC .m4a e la cartella di lavoro sparisce.
public enum RecordingFinalizer {
    public static let mainName = "registrazione.caf"
    public static let meName = "tu.caf"
    public static let othersName = "altri.caf"
    /// Tracce vocali convertite, nella cartella delle tracce: le legge la trascrizione.
    public static let meTrack = "tu.m4a"
    public static let othersTrack = "altri.m4a"

    public struct Result: Sendable {
        public let recording: URL
        public let seconds: Double
    }

    /// Converte la cartella di lavoro: registrazione in `output`, tracce in `tracksDirectory`.
    /// La registrazione si converte per ultima: se l'app esce prima, al riavvio `output` non esiste
    /// e il recupero riprende con lo stesso nome e la stessa cartella delle tracce, senza doppioni.
    /// Dopo, il CAF principale sparisce subito: senza di lui `leftovers` non riprende la cartella.
    public static func finalize(workingDirectory: URL, output: URL, tracksDirectory: URL?) throws -> Result {
        if let tracksDirectory {
            try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
            for (source, name) in [(meName, meTrack), (othersName, othersTrack)] {
                let url = workingDirectory.appendingPathComponent(source)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let destination = tracksDirectory.appendingPathComponent(name)
                do {
                    try convert(url, to: destination, sampleRate: 16_000, channels: 1, bitRate: 32_000)
                } catch {
                    // La traccia non sparisce con la cartella di lavoro: il CAF resta accanto alle tracce.
                    Diagnostics.log("Conversione della traccia \(source) non riuscita: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("parziale"))
                    let kept = tracksDirectory.appendingPathComponent(source)
                    try? FileManager.default.removeItem(at: kept)
                    try? FileManager.default.moveItem(at: url, to: kept)
                }
            }
        }
        let main = workingDirectory.appendingPathComponent(mainName)
        let seconds = try convert(main, to: output, sampleRate: 48_000, channels: 2, bitRate: 160_000)
        try? FileManager.default.removeItem(at: main)
        try? FileManager.default.removeItem(at: workingDirectory)
        return Result(recording: output, seconds: seconds)
    }

    /// Cartelle di lavoro rimaste da una sessione interrotta (crash, Mac spento, uscita forzata).
    /// Include anche quelle in uso (registrazione viva, recupero in corso): per recuperarle serve `claimLeftovers`.
    public static func leftovers(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(mainName).path) }
    }

    /// Le cartelle da recuperare, ognuna col suo lock: salta quelle che un'altra Cornetta sta registrando o
    /// recuperando (per esempio una copia aperta dal disco di installazione accanto a quella in Applicazioni).
    /// Il lock va tenuto fino alla fine del recupero.
    public static func claimLeftovers(in root: URL) -> [(folder: URL, lock: WorkingFolderLock)] {
        leftovers(in: root).compactMap { folder in
            // Ricontrolla il CAF col lock preso: chi lo teneva può aver appena finito e cancellato la cartella.
            guard let lock = WorkingFolderLock(folder: folder),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(mainName).path) else {
                Diagnostics.log("Salto \(folder.lastPathComponent): è in uso da un'altra Cornetta o è già stata salvata")
                return nil
            }
            return (folder, lock)
        }
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
        } catch {
            // Disco pieno a metà conversione: il file a metà non deve occupare altro spazio. Il CAF resta.
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        // Il file definitivo compare solo a conversione finita: mai un .m4a a metà nella cartella Musica.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return Double(input.length) / format.sampleRate
    }
}

/// Lock fra processi su una cartella di lavoro (flock su un file al suo interno). Lo tiene la registrazione
/// viva e il recupero in corso: un'altra Cornetta non converte e non cancella i CAF che qualcuno sta scrivendo.
/// macOS lo toglie da solo quando il processo finisce, anche per un crash: la cartella torna recuperabile.
public final class WorkingFolderLock: @unchecked Sendable {
    public static let fileName = "in-uso.lock"
    private let lock = NSLock()
    private var descriptor: Int32

    /// Nil se la cartella non esiste o se un altro lo tiene già (anche nello stesso processo).
    public init?(folder: URL) {
        let fd = open(folder.appendingPathComponent(Self.fileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
