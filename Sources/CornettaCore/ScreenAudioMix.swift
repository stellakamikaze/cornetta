import AVFoundation
import Foundation

/// Allo stop unisce audio del Mac e microfono in una traccia sola. Durante la registrazione stanno in
/// due tracce (il file resta leggibile dopo un crash), ma WhatsApp, Slack e i browser leggono solo la prima
/// traccia audio: la voce sparirebbe nei video condivisi. Il video passa com'è, senza ricodifica.
public enum ScreenAudioMix {
    public static let mixedBitRate = 160_000

    /// Riscrive `url` con una sola traccia audio. Con meno di due tracce audio non fa niente.
    /// Se qualcosa va storto il file originale resta intatto.
    public static func mergeAudioTracks(in url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).unione.mp4")
        try? FileManager.default.removeItem(at: temporary)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: ScreenEncoding.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let hint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        let audioInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: ScreenEncoding.audioSettings(channels: 2, bitRate: mixedBitRate))
        writer.add(videoInput)
        writer.add(audioInput)

        guard reader.startReading() else { throw failure(reader.error, "lettura") }
        guard writer.startWriting() else { throw failure(writer.error, "scrittura") }
        writer.startSession(atSourceTime: .zero)

        async let videoDone: Void = pump(videoOutput, into: videoInput, label: "video")
        async let audioDone: Void = pump(audioOutput, into: audioInput, label: "audio")
        _ = await (videoDone, audioDone)

        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporary)
            throw failure(reader.error, "lettura")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: temporary)
            throw failure(writer.error, "scrittura")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Toglie i file d'unione rimasti da un'uscita a metà: il video originale è intatto accanto.
    public static func removeLeftovers(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".unione.mp4") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Copia i campioni finché la sorgente finisce, al ritmo che il writer accetta.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "cornetta.unione.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private static func failure(_ error: Error?, _ step: String) -> Error {
        ScreenFileWriter.WriterError.failed("Unione dell'audio non riuscita (\(step)): \(error?.localizedDescription ?? "errore sconosciuto")")
    }
}
