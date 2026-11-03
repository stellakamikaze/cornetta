import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CornettaCore

/// Video dello schermo: dimensioni, bitrate e file scritti da `ScreenFileWriter` con frame e audio sintetici.
struct ScreenRecordingTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cornetta-schermo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - ScreenEncoding

    @Test func retinaScreenIsScaledToFullHD() {
        let size = ScreenEncoding.outputSize(sourceWidth: 3840, sourceHeight: 2160)
        #expect(size == ScreenEncoding.Size(width: 1920, height: 1080))
    }

    @Test func macBookScreenKeepsProportionsAndEvenSides() {
        // MacBook Air 13": 2560×1664 pixel.
        let size = ScreenEncoding.outputSize(sourceWidth: 2560, sourceHeight: 1664)
        #expect(size.width == 1920)
        #expect(size.height == 1248)
        #expect(size.height % 2 == 0)
    }

    @Test func smallWindowIsNotEnlarged() {
        let size = ScreenEncoding.outputSize(sourceWidth: 801, sourceHeight: 599)
        #expect(size.width <= 802 && size.height <= 600)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    @Test func bitRateStaysBetweenLimits() {
        #expect(ScreenEncoding.videoBitRate(for: .init(width: 1920, height: 1080)) == 3_110_400)
        #expect(ScreenEncoding.videoBitRate(for: .init(width: 320, height: 200)) == ScreenEncoding.minBitRate)
        #expect(ScreenEncoding.videoBitRate(for: .init(width: 1920, height: 1920)) == ScreenEncoding.maxBitRate)
    }

    /// Il motivo della funzione: un'ora a 1080p con audio sta sotto i 2 GB, QuickTime ne fa 4-6.
    @Test func oneHourOfFullHDStaysUnderTwoGigabytes() {
        let bytes = ScreenEncoding.bytesPerHour(for: .init(width: 1920, height: 1080), microphone: true, systemAudio: true)
        #expect(bytes < 2_000_000_000)
    }

    @Test func screenFileNameUsesMP4() throws {
        let components = DateComponents(year: 2026, month: 11, day: 3, hour: 12, minute: 30)
        let date = try #require(Calendar.current.date(from: components))
        let dir = URL(fileURLWithPath: "/tmp/x")
        let url = FileNaming.screenRecordingURL(in: dir, date: date) { $0.lastPathComponent == "Schermo 2026-11-03 12.30.mp4" }
        #expect(url.lastPathComponent == "Schermo 2026-11-03 12.30 (2).mp4")
    }

    // MARK: - ScreenFileWriter

    /// Frame 1920×1080 con un riquadro che si sposta, come una finestra che scorre.
    func videoSample(index: Int, size: ScreenEncoding.Size, fps: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let offset = (index * 12) % (size.width - 200)
        for y in 0..<size.height {
            let row = base + y * rowBytes
            for x in 0..<size.width {
                let inside = x >= offset && x < offset + 200 && y >= 300 && y < 500
                let value: UInt8 = inside ? 30 : 235
                row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = inside ? 200 : value; row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try #require(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    /// Un decimo di secondo di sinusoide in PCM float.
    func audioSample(index: Int, channels: Int) throws -> CMSampleBuffer {
        let rate = Double(ScreenEncoding.audioSampleRate)
        let frames = Int(rate / 10)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try #require(pcm.floatChannelData)
        for channel in 0..<channels {
            for i in 0..<frames { data[channel][i] = Float(sin(Double(index * frames + i) * 0.06)) * 0.2 }
        }
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(index * frames), timescale: CMTimeScale(rate)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: description!, sampleCount: frames, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let buffer = try #require(sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: pcm.audioBufferList)
        return buffer
    }

    /// Scrive `seconds` di video a 30 fps con le due tracce audio, al ritmo vero come ScreenCaptureKit:
    /// il writer è in tempo reale e scarta ciò che arriva troppo in fretta.
    func feed(_ writer: ScreenFileWriter, seconds: Int, size: ScreenEncoding.Size) throws {
        let fps = ScreenEncoding.framesPerSecond
        var audioIndex = 0
        let start = Date()
        for frame in 0..<(seconds * fps) {
            // Audio a blocchi di 0,1 s, fino al tempo del frame.
            while Double(audioIndex) / 10 <= Double(frame) / Double(fps) {
                writer.append(systemAudio: try audioSample(index: audioIndex, channels: 2))
                writer.append(microphone: try audioSample(index: audioIndex, channels: 1))
                audioIndex += 1
            }
            writer.append(video: try videoSample(index: frame, size: size, fps: fps))
            #expect(writer.failure == nil)
            let due = start.addingTimeInterval(Double(frame + 1) / Double(fps))
            Thread.sleep(until: due)
        }
    }

    func finish(_ writer: ScreenFileWriter) async throws -> ScreenFileWriter.Saved {
        try await withCheckedThrowingContinuation { continuation in
            writer.finish { continuation.resume(with: $0) }
        }
    }

    @Test func writesHEVCVideoWithTwoAudioTracks() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = ScreenEncoding.Size(width: 1920, height: 1080)
        let writer = try ScreenFileWriter(url: dir.appendingPathComponent("prova.mp4"), size: size,
                                          systemAudio: true, microphone: true)
        try feed(writer, seconds: 3, size: size)
        let saved = try await finish(writer)
        #expect(saved.bytes > 0)

        let asset = AVURLAsset(url: saved.url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.3)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 2)
        let track = try #require(videoTracks.first)
        let formats = try await track.load(.formatDescriptions)
        let codec = try #require(formats.first).mediaSubType
        #expect(codec == .hevc)
        let natural = try await track.load(.naturalSize)
        #expect(natural == CGSize(width: 1920, height: 1080))
    }

    @Test func audioBeforeTheFirstFrameIsDropped() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = ScreenEncoding.Size(width: 640, height: 360)
        let writer = try ScreenFileWriter(url: dir.appendingPathComponent("prova.mp4"), size: size,
                                          systemAudio: true, microphone: false)
        // Prima del primo frame non c'è sessione: l'audio non deve far fallire il writer.
        writer.append(systemAudio: try audioSample(index: 0, channels: 2))
        try feed(writer, seconds: 1, size: size)
        let saved = try await finish(writer)
        #expect(saved.seconds > 0.9)
        #expect(writer.failure == nil)
    }

    @Test func emptyRecordingIsRemoved() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vuoto.mp4")
        let writer = try ScreenFileWriter(url: url, size: .init(width: 640, height: 360), systemAudio: false, microphone: false)
        await #expect(throws: ScreenFileWriter.WriterError.self) { try await finish(writer) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Crash a metà: una copia del file presa mentre il writer scrive, senza chiusura, si apre e ha i frammenti scritti.
    @Test func unfinishedFileIsReadableUpToTheLastFragment() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = ScreenEncoding.Size(width: 640, height: 360)
        let url = dir.appendingPathComponent("interrotto.mp4")
        let writer = try ScreenFileWriter(url: url, size: size, systemAudio: true, microphone: false,
                                          fragmentInterval: 1)
        try feed(writer, seconds: 4, size: size)
        // Il writer scrive i frammenti in differita: si aspetta che il file cresca prima di copiarlo.
        try await Task.sleep(for: .seconds(1))
        let copy = dir.appendingPathComponent("copia.mp4")
        try FileManager.default.copyItem(at: url, to: copy)
        _ = try? await finish(writer)

        let asset = AVURLAsset(url: copy)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        #expect(duration >= 2)
    }
}
