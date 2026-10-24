import CoreAudio
import Foundation

/// Dove esce l'audio del Mac: uscita di default, uscita degli effetti e processi che stanno riproducendo.
/// Serve al log di #3820. Al massimo due righe, senza UID né pid.
struct AudioRouting: Equatable {
    struct Output: Equatable {
        let name: String
        let transport: UInt32
        let sampleRate: Double
    }

    struct Process: Equatable {
        let bundleID: String
        let outputs: [String]
    }

    /// Oltre questo numero di processi la riga dice solo quanti altri ce ne sono.
    static let maxProcesses = 8

    let defaultOutput: Output?
    let effectsOutput: Output?
    let processes: [Process]

    /// Legge lo stato attuale da Core Audio. Non va chiamato dal thread audio.
    static func current() -> AudioRouting {
        func output(_ selector: AudioObjectPropertySelector) -> Output? {
            let id = try? CoreAudio.value(CoreAudio.system, selector, initial: AudioObjectID(kAudioObjectUnknown))
            guard let id, id != kAudioObjectUnknown else { return nil }
            return Output(name: CoreAudio.deviceName(id),
                          transport: (try? CoreAudio.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
                          sampleRate: (try? CoreAudio.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0)
        }
        let own = getpid()
        var processes: [Process] = []
        for object in CoreAudio.objects(CoreAudio.system, kAudioHardwarePropertyProcessObjectList) {
            let running = (try? CoreAudio.value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            let pid = (try? CoreAudio.value(object, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            guard running != 0, pid != own else { continue }
            // Senza bundle ID (strumenti da riga di comando, alcuni aiutanti) vale il nome del processo.
            var bundle = (try? CoreAudio.string(object, kAudioProcessPropertyBundleID)) ?? ""
            if bundle.isEmpty { bundle = processName(pid) }
            guard !bundle.isEmpty else { continue }
            let devices = CoreAudio.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            processes.append(Process(bundleID: bundle, outputs: devices.map(CoreAudio.deviceName)))
        }
        return AudioRouting(defaultOutput: output(kAudioHardwarePropertyDefaultOutputDevice),
                            effectsOutput: output(kAudioHardwarePropertyDefaultSystemOutputDevice),
                            processes: processes)
    }

    private static func processName(_ pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Le righe del log: uscite e processi. I processi uguali (aiutanti della stessa app) contano una volta.
    var logLines: [String] {
        func describe(_ output: Output?) -> String {
            guard let output else { return "nessuna" }
            return "\(output.name) (\(Self.transportName(output.transport)), \(Int(output.sampleRate)) Hz)"
        }
        let effects = effectsOutput == defaultOutput ? "uguale" : describe(effectsOutput)
        var entries: [String] = []
        for process in processes {
            let outputs = process.outputs.isEmpty ? "?" : process.outputs.joined(separator: " + ")
            let entry = "\(process.bundleID) su \(outputs)"
            if !entries.contains(entry) { entries.append(entry) }
        }
        entries.sort()
        if entries.count > Self.maxProcesses {
            let others = entries.count - Self.maxProcesses
            entries = Array(entries.prefix(Self.maxProcesses)) + ["altri \(others)"]
        }
        return ["Uscita: \(describe(defaultOutput)); effetti: \(effects)",
                "Processi in uscita: \(entries.isEmpty ? "nessuno" : entries.joined(separator: "; "))"]
    }

    /// Nome breve del trasporto di un dispositivo (kAudioDeviceTransportType…).
    static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "integrato"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "aggregato"
        case kAudioDeviceTransportTypeVirtual: return "virtuale"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        case 0: return "?"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((transport >> $0) & 0xFF) }
            return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : "?"
        }
    }
}
