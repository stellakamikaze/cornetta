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
    private var isStarting = false
    private var systemPeak: Float = 0
    private var silenceWarned = false
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
        Library.shared.onTranscriptReady = { [weak self] recording in
            self?.announceTranscript(recording)
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
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        message = nil
        closeNotice()
        Diagnostics.log("Avvio richiesto")
        let micAllowed = await CallRecorder.requestMicrophoneAccess()
        Diagnostics.log("Permesso microfono: \(micAllowed)")
        let url = FileNaming.recordingURL(in: FileNaming.defaultDirectory)
        let recorder = CallRecorder(outputURL: url, workingDirectory: Library.shared.workingDirectory(for: url),
                                    tracksDirectory: SpeechEngine.isAvailable ? Library.shared.tracksDirectory(for: url) : nil)
        recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Si imposta all'avvio: anche uno stop per errore del dispositivo converte il file e deve
        // farlo entrare in libreria (e quindi in trascrizione), non solo lo stop dal menu.
        recorder.onFinalized = { [weak self] result in
            switch result {
            case .success(let saved):
                self?.lastFile = saved.recording
                self?.message = "Salvata: \(saved.recording.lastPathComponent)"
                Library.shared.recordingFinished(saved.recording)
            case .failure(let error):
                self?.message = "Salvataggio non riuscito: \(error.localizedDescription). L'audio resta al sicuro e viene recuperato al prossimo avvio."
            }
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
        systemPeak = 0
        silenceWarned = false
        meterTimer?.invalidate()
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
        finish()
        message = "Salvo la registrazione…"
        if let version = pendingUpdateNotice {
            pendingUpdateNotice = nil
            announceUpdate(version)
        }
    }

    /// All'uscita dall'app: chiude i file senza convertire. Il prossimo avvio recupera la registrazione.
    func stopForTermination() {
        guard let recorder else { return }
        recorder.stopForTermination()
        Diagnostics.log("Uscita durante una registrazione: la recupero al prossimo avvio")
        finish()
    }

    func noteRecovered(_ name: String) {
        message = "Recuperata una registrazione interrotta: \(name)"
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
        systemPeak = max(systemPeak, levels.system)
        checkAudioArrives(recorder)
    }

    /// Se macOS non dà l'audio (permesso negato, dispositivo bloccato), lo si dice subito, non a fine chiamata.
    private func checkAudioArrives(_ recorder: CallRecorder) {
        guard !silenceWarned else { return }
        let noAudio = elapsed > 8 && (recorder.callbackCount == 0 || recorder.restartCount >= 3)
        let noOthers = elapsed > 25 && systemPeak == 0 && !callAppsSeen.isEmpty
        guard noAudio || noOthers else { return }
        silenceWarned = true
        Diagnostics.log(noAudio ? "Avviso: nessun audio in arrivo" : "Avviso: audio di sistema muto durante una chiamata")
        showError(title: noAudio ? "Cornetta non riceve audio" : "Non sento la voce degli altri",
                  message: noAudio
                    ? "macOS non sta passando l'audio a Cornetta. Controlla in Impostazioni › Privacy e sicurezza che Cornetta possa usare microfono e audio di sistema."
                    : "La chiamata è in corso ma l'audio di sistema è muto. Controlla in Impostazioni › Privacy e sicurezza › Registrazione schermo e audio di sistema che Cornetta sia attiva.")
    }

    private func showError(title: String, message: String) {
        NSSound(named: "Basso")?.play()
        showNotice(kind: "error", NoticeView(
            icon: "exclamationmark.triangle.fill", tint: .orange, title: title, message: message,
            primary: "Apri Impostazioni", secondary: "Chiudi",
            onPrimary: { [weak self] in
                self?.closeNotice()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) }
            },
            onSecondary: { [weak self] in self?.closeNotice() }))
    }

    private func handle(_ event: CallRecorder.Event) {
        switch event {
        case .microphoneChanged(let name):
            microphoneName = name
        case .failure(let text):
            finish()
            message = text
            showError(title: "Registrazione interrotta", message: text + " Quello che era già registrato viene salvato.")
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

    // MARK: - Trascrizioni

    private func announceTranscript(_ recording: Library.Recording) {
        guard !isRecording, noticeKind == nil || noticeKind == "transcript" else { return }
        showNotice(kind: "transcript", NoticeView(
            icon: "text.bubble.fill", tint: Color(red: 0.11, green: 0.50, blue: 0.24),
            title: "Trascrizione pronta",
            message: "\(Library.shared.title(for: recording)) è trascritta, con la tua voce e quella degli altri separate.",
            primary: "Apri", secondary: "Chiudi",
            onPrimary: { [weak self] in self?.closeNotice(); LibraryWindow.show(select: recording.id) },
            onSecondary: { [weak self] in self?.closeNotice() }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.noticeKind == "transcript" { self?.closeNotice() }
        }
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
