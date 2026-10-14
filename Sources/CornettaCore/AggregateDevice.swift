import CoreAudio
import Foundation

/// Dispositivo aggregato privato: microfono di default + tap di sistema, con un solo clock.
final class AggregateDevice {
    let deviceID: AudioObjectID
    /// Canali per stream di input, nell'ordine in cui arrivano alla callback.
    let streamChannels: [Int]
    /// Quanti stream all'inizio della lista appartengono al dispositivo fisico (non al tap).
    let leadingStreamCount: Int
    /// true se il dispositivo fisico è il microfono. false se è l'uscita, usata solo come clock.
    let leadingStreamsAreMicrophone: Bool
    let micName: String?

    init(tap: SystemAudioTap, microphone: AudioObjectID?) throws {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cornetta",
            kAudioAggregateDeviceUIDKey: "com.stellakamikaze.cornetta.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Con tapautostart = true su macOS 26 il dispositivo non parte mai (verificato con --probe).
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        // Senza microfono serve comunque un dispositivo fisico che dia il clock: si usa l'uscita di default.
        let clockDevice = microphone ?? CoreAudio.defaultOutputDevice()
        var leadingStreams = 0
        if let clockDevice, let clockUID = try? CoreAudio.string(clockDevice, kAudioDevicePropertyDeviceUID) {
            description[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
            leadingStreams = (try? CoreAudio.inputStreamChannels(clockDevice).count) ?? 0
        }
        leadingStreamsAreMicrophone = microphone != nil
        micName = microphone.map(CoreAudio.deviceName)

        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creazione del dispositivo aggregato")
        deviceID = id

        // Il dispositivo aggregato pubblica gli stream poco dopo la creazione.
        var channels: [Int] = []
        for _ in 0..<20 {
            channels = (try? CoreAudio.inputStreamChannels(id)) ?? []
            if channels.count >= leadingStreams + 1 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard channels.count >= leadingStreams + 1 else {
            AudioHardwareDestroyAggregateDevice(id)
            throw CoreAudioError("Il dispositivo audio non è ancora pronto", kAudioHardwareNotRunningError)
        }
        streamChannels = channels
        leadingStreamCount = leadingStreams
    }

    var sampleRate: Double {
        (try? CoreAudio.value(deviceID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
    }

    func destroy() {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}
