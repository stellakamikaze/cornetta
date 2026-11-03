import AVFoundation
import Foundation

/// Scrive un video dello schermo già compresso: HEVC e AAC in un .mp4 a frammenti. Se l'app si chiude di
/// colpo, il file resta leggibile fino all'ultimo frammento (`fragmentInterval`). Va usato da una sola coda.
public final class ScreenFileWriter {
    public struct Saved: Sendable {
        public let url: URL
        public let seconds: Double
        public let bytes: Int64
    }

    public enum WriterError: LocalizedError {
        case noFrames
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noFrames: return "Non è arrivata nessuna immagine dello schermo"
            case .failed(let text): return text
            }
        }
    }

    public let url: URL
    public let size: ScreenEncoding.Size
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?
    public private(set) var droppedFrames = 0

    public init(url: URL, size: ScreenEncoding.Size, systemAudio: Bool, microphone: Bool,
                fragmentInterval: Double = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        video = AVAssetWriterInput(mediaType: .video, outputSettings: ScreenEncoding.videoSettings(for: size))
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: ScreenEncoding.audioSettings(channels: channels, bitRate: bitRate))
            input.expectsMediaDataInRealTime = true
            return input
        }
        if systemAudio {
            let input = audioInput(channels: 2, bitRate: ScreenEncoding.systemAudioBitRate)
            writer.add(input)
            self.systemAudio = input
        } else {
            self.systemAudio = nil
        }
        if microphone {
            let input = audioInput(channels: 1, bitRate: ScreenEncoding.microphoneBitRate)
            writer.add(input)
            self.microphone = input
        } else {
            self.microphone = nil
        }
        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "Non riesco a creare il video")
        }
    }

    /// Secondi scritti, dal primo frame all'ultimo.
    public var seconds: Double {
        guard let startTime, let lastVideoTime else { return 0 }
        return max(0, (lastVideoTime - startTime).seconds)
    }

    public var failure: String? {
        writer.status == .failed ? (writer.error?.localizedDescription ?? "Scrittura del video non riuscita") : nil
    }

    /// Il video parte dal primo frame: l'audio che arriva prima si scarta.
    public func append(video sample: CMSampleBuffer) {
        guard writer.status == .writing else { return }
        let time = sample.presentationTimeStamp
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        if let lastVideoTime, time <= lastVideoTime { return }
        guard video.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        if video.append(sample) { lastVideoTime = time }
    }

    public func append(systemAudio sample: CMSampleBuffer) { appendAudio(sample, to: systemAudio) }
    public func append(microphone sample: CMSampleBuffer) { appendAudio(sample, to: microphone) }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let startTime, writer.status == .writing, input.isReadyForMoreMediaData,
              sample.presentationTimeStamp >= startTime else { return }
        input.append(sample)
    }

    /// Chiude il file. Senza frame il file vuoto si cancella.
    public func finish(completion: @escaping @Sendable (Result<Saved, Error>) -> Void) {
        guard startTime != nil, writer.status == .writing else {
            let error: Error = failure.map { WriterError.failed($0) } ?? WriterError.noFrames
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            completion(.failure(error))
            return
        }
        if let lastVideoTime { writer.endSession(atSourceTime: lastVideoTime) }
        video.markAsFinished()
        systemAudio?.markAsFinished()
        microphone?.markAsFinished()
        let url = url, seconds = seconds
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                completion(.success(Saved(url: url, seconds: seconds, bytes: bytes)))
            } else {
                completion(.failure(WriterError.failed(writer.error?.localizedDescription ?? "Chiusura del video non riuscita")))
            }
        }
    }
}
