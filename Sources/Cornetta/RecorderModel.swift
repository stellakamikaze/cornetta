import AppKit
import CornettaCore
import Foundation

@MainActor
final class RecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneName: String?
    @Published private(set) var message: String?
    @Published private(set) var lastFile: URL?

    private var recorder: CallRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    var elapsedText: String {
        let total = Int(elapsed)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        message = nil
        Diagnostics.log("Avvio richiesto")
        let micAllowed = await CallRecorder.requestMicrophoneAccess()
        Diagnostics.log("Permesso microfono: \(micAllowed)")
        let url = FileNaming.recordingURL(in: FileNaming.defaultDirectory)
        let recorder = CallRecorder(outputURL: url)
        recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try recorder.start(useMicrophone: micAllowed)
        } catch {
            message = error.localizedDescription
            return
        }
        self.recorder = recorder
        microphoneName = recorder.microphoneName
        if !micAllowed {
            message = "Microfono non autorizzato: registro solo l'audio della chiamata."
        } else if recorder.microphoneName == nil {
            message = "Nessun microfono trovato: registro solo l'audio della chiamata."
        }
        isRecording = true
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard let recorder else { return }
        let stats = recorder.stop()
        Diagnostics.log(String(format: "Stop: %.2f s scritti, %.2f s dall'avvio, riavvii %d", stats.seconds, Date().timeIntervalSince(startedAt ?? Date()), recorder.restartCount))
        lastFile = recorder.outputURL
        finish()
        message = "Salvata: \(recorder.outputURL.lastPathComponent)"
    }

    func openFolder() {
        let folder = FileNaming.defaultDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func revealLastFile() {
        guard let lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    private func handle(_ event: CallRecorder.Event) {
        switch event {
        case .microphoneChanged(let name):
            microphoneName = name
        case .failure(let text):
            if let recorder { lastFile = recorder.outputURL }
            finish()
            message = text
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        startedAt = nil
    }
}
