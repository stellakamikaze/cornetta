import CoreAudio
import CornettaCore
import Foundation

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }
    static var macOS: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Indirizzo del servizio (feedback, download). Sta in Info.plist accanto a SUFeedURL.
    static var serviceURL: URL {
        let raw = Bundle.main.infoDictionary?["CornettaServiceURL"] as? String ?? "https://cornetta.stellakamikaze.org"
        return URL(string: raw)!
    }

    /// Informazioni tecniche allegate al feedback. Niente audio, niente contenuti delle chiamate.
    static func diagnostics(microphone: String?) -> String {
        var lines = [
            "Cornetta \(version) (\(build)) · macOS \(macOS) · \(arch)",
            "App: \(Bundle.main.bundlePath)",
            "Microfono: \(microphone ?? CoreAudioInfo.defaultInputName ?? "nessuno")",
            "Uscita: \(CoreAudioInfo.defaultOutputName ?? "nessuna")",
            "App che usano il microfono: \(CallDetector.callApps(from: CallDetector.microphoneClients(), ownPID: getpid()).joined(separator: ", "))",
            "",
            "--- ultime righe del log ---",
        ]
        if let log = try? String(contentsOf: Diagnostics.fileURL, encoding: .utf8) {
            lines += log.split(separator: "\n").suffix(120).map(String.init)
        }
        return lines.joined(separator: "\n")
    }
}

enum CoreAudioInfo {
    static var defaultInputName: String? { name(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutputName: String? { name(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func name(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
