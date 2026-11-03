import AppKit
import CornettaCore
import ScreenCaptureKit
import SwiftUI

/// Video dello schermo: la persona sceglie schermo, finestra o app nel selettore di macOS, Cornetta
/// registra un video già compresso in ~/Movies/Cornetta. Indipendente dalla registrazione delle chiamate.
@MainActor
final class ScreenRecordingModel: NSObject, ObservableObject {
    static let shared = ScreenRecordingModel()

    @Published private(set) var isRecording = false
    @Published private(set) var isPicking = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastVideo: URL?
    @Published private(set) var withoutMicrophone = false

    @AppStorage("screenMicrophone") var includeMicrophone = true
    @AppStorage("screenSystemAudio") var includeSystemAudio = true
    @AppStorage("screenOverlay") var showOverlay = true { didSet { refreshOverlay() } }

    private var recorder: ScreenRecorder?
    private var startedAt: Date?
    private var timer: Timer?
    private var overlayPanel: FloatingPanel?
    private var closing = 0
    private var closedWaiters: [() -> Void] = []
    private var nextDiskCheck = Date.distantPast
    private var lowDiskWarned = false
    private var longWarned = false
    /// Durata dell'ultima prova da riga di comando (`--record-screen`): allo scadere si ferma da sola.
    var headlessSeconds: Double?
    var onHeadlessSaved: ((Result<ScreenFileWriter.Saved, Error>) -> Void)?
    /// Opzioni della prova da riga di comando: non toccano le preferenze salvate dell'app installata.
    var headlessOptions: (microphone: Bool, systemAudio: Bool, overlay: Bool)?

    override init() {
        super.init()
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isRecording == true else { return }
                Diagnostics.log("Il Mac va in stop durante un video: lo fermo e lo salvo")
                self?.stop(reason: "Il Mac è andato in stop durante il video. Quello che era registrato è salvato.")
            }
        }
    }

    var elapsedText: String {
        let total = Int(elapsed)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Avvio

    func toggle() {
        if isRecording { stop() } else { pick() }
    }

    /// Apre il selettore di macOS. La registrazione parte quando la persona sceglie cosa mostrare.
    func pick() {
        guard !isRecording else { return }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        isPicking = true
        Diagnostics.log("Schermo: selettore aperto")
        picker.present()
    }

    private func start(filter: SCContentFilter) async {
        isPicking = false
        guard !isRecording else { return }
        let directory = FileNaming.screenDirectory
        let url = FileNaming.screenRecordingURL(in: directory)
        let wantsMicrophone = headlessOptions?.microphone ?? includeMicrophone
        let wantsSystemAudio = headlessOptions?.systemAudio ?? includeSystemAudio
        var useMicrophone = wantsMicrophone && ScreenRecorder.supportsMicrophone
        if useMicrophone {
            useMicrophone = await CallRecorder.requestMicrophoneAccess()
        }
        let recorder = ScreenRecorder(filter: filter, outputURL: url, systemAudio: wantsSystemAudio, microphone: useMicrophone)
        recorder.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.recorder === recorder else { return }
                switch event {
                case .stopped(let text):
                    self.stop(reason: text.map { "La registrazione si è interrotta: \($0)." })
                }
            }
        }
        do {
            try await recorder.start()
        } catch {
            Diagnostics.log("Schermo: avvio non riuscito: \(error.localizedDescription)")
            endPicker()
            RecorderModel.shared.showError(
                title: "Non riesco a registrare lo schermo",
                message: error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ". Controlla in Impostazioni › Privacy e sicurezza › Registrazione schermo e audio di sistema che Cornetta sia attiva.")
            onHeadlessSaved?(.failure(error))
            return
        }
        self.recorder = recorder
        withoutMicrophone = wantsMicrophone && !recorder.microphoneIncluded
        isRecording = true
        startedAt = Date()
        elapsed = 0
        nextDiskCheck = .distantPast
        lowDiskWarned = false
        longWarned = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshOverlay()
        Diagnostics.log("Schermo: registrazione avviata in \(url.lastPathComponent)")
    }

    // MARK: - Stop

    func stop(reason: String? = nil) {
        guard let recorder else { return }
        self.recorder = nil
        isRecording = false
        startedAt = nil
        timer?.invalidate()
        timer = nil
        refreshOverlay()
        endPicker()
        closing += 1
        let reason = reason
        recorder.stop { [weak self] result in
            Task { @MainActor in self?.closed(result, reason: reason) }
        }
    }

    private func closed(_ result: Result<ScreenFileWriter.Saved, Error>, reason: String?) {
        closing -= 1
        if closing == 0 {
            let waiters = closedWaiters
            closedWaiters = []
            waiters.forEach { $0() }
        }
        if let onHeadlessSaved {
            onHeadlessSaved(result)
            return
        }
        switch result {
        case .success(let saved):
            Diagnostics.log(String(format: "Schermo: salvato %@, %.1f s, %lld byte", saved.url.lastPathComponent, saved.seconds, saved.bytes))
            lastVideo = saved.url
            let size = ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file)
            RecorderModel.shared.showNotice(kind: "screen", NoticeView(
                icon: "checkmark.circle.fill", tint: .green,
                title: "Video salvato · \(size)",
                message: (reason.map { $0 + " " } ?? "") + "\(saved.url.lastPathComponent), in Filmati › Cornetta.",
                primary: "Mostra nel Finder", secondary: "Chiudi",
                onPrimary: { RecorderModel.shared.closeNotice(); NSWorkspace.shared.activateFileViewerSelecting([saved.url]) },
                onSecondary: { RecorderModel.shared.closeNotice() }))
        case .failure(let error):
            Diagnostics.log("Schermo: salvataggio non riuscito: \(error.localizedDescription)")
            RecorderModel.shared.showError(title: "Video non salvato",
                                           message: (reason.map { $0 + " " } ?? "") + error.localizedDescription + ".")
        }
    }

    var hasUnsavedWork: Bool { isRecording || closing > 0 }

    /// All'uscita: ferma e aspetta che il file sia chiuso, al massimo `timeout` secondi. Il video a frammenti
    /// resta comunque leggibile se il tempo scade.
    func stopAndWait(timeout: TimeInterval, _ action: @escaping () -> Void) {
        if isRecording { stop() }
        guard closing > 0 else { action(); return }
        let once = Once(action)
        closedWaiters.append(once.run)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.run() }
    }

    private func endPicker() {
        isPicking = false
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    // MARK: - Durante il video

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if let headlessSeconds, elapsed >= headlessSeconds {
            stop()
            return
        }
        if elapsed > 3 * 3600, !longWarned {
            longWarned = true
            RecorderModel.shared.showNotice(kind: "screen-long", NoticeView(
                icon: "clock.fill", tint: .orange, title: "Il video dura da 3 ore",
                message: "Se l'hai dimenticato acceso, fermalo adesso.",
                primary: "Ferma e salva", secondary: "Continua",
                onPrimary: { [weak self] in RecorderModel.shared.closeNotice(); self?.stop() },
                onSecondary: { RecorderModel.shared.closeNotice() }))
        }
        checkDiskSpace()
    }

    private func checkDiskSpace() {
        let now = Date()
        guard now >= nextDiskCheck else { return }
        nextDiskCheck = now.addingTimeInterval(10)
        let values = try? FileNaming.screenDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < 200_000_000 {
            Diagnostics.log("Schermo: spazio libero \(free / 1_000_000) MB, fermo il video")
            stop(reason: "Sul disco restavano meno di 200 MB.")
        } else if free < 1_000_000_000, !lowDiskWarned {
            lowDiskWarned = true
            RecorderModel.shared.showNotice(kind: "screen-disk", NoticeView(
                icon: "externaldrive.fill.badge.exclamationmark", tint: .orange, title: "Disco quasi pieno",
                message: "Sul disco resta meno di 1 GB. Sotto i 200 MB Cornetta ferma e salva il video da sola.",
                primary: "Ferma e salva", secondary: "Continua",
                onPrimary: { [weak self] in RecorderModel.shared.closeNotice(); self?.stop() },
                onSecondary: { RecorderModel.shared.closeNotice() }))
        }
    }

    // MARK: - Pannello

    private func refreshOverlay() {
        if isRecording && (headlessOptions?.overlay ?? showOverlay) {
            if overlayPanel == nil {
                let panel = FloatingPanel(rootView: ScreenOverlayView(model: self), autosaveName: "CornettaScreenOverlay")
                // Il pannello non deve finire nel video.
                panel.sharingType = .none
                overlayPanel = panel
            }
            overlayPanel?.show()
        } else {
            overlayPanel?.orderOut(nil)
        }
    }

    func openFolder() {
        let folder = FileNaming.screenDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

// MARK: - SCContentSharingPickerObserver

extension ScreenRecordingModel: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            Diagnostics.log("Schermo: selettore chiuso senza scelta")
            guard !self.isRecording else { return }
            self.endPicker()
            self.onHeadlessSaved?(.failure(ScreenFileWriter.WriterError.failed("Selettore chiuso senza scelta")))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            if self.isRecording {
                self.recorder?.update(filter: filter)
            } else {
                await self.start(filter: filter)
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            Diagnostics.log("Schermo: selettore non aperto: \(error.localizedDescription)")
            self.endPicker()
            RecorderModel.shared.showError(title: "Non riesco ad aprire la scelta dello schermo",
                                           message: error.localizedDescription + ".")
            self.onHeadlessSaved?(.failure(error))
        }
    }
}

/// Pannello piccolo durante il video: tempo e pulsante per fermare.
struct ScreenOverlayView: View {
    @ObservedObject var model: ScreenRecordingModel

    var body: some View {
        HStack(spacing: 12) {
            RecordingDot()
            VStack(alignment: .leading, spacing: 2) {
                Text("Video dello schermo").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(model.elapsedText)
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
            }
            .frame(minWidth: 110, alignment: .leading)
            Button {
                model.stop()
            } label: {
                Label("Ferma", systemImage: "stop.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(FilledButtonStyle(color: .red))
            .help("Ferma e salva il video")
        }
        .panelStyle()
    }
}
