import CoreAudio
import Foundation

/// Un processo che sta usando il microfono.
public struct MicrophoneClient: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String

    public init(pid: pid_t, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Capisce se è in corso una chiamata guardando quali app usano il microfono.
public enum CallDetector {
    /// Processi di sistema che usano il microfono senza essere una chiamata (Siri, dettatura…).
    static let ignoredPrefixes = [
        "com.apple.siri", "com.apple.assistant", "com.apple.CoreSpeech", "com.apple.corespeech",
        "com.apple.SpeechRecognitionCore", "com.apple.dictation", "com.apple.DictationIM",
        "com.apple.accessibility", "com.apple.VoiceMemos", "com.apple.audio", "com.apple.coreaudio",
        "com.apple.controlcenter", "com.apple.systemsound", "com.apple.voicebankingd",
        "com.stellakamikaze.cornetta",   // un'altra copia di Cornetta non è una chiamata
    ]

    /// Processi che usano il microfono adesso, letti da Core Audio (macOS 14+).
    public static func microphoneClients() -> [MicrophoneClient] {
        CoreAudio.objects(CoreAudio.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            let running = (try? CoreAudio.value(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0
            guard running != 0 else { return nil }
            let pid = (try? CoreAudio.value(object, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            let bundle = (try? CoreAudio.string(object, kAudioProcessPropertyBundleID)) ?? ""
            return MicrophoneClient(pid: pid, bundleID: bundle)
        }
    }

    /// Le app che probabilmente sono in chiamata, normalizzate (un helper di Chrome diventa Chrome).
    public static func callApps(from clients: [MicrophoneClient], ownPID: pid_t) -> [String] {
        var apps: [String] = []
        for client in clients where client.pid != ownPID && !client.bundleID.isEmpty {
            if ignoredPrefixes.contains(where: { client.bundleID.hasPrefix($0) }) { continue }
            let app = normalize(client.bundleID)
            if !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    /// Riporta i processi ausiliari all'app che l'utente riconosce.
    public static func normalize(_ bundleID: String) -> String {
        if bundleID.contains("avconferenced") || bundleID.contains("FaceTime") || bundleID.contains("TelephonyUtilities") {
            return "com.apple.FaceTime"
        }
        if bundleID.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        let lower = bundleID.lowercased()
        for marker in [".helper", ".framework.audioservice", ".audioservice"] {
            if let range = lower.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }
        return bundleID
    }
}
