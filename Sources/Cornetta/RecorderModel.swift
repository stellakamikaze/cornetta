import AppKit
import CornettaCore
import SwiftUI

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneName: String?
    @Published private(set) var message: String?
    @Published private(set) var lastFile: URL?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var callEndedSuggestion = false

    @AppStorage("showOverlay") var showOverlay = true { didSet { refreshOverlay() } }
    @AppStorage("proposeOnCall") var proposeOnCall = true

    private var recorder: CallRecorder?
    private var startedAt: Date?
    private var meterTimer: Timer?
    private var callTimer: Timer?

    // Rilevamento chiamate
    private var callAppsSeen: [String: Date] = [:]
    private var promptedApps: Set<String> = []
    private var lastCallAppSeenAt: Date?

    // Pannelli
    private var overlayPanel: FloatingPanel?
    private var noticePanel: FloatingPanel?
    private var noticeKind: String?
    private var feedbackWindow: NSWindow?
    private var pendingUpdateNotice: String?

    init() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCalls() }
        }
        UpdateManager.shared.onUpdateFound = { [weak self] version in
            self?.announceUpdate(version)
        }
    }

    var elapsedText: String {
        let total = Int(elapsed)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Registrazione

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        message = nil
        closeNotice()
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
        callEndedSuggestion = false
        startedAt = Date()
        elapsed = 0
        lastCallAppSeenAt = callAppsSeen.isEmpty ? nil : Date()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshOverlay()
    }

    func stop() {
        guard let recorder else { return }
        let stats = recorder.stop()
        Diagnostics.log(String(format: "Stop: %.2f s scritti, %.2f s dall'avvio, riavvii %d, guadagno voce %.1f",
                               stats.seconds, Date().timeIntervalSince(startedAt ?? Date()), recorder.restartCount,
                               recorder.meter.micGain))
        lastFile = recorder.outputURL
        finish()
        message = "Salvata: \(recorder.outputURL.lastPathComponent)"
        if let version = pendingUpdateNotice {
            pendingUpdateNotice = nil
            announceUpdate(version)
        }
    }

    func dismissCallEnded() {
        callEndedSuggestion = false
        lastCallAppSeenAt = nil
    }

    private func tick() {
        guard let startedAt, let recorder else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        let levels = recorder.meter.levels
        micLevel = levels.mic
        systemLevel = levels.system
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
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        startedAt = nil
        callEndedSuggestion = false
        micLevel = 0
        systemLevel = 0
        refreshOverlay()
    }

    // MARK: - Pannello di registrazione

    private func refreshOverlay() {
        if isRecording && showOverlay {
            if overlayPanel == nil {
                overlayPanel = FloatingPanel(rootView: RecordingOverlayView(model: self), autosaveName: "CornettaOverlay")
            }
            overlayPanel?.show()
        } else {
            overlayPanel?.orderOut(nil)
        }
    }

    // MARK: - Chiamate

    private func pollCalls() {
        let apps = CallDetector.callApps(from: CallDetector.microphoneClients(), ownPID: getpid())
        let now = Date()
        for app in apps where callAppsSeen[app] == nil { callAppsSeen[app] = now }
        for app in callAppsSeen.keys where !apps.contains(app) {
            callAppsSeen[app] = nil
            promptedApps.remove(app)
        }

        if isRecording {
            if !apps.isEmpty {
                lastCallAppSeenAt = now
                if callEndedSuggestion { callEndedSuggestion = false }
            } else if let last = lastCallAppSeenAt, now.timeIntervalSince(last) > 6, !callEndedSuggestion {
                // L'app di chiamata ha lasciato il microfono: probabilmente la chiamata è finita.
                callEndedSuggestion = true
                if !showOverlay { showCallEndedNotice() }
            }
            return
        }

        if noticeKind == "call", apps.isEmpty { closeNotice() }
        guard proposeOnCall, noticeKind == nil else { return }
        // Avviso solo se l'app usa il microfono da almeno 4 secondi (niente falsi allarmi da dettatura).
        if let app = apps.first(where: { !promptedApps.contains($0) && now.timeIntervalSince(callAppsSeen[$0] ?? now) >= 4 }) {
            promptedApps.insert(app)
            showCallNotice(appName: Self.displayName(for: app))
        }
    }

    private func showCallNotice(appName: String) {
        Diagnostics.log("Chiamata rilevata: \(appName)")
        showNotice(kind: "call", NoticeView(
            icon: "phone.fill", tint: .red,
            title: "Chiamata in corso su \(appName)",
            message: "Vuoi registrarla? Registro la tua voce e quella delle altre persone in un file.",
            primary: "Registra", secondary: "Non ora",
            onPrimary: { [weak self] in self?.closeNotice(); Task { await self?.start() } },
            onSecondary: { [weak self] in self?.closeNotice() }))
        // Se nessuno risponde, l'avviso sparisce da solo dopo 30 secondi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.noticeKind == "call" { self?.closeNotice() }
        }
    }

    private func showCallEndedNotice() {
        showNotice(kind: "ended", NoticeView(
            icon: "phone.down.fill", tint: .orange,
            title: "La chiamata sembra finita",
            message: "Cornetta sta ancora registrando.",
            primary: "Ferma e salva", secondary: "Continua",
            onPrimary: { [weak self] in self?.closeNotice(); self?.stop() },
            onSecondary: { [weak self] in self?.closeNotice(); self?.dismissCallEnded() }))
    }

    static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: - Aggiornamenti

    func announceUpdate(_ version: String) {
        // Durante una registrazione l'avviso aspetta lo stop: niente distrazioni in chiamata.
        guard !isRecording else { pendingUpdateNotice = version; return }
        showNotice(kind: "update", NoticeView(
            icon: "arrow.down.circle.fill", tint: .blue,
            title: "Aggiornamento disponibile",
            message: "È pronta Cornetta \(version). L'installazione richiede pochi secondi e l'app si riapre da sola.",
            primary: "Aggiorna ora", secondary: "Più tardi",
            onPrimary: { [weak self] in self?.closeNotice(); UpdateManager.shared.installOrCheck() },
            onSecondary: { [weak self] in self?.closeNotice() }))
        NSSound(named: "Glass")?.play()
    }

    // MARK: - Avvisi

    private func showNotice<V: View>(kind: String, _ view: V) {
        noticePanel?.orderOut(nil)
        noticePanel = FloatingPanel(rootView: view, autosaveName: "CornettaNotice")
        noticeKind = kind
        noticePanel?.show()
    }

    private func closeNotice() {
        noticePanel?.orderOut(nil)
        noticePanel = nil
        noticeKind = nil
    }

    // MARK: - Feedback

    func openFeedback() {
        if let feedbackWindow {
            NSApp.activate(ignoringOtherApps: true)
            feedbackWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Feedback su Cornetta"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: FeedbackView(microphone: microphoneName) { [weak self] in
            self?.feedbackWindow?.close()
            self?.feedbackWindow = nil
        })
        window.center()
        feedbackWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dimostrazione (per gli screenshot del sito)

    /// `Cornetta --demo`: mostra pannello e avvisi con dati di esempio, senza registrare.
    func showDemo() {
        isRecording = true
        elapsed = 12 * 60 + 48
        microphoneName = "Microfono MacBook Air"
        micLevel = 0.72
        systemLevel = 0.81
        refreshOverlay()
        showCallNotice(appName: "WhatsApp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let panel = FloatingPanel(rootView: NoticeView(
                icon: "arrow.down.circle.fill", tint: .blue,
                title: "Aggiornamento disponibile",
                message: "È pronta Cornetta 0.3.0. L'installazione richiede pochi secondi e l'app si riapre da sola.",
                primary: "Aggiorna ora", secondary: "Più tardi", onPrimary: {}, onSecondary: {}),
                autosaveName: "CornettaDemoUpdate")
            panel.setFrameOrigin(NSPoint(x: 80, y: 120))
            panel.show()
            self.demoPanels.append(panel)
        }
    }

    private var demoPanels: [FloatingPanel] = []

    // MARK: - Finder

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
}
