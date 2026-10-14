import CoreAudio
import Foundation

/// Sonda diagnostica: prova tap e dispositivo aggregato in varie combinazioni e riporta cosa gira.
public enum Probe {
    public static func run() -> [String] {
        var lines: [String] = []
        func measure(_ label: String, device: AudioObjectID) {
            var count = 0
            let lock = NSLock()
            var proc: AudioDeviceIOProcID?
            let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, _, _, _, _ in
                lock.lock(); count += 1; lock.unlock()
            }
            let started = AudioDeviceStart(device, proc)
            Thread.sleep(forTimeInterval: 1.5)
            let running = (try? CoreAudio.value(device, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(9))) ?? 9
            AudioDeviceStop(device, proc)
            if let proc { AudioDeviceDestroyIOProcID(device, proc) }
            lines.append("\(label): create=\(created) start=\(started) running=\(running) callbacks=\(count)")
        }

        let mic = CoreAudio.defaultInputDevice()
        let out = CoreAudio.defaultOutputDevice()
        if let mic { measure("mic diretto", device: mic) }

        // Aggregato senza tap, solo microfono.
        if let mic, let uid = try? CoreAudio.string(mic, kAudioDevicePropertyDeviceUID) {
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Cornetta probe",
                kAudioAggregateDeviceUIDKey: "com.stellakamikaze.cornetta.probe.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            ]
            var id = AudioObjectID(0)
            let st = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
            lines.append("aggregate solo mic: create=\(st)")
            if st == noErr { Thread.sleep(forTimeInterval: 0.3); measure("aggregate solo mic", device: id); AudioHardwareDestroyAggregateDevice(id) }
        }

        // Taps già presenti nel sistema.
        var addr = address(kAudioHardwarePropertyTapList)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(CoreAudio.system, &addr, 0, nil, &size)
        lines.append("taps nel sistema: \(Int(size) / MemoryLayout<AudioObjectID>.size)")

        let own = try? CoreAudio.processObject(pid: getpid())
        let variants: [(String, () -> CATapDescription)] = [
            ("globale privato escluso-me", {
                let d = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
                d.isPrivate = true; return d
            }),
            ("globale pubblico senza esclusioni", {
                CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }),
            ("globale privato senza esclusioni", {
                let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                d.isPrivate = true; return d
            }),
        ]
        for (name, make) in variants {
            let description = make()
            description.uuid = UUID()
            var tapID = AudioObjectID(0)
            let st = AudioHardwareCreateProcessTap(description, &tapID)
            guard st == noErr else { lines.append("\(name): create tap \(st)"); continue }
            let tapUID = description.uuid.uuidString
            for autostart in [true, false] {
                let dict: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "Cornetta probe",
                    kAudioAggregateDeviceUIDKey: "com.stellakamikaze.cornetta.probe.\(UUID().uuidString)",
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceTapAutoStartKey: autostart,
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                ]
                var id = AudioObjectID(0)
                let cst = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &id)
                if cst == noErr {
                    Thread.sleep(forTimeInterval: 0.3)
                    measure("\(name) solo-tap autostart=\(autostart)", device: id)
                    AudioHardwareDestroyAggregateDevice(id)
                } else {
                    lines.append("\(name): create aggregate \(cst)")
                }
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        _ = out
        return lines
    }
}
