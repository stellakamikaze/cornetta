import AppKit
import CornettaCore
import Foundation

/// Prova del video dello schermo senza la barra dei menu:
/// Cornetta --record-screen <secondi> [--out <file.json>] [--no-mic] [--no-audio] [--no-overlay]
/// Apre il selettore di macOS, registra i secondi dati da quando si sceglie, poi scrive l'esito in JSON
/// (file, secondi, byte, errore) ed esce. Il video va in ~/Movies/Cornetta come dal menu.
enum HeadlessScreen {
    @MainActor static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let seconds = Double(value("--record-screen") ?? "") ?? 10
        let report = value("--out").map { URL(fileURLWithPath: $0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = ScreenRecordingModel.shared
        model.headlessOptions = (microphone: !arguments.contains("--no-mic"),
                                 systemAudio: !arguments.contains("--no-audio"),
                                 overlay: !arguments.contains("--no-overlay"))
        model.headlessSeconds = seconds
        model.onHeadlessSaved = { result in
            var json: [String: String] = [:]
            switch result {
            case .success(let saved):
                json = ["file": saved.url.path, "seconds": String(format: "%.2f", saved.seconds), "bytes": String(saved.bytes)]
            case .failure(let error):
                json = ["error": error.localizedDescription]
            }
            let text = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if let report { try? text.write(to: report, atomically: true, encoding: .utf8) }
            print(text)
            exit(json["error"] == nil ? 0 : 1)
        }
        DispatchQueue.main.async { model.pick() }
        app.run()
    }
}
