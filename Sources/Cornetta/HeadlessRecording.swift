import CornettaCore
import Foundation

/// Modalità senza interfaccia, per i test:
/// Cornetta --record <secondi> [--out <file.m4a>] [--debug-tracks <cartella>] [--no-mic]
/// Scrive le statistiche in <file.m4a>.json.
enum HeadlessRecording {
    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let seconds = Double(value("--record") ?? "") ?? 10
        let output = value("--out").map { URL(fileURLWithPath: $0) }
            ?? FileNaming.recordingURL(in: FileNaming.defaultDirectory)
        let debug = value("--debug-tracks").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let wantsMic = !arguments.contains("--no-mic")

        let micAllowed: Bool
        if wantsMic {
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            Task.detached {
                granted = await CallRecorder.requestMicrophoneAccess()
                semaphore.signal()
            }
            semaphore.wait()
            micAllowed = granted
        } else {
            micAllowed = false
        }

        // --cycles N: registra N volte di seguito nello stesso processo (test di regressione).
        let cycles = Int(value("--cycles") ?? "") ?? 1
        var report: [String: String] = ["file": output.path, "microphoneAllowed": String(micAllowed)]
        for cycle in 1..<max(cycles, 1) {
            let extra = CallRecorder(outputURL: output.deletingPathExtension().appendingPathExtension("ciclo\(cycle).m4a"))
            do {
                try extra.start(useMicrophone: micAllowed)
                let end = Date().addingTimeInterval(seconds)
                RunLoop.main.add(Timer(fire: end, interval: 0, repeats: false) { _ in }, forMode: .default)
                while Date() < end { RunLoop.main.run(until: end) }
                report["ciclo\(cycle)"] = "callbacks=\(extra.callbackCount) restarts=\(extra.restartCount) seconds=\(String(format: "%.2f", extra.stop().seconds))"
            } catch {
                report["ciclo\(cycle)"] = error.localizedDescription
            }
        }
        let tracks = value("--tracks").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let recorder = CallRecorder(outputURL: output, debugDirectory: debug, tracksDirectory: tracks)
        do {
            try recorder.start(useMicrophone: micAllowed)
            report["microphone"] = recorder.microphoneName ?? "nessuno"
            // Un run loop senza sorgenti ritorna subito: il timer lo tiene vivo per tutta la durata.
            let end = Date().addingTimeInterval(seconds)
            RunLoop.main.add(Timer(fire: end, interval: 0, repeats: false) { _ in }, forMode: .default)
            while Date() < end { RunLoop.main.run(until: end) }
            report["diagnostics"] = recorder.diagnostics + " " + recorder.deviceState
            report["wallSeconds"] = String(format: "%.2f", seconds - end.timeIntervalSinceNow)
            report["callbacks"] = String(recorder.callbackCount)
            report["restarts"] = String(recorder.restartCount)
            let stats = recorder.stop()
            report["seconds"] = String(format: "%.2f", stats.seconds)
            report["micPeakRMS"] = String(format: "%.5f", stats.micPeakRMS)
            report["systemPeakRMS"] = String(format: "%.5f", stats.systemPeakRMS)
        } catch {
            report["error"] = error.localizedDescription
        }

        let json = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? json.write(to: output.appendingPathExtension("json"))
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(report["error"] == nil ? 0 : 1)
    }
}
