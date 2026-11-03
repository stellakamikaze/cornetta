import AVFoundation
import Foundation
import ScreenCaptureKit

/// Registra lo schermo, una finestra o un'app scelti con il selettore di macOS (`SCContentSharingPicker`)
/// in un video già compresso. Con il selettore macOS non chiede il permesso Registrazione schermo: la
/// persona sceglie cosa mostrare, e il sistema lo segnala con l'indicatore viola nella barra dei menu.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        /// La cattura si è fermata da sola: finestra chiusa, stop dalla barra di sistema, errore.
        case stopped(String?)
    }

    public let outputURL: URL
    public var onEvent: ((Event) -> Void)?
    public private(set) var microphoneIncluded = false
    private let filter: SCContentFilter
    private let wantsSystemAudio: Bool
    private let wantsMicrophone: Bool
    private let queue = DispatchQueue(label: "cornetta.schermo", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: ScreenFileWriter?
    private var stopping = false

    public init(filter: SCContentFilter, outputURL: URL, systemAudio: Bool, microphone: Bool) {
        self.filter = filter
        self.outputURL = outputURL
        self.wantsSystemAudio = systemAudio
        self.wantsMicrophone = microphone
    }

    /// Il microfono nello stream c'è da macOS 15: su macOS 14 il video ha solo l'audio del Mac.
    public static var supportsMicrophone: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Dimensione in pixel di ciò che si registra: area del filtro per la densità dello schermo.
    static func sourceSize(of filter: SCContentFilter) -> (width: Int, height: Int) {
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        return (Int(rect.width * scale), Int(rect.height * scale))
    }

    public func start() async throws {
        let source = Self.sourceSize(of: filter)
        let size = ScreenEncoding.outputSize(sourceWidth: source.width, sourceHeight: source.height)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreenEncoding.framesPerSecond))
        config.queueDepth = 6
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = wantsSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = ScreenEncoding.audioSampleRate
        config.channelCount = 2
        var mic = false
        if wantsMicrophone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
            mic = true
        }
        microphoneIncluded = mic

        let writer = try ScreenFileWriter(url: outputURL, size: size, systemAudio: wantsSystemAudio, microphone: mic)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if mic, #available(macOS 15.0, *) { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        queue.sync { self.writer = writer }
        self.stream = stream
        Diagnostics.log("Schermo: \(source.width)×\(source.height) → \(size.width)×\(size.height), \(ScreenEncoding.videoBitRate(for: size) / 1000) kbit/s, audio Mac \(wantsSystemAudio), microfono \(mic)")
        do {
            try await stream.startCapture()
        } catch {
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// La persona ha cambiato cosa mostrare dal menu di sistema: il video continua sul contenuto nuovo.
    public func update(filter: SCContentFilter) {
        stream?.updateContentFilter(filter) { error in
            if let error { Diagnostics.log("Schermo: cambio di contenuto non riuscito: \(error.localizedDescription)") }
        }
    }

    /// Secondi già scritti nel video.
    public var seconds: Double { queue.sync { writer?.seconds ?? 0 } }

    /// Ferma la cattura e chiude il file. `completion` arriva su una coda qualsiasi.
    public func stop(completion: @escaping @Sendable (Result<ScreenFileWriter.Saved, Error>) -> Void) {
        let stream = self.stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
            self.queue.async {
                guard let writer = self.writer, !self.stopping else { return }
                self.stopping = true
                self.writer = nil
                if writer.droppedFrames > 0 { Diagnostics.log("Schermo: \(writer.droppedFrames) frame scartati") }
                writer.finish(completion: completion)
            }
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, sample.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sample) else { return }
            writer.append(video: sample)
        case .audio:
            writer.append(systemAudio: sample)
        default:
            if #available(macOS 15.0, *), type == .microphone { writer.append(microphone: sample) }
        }
    }

    /// ScreenCaptureKit manda frame anche quando lo schermo non cambia (`idle`): nel video vanno solo quelli completi.
    static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diagnostics.log("Schermo: cattura fermata dal sistema: \(error.localizedDescription)")
        let code = (error as NSError).code
        // La persona ha fermato dalla barra di sistema: non è un errore da mostrare.
        let text: String? = code == SCStreamError.Code.userStopped.rawValue ? nil : error.localizedDescription
        onEvent?(.stopped(text))
    }
}
