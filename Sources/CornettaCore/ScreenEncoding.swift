import AVFoundation
import Foundation

/// Dimensione e compressione dei video dello schermo. Un video di QuickTime pesa 4-6 GB l'ora; con questi
/// valori un'ora di lavoro a schermo sta fra 0,5 e 1,8 GB e il testo resta leggibile.
public enum ScreenEncoding {
    /// Lato lungo massimo: uno schermo Retina 5K esce a 1920×1080, la scrittura resta nitida.
    public static let maxLongSide = 1920
    public static let framesPerSecond = 30
    /// Bit per pixel per frame: lo schermo cambia poco da un frame all'altro, HEVC ne approfitta.
    static let bitsPerPixel = 0.05
    public static let minBitRate = 1_000_000
    public static let maxBitRate = 4_000_000
    public static let systemAudioBitRate = 128_000
    public static let microphoneBitRate = 96_000
    public static let audioSampleRate = 48_000

    public struct Size: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Dimensione del video per una sorgente in pixel: proporzioni tenute, lato lungo al massimo `maxLongSide`,
    /// lati pari (HEVC li vuole pari). Una finestra piccola resta com'è.
    public static func outputSize(sourceWidth: Int, sourceHeight: Int) -> Size {
        let width = max(sourceWidth, 2), height = max(sourceHeight, 2)
        let scale = min(1, Double(maxLongSide) / Double(max(width, height)))
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return Size(width: even(Double(width) * scale), height: even(Double(height) * scale))
    }

    /// Bitrate medio del video: proporzionale ai pixel, fra `minBitRate` e `maxBitRate`.
    public static func videoBitRate(for size: Size) -> Int {
        let raw = Double(size.width * size.height * framesPerSecond) * bitsPerPixel
        return min(maxBitRate, max(minBitRate, Int(raw)))
    }

    public static func videoSettings(for size: Size) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.hevc,
         AVVideoWidthKey: size.width,
         AVVideoHeightKey: size.height,
         AVVideoCompressionPropertiesKey: [
             AVVideoAverageBitRateKey: videoBitRate(for: size),
             AVVideoExpectedSourceFrameRateKey: framesPerSecond,
             AVVideoMaxKeyFrameIntervalDurationKey: 2,
             AVVideoAllowFrameReorderingKey: false,
         ] as [String: Any]]
    }

    public static func audioSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: audioSampleRate,
         AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: bitRate]
    }

    /// Peso atteso in byte per un'ora, a bitrate pieno: serve alle stime nei testi e nei test.
    public static func bytesPerHour(for size: Size, microphone: Bool, systemAudio: Bool) -> Int {
        let bits = videoBitRate(for: size) + (systemAudio ? systemAudioBitRate : 0) + (microphone ? microphoneBitRate : 0)
        return bits / 8 * 3600
    }
}
