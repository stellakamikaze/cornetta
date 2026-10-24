import CoreAudio
import Testing
@testable import CornettaCore

/// Righe del log su uscite e processi (#3820): al massimo due, senza UID né pid.
struct AudioRoutingTests {
    let speakers = AudioRouting.Output(name: "Altoparlanti MacBook Air", transport: kAudioDeviceTransportTypeBuiltIn, sampleRate: 48_000)
    let airpods = AudioRouting.Output(name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth, sampleRate: 24_000)

    @Test func twoLinesWithOutputsAndProcesses() {
        let routing = AudioRouting(defaultOutput: airpods, effectsOutput: speakers, processes: [
            .init(bundleID: "org.mozilla.firefox", outputs: ["AirPods"]),
            .init(bundleID: "com.apple.Music", outputs: ["AirPods", "Altoparlanti MacBook Air"]),
            .init(bundleID: "org.mozilla.firefox", outputs: ["AirPods"]),
        ])
        #expect(routing.logLines == [
            "Uscita: AirPods (Bluetooth, 24000 Hz); effetti: Altoparlanti MacBook Air (integrato, 48000 Hz)",
            "Processi in uscita: com.apple.Music su AirPods + Altoparlanti MacBook Air; org.mozilla.firefox su AirPods",
        ])
    }

    @Test func sameEffectsOutputAndNoProcesses() {
        let routing = AudioRouting(defaultOutput: speakers, effectsOutput: speakers, processes: [])
        #expect(routing.logLines == [
            "Uscita: Altoparlanti MacBook Air (integrato, 48000 Hz); effetti: uguale",
            "Processi in uscita: nessuno",
        ])
        let empty = AudioRouting(defaultOutput: nil, effectsOutput: speakers, processes: [.init(bundleID: "a.b", outputs: [])])
        #expect(empty.logLines.first == "Uscita: nessuna; effetti: Altoparlanti MacBook Air (integrato, 48000 Hz)")
        #expect(empty.logLines.last == "Processi in uscita: a.b su ?")
    }

    @Test func longProcessListIsCut() {
        let processes = (0..<12).map { AudioRouting.Process(bundleID: "app.\($0 + 10)", outputs: ["X"]) }
        let line = AudioRouting(defaultOutput: speakers, effectsOutput: speakers, processes: processes).logLines[1]
        #expect(line.hasSuffix("; altri 4"))
        #expect(line.components(separatedBy: "; ").count == AudioRouting.maxProcesses + 1)
    }

    @Test func transportNames() {
        #expect(AudioRouting.transportName(kAudioDeviceTransportTypeUSB) == "USB")
        #expect(AudioRouting.transportName(kAudioDeviceTransportTypeAirPlay) == "AirPlay")
        #expect(AudioRouting.transportName(0) == "?")
        #expect(AudioRouting.transportName(0x7A7A_7A7A) == "zzzz")
    }
}
