import AVFoundation

/// Scrive il mix finale in AAC a 48 kHz e, se richiesto, le tracce separate in WAV.
/// Va usato da una sola coda.
final class TrackWriter {
    static let fileSampleRate: Double = 48_000

    private var file: AVAudioFile?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private let debugDirectory: URL?
    private var converter: AVAudioConverter?
    private var leveler = VoiceLeveler()
    private(set) var stats = CallRecorder.Stats()
    let meter: LevelMeter

    init(outputURL: URL, debugDirectory: URL?, meter: LevelMeter) throws {
        self.meter = meter
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.fileSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        file = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.debugDirectory = debugDirectory
        if let debugDirectory {
            try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        }
    }

    func write(mic: [[Float]], system: [[Float]], frameCount: Int, sampleRate: Double) throws {
        guard let file, frameCount > 0, sampleRate > 0 else { return }

        let micMono = Mixer.downmixToMono(mic, frameCount: frameCount)
        let systemStereo = Mixer.toStereo(system, frameCount: frameCount)
        stats.record(micRMS: mic.isEmpty ? 0 : Mixer.rms(micMono),
                     systemRMS: max(Mixer.rms(systemStereo.left), Mixer.rms(systemStereo.right)),
                     frames: frameCount, sampleRate: sampleRate, hasMicrophone: !mic.isEmpty)

        let systemRMS = max(Mixer.rms(systemStereo.left), Mixer.rms(systemStereo.right))
        let leveledMic = mic.isEmpty ? [] : [leveler.process(micMono, systemRMS: systemRMS, sampleRate: sampleRate)]
        meter.update(mic: leveledMic.first.map(Mixer.rms) ?? 0, system: systemRMS, micGain: leveler.gain)
        let mixed = Mixer.mix(mic: leveledMic, system: system, frameCount: frameCount)
        let buffer = try makeBuffer([mixed.left, mixed.right], sampleRate: sampleRate)

        if sampleRate == Self.fileSampleRate {
            try file.write(from: buffer)
        } else {
            try file.write(from: try resample(buffer, to: file.processingFormat))
        }

        if let debugDirectory {
            try writeDebug(micMono: micMono, system: systemStereo, sampleRate: sampleRate, directory: debugDirectory)
        }
    }

    func close() {
        file = nil
        micFile = nil
        systemFile = nil
        converter = nil
    }

    private func makeBuffer(_ channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let frameCount = channels.first?.count ?? 0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let data = buffer.floatChannelData else {
            throw CoreAudioError("Preparazione del buffer audio", kAudioHardwareUnspecifiedError)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { source in
                data[index].update(from: source.baseAddress!, count: frameCount)
            }
        }
        return buffer
    }

    private func resample(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if converter?.inputFormat.sampleRate != input.format.sampleRate {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else {
            throw CoreAudioError("Conversione della frequenza di campionamento", kAudioHardwareUnspecifiedError)
        }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CoreAudioError("Conversione della frequenza di campionamento", kAudioHardwareUnspecifiedError)
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return output
    }

    private func writeDebug(micMono: [Float], system: (left: [Float], right: [Float]), sampleRate: Double, directory: URL) throws {
        if micFile == nil {
            let wav = { (channels: Int) -> [String: Any] in
                [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
            }
            micFile = try AVAudioFile(forWriting: directory.appendingPathComponent("mic.wav"), settings: wav(1),
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            systemFile = try AVAudioFile(forWriting: directory.appendingPathComponent("system.wav"), settings: wav(2),
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard micFile?.processingFormat.sampleRate == sampleRate else { return }
        try micFile?.write(from: makeBuffer([micMono], sampleRate: sampleRate))
        try systemFile?.write(from: makeBuffer([system.left, system.right], sampleRate: sampleRate))
    }
}
