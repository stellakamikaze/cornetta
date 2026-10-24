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
    private var noAudioWarned = false
    private var noOthersWarned = false
    private var startedAt: Date?
    private var meterTimer: Timer?
    private var callTimer: Timer?
    /// Registrazioni in corso o in conversione, per file di uscita: uscita e aggiornamento le aspettano.
    private var unsaved: Set<URL> = []
    private var savedWaiters: [() -> Void] = []

    // Registrazione dimenticata e spazio su disco
    private var lastSoundAt: Date?
    private var nextDiskCheck = Date.distantPast
    private var lowDiskWarned = false
    private var longRecordingWarned = false
    private static let forgottenAfter: TimeInterval = 10 * 60
    private static let longRecording: TimeInterval = 3 * 3600
    private static let diskWarnBytes: Int64 = 1_000_000_000
    private static let diskStopBytes: Int64 = 200_000_000

    // Rilevamento chiamate
    private var callAppsSeen: [String: Date] = [:]
    private var promptedApps: Set<String> = []
    private var lastCallAppSeenAt: Date?
    /// Ultimo avviso sulla voce degli altri sparita: al massimo uno ogni 20 minuti.
    private var othersWarnedAt: Date?
    private static let othersWarningInterval: TimeInterval = 20 * 60

    // Pannelli
    private var overlayPanel: FloatingPanel?
    private var noticePanel: FloatingPanel?
    private var noticeKind: String?
    private var feedbackWindow: NSWindow?
    private var pendingUpdateNotice: String?
    private var pendingRecoveryFailures: [URL] = []
    private var pendingTranscripts: [Library.Recording] = []
    private var transcriptsInNotice: [Library.Recording] = []
    /// Avvisi legati alla registrazione in corso: allo stop non servono più.
    private static let recordingNotices: Set<String> = ["ended", "others", "disk", "long"]
    /// Avvisi informativi che la proposta di registrare una chiamata può sostituire: restano a schermo finché
    /// non si chiudono e bloccherebbero la proposta. L'errore no: dice che Cornetta non può registrare.
    private static let replacedByCall: Set<String> = ["stopped", "recovery", "update", "transcript"]
    /// Rimette in coda l'avviso a schermo quando la proposta di chiamata lo sostituisce.
    private var requeueNotice: (() -> Void)?
    /// Motivo dello stop automatico, per file di uscita: l'avviso parte a conversione finita, con l'esito vero.
    private var stopReasons: [URL: String] = [:]

    init() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCalls() }
        }
        // Come su Windows: a coperchio chiuso la registrazione si ferma e si salva, non riprende al risveglio.
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForSleep() }
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
        let url = FileNaming.newRecordingURL(in: FileNaming.defaultDirectory, workingRoot: Library.shared.workingRoot)
        let recorder = CallRecorder(outputURL: url, workingDirectory: Library.shared.workingDirectory(for: url),
                                    tracksDirectory: SpeechEngine.isAvailable ? Library.shared.tracksDirectory(for: url) : nil)
        recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Si imposta all'avvio: anche uno stop per errore del dispositivo converte il file e deve
        // farlo entrare in libreria (e quindi in trascrizione), non solo lo stop dal menu.
        recorder.onFinalized = { [weak self] result in
            defer { self?.saved(url) }
            switch result {
            case .success(let saved):
                Telemetry.send(.registrazione, outcome: "ok", seconds: saved.seconds)
                self?.lastFile = saved.recording
                self?.message = "Salvata: \(saved.recording.lastPathComponent)"
                Library.shared.recordingFinished(saved.recording)
            case .failure(let error):
                Telemetry.send(.registrazione, outcome: "errore", code: TelemetryFields.errorCode(error, prefix: "salvataggio"))
                self?.message = "Salvataggio non riuscito: \(error.localizedDescription). L'audio resta al sicuro e viene recuperato al prossimo avvio."
            }
            if let reason = self?.stopReasons.removeValue(forKey: url) {
                let converted: Bool
                if case .success = result { converted = true } else { converted = false }
                self?.showStoppedNotice(reason, converted: converted)
            }
        }
        recorder.callActive = !callAppsSeen.isEmpty
        do {
            try recorder.start(useMicrophone: micAllowed)
        } catch {
            Telemetry.send(.registrazione, outcome: "errore", code: TelemetryFields.errorCode(error, prefix: "avvio"))
            message = error.localizedDescription
            // Il menu è chiuso: senza avviso chi ha premuto «Registra» crede che Cornetta registri.
            showError(title: "Non riesco a registrare",
                      message: error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ". Controlla in Impostazioni › Privacy e sicurezza che Cornetta possa usare microfono e audio di sistema.")
            return
        }
        self.recorder = recorder
        unsaved.insert(url)
        microphoneName = recorder.microphoneName
        if !micAllowed {
            message = "Microfono non autorizzato: registro solo l'audio della chiamata."
        } else if recorder.microphoneName == nil {
            message = "Nessun microfono trovato: registro solo l'audio della chiamata."
        }
        isRecording = true
        // Avviata da menu o ⌘R: allo stop la chiamata in corso non va riproposta, solo una nuova.
        promptedApps.formUnion(callAppsSeen.keys)
        callEndedSuggestion = false
        startedAt = Date()
        elapsed = 0
        lastCallAppSeenAt = callAppsSeen.isEmpty ? nil : Date()
        systemPeak = 0
        noAudioWarned = false
        noOthersWarned = false
        othersWarnedAt = nil
        lastSoundAt = Date()
        nextDiskCheck = .distantPast
        lowDiskWarned = false
        longRecordingWarned = false
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshOverlay()
    }

    func stop() {
        guard let recorder else { return }
        let stats = recorder.stop()
        Diagnostics.log(String(format: "Stop: %.2f s scritti, %.2f s dall'avvio, riavvii %d, reset per zeri %d, guadagno voce %.1f",
                               stats.seconds, Date().timeIntervalSince(startedAt ?? Date()), recorder.restartCount,
                               recorder.zeroResets, recorder.meter.micGain))
        finish()
        message = "Salvo la registrazione…"
    }

    /// All'uscita dall'app: chiude i file senza convertire. Il prossimo avvio recupera la registrazione.
    func stopForTermination() {
        guard let recorder else { return }
        recorder.stopForTermination()
        Diagnostics.log("Uscita durante una registrazione: la recupero al prossimo avvio")
        finish()
        saved(recorder.outputURL, showNotices: false)
    }

    /// Ferma e salva senza che l'utente l'abbia chiesto. L'avviso parte da `onFinalized`, a conversione
    /// finita: con il disco quasi pieno la conversione può fallire, e «salvata» sarebbe falso.
    private func stopAndTell(_ reason: String) {
        guard let url = recorder?.outputURL else { return }
        stopReasons[url] = reason
        stop()
    }

    /// Avviso dello stop automatico, che resta finché non si chiude.
    private func showStoppedNotice(_ reason: String, converted: Bool) {
        if converted {
            showNotice(kind: "stopped", NoticeView(
                icon: "stop.circle.fill", tint: .orange,
                title: "Registrazione fermata e salvata",
                message: reason,
                primary: "Apri", secondary: "Chiudi",
                onPrimary: { [weak self] in self?.closeNotice(); LibraryWindow.show() },
                onSecondary: { [weak self] in self?.closeNotice() }))
        } else {
            showNotice(kind: "stopped", NoticeView(
                icon: "exclamationmark.triangle.fill", tint: .orange,
                title: "Registrazione fermata, non ancora salvata",
                message: reason + " La conversione non è riuscita, ma l'audio è al sicuro: Cornetta lo recupera al prossimo avvio. Se il disco è pieno, prima libera spazio.",
                primary: "Chiudi", secondary: "Invia un feedback",
                onPrimary: { [weak self] in self?.closeNotice() },
                onSecondary: { [weak self] in self?.closeNotice(); self?.openFeedback() }))
        }
    }

    private func stopForSleep() {
        guard recorder != nil else { return }
        Diagnostics.log("Il Mac va in stop durante una registrazione: la fermo e la salvo")
        stopAndTell("Il Mac è andato in stop durante la registrazione. Quello che era registrato è salvato.")
    }

    var hasUnsavedWork: Bool { !unsaved.isEmpty }

    /// Esegue `action` quando nessuna registrazione è in corso o in conversione (subito, se è già così).
    /// Con `timeout` parte comunque dopo quei secondi, una volta sola.
    func whenSaved(timeout: TimeInterval? = nil, _ action: @escaping () -> Void) {
        guard hasUnsavedWork else { action(); return }
        let once = Once(action)
        savedWaiters.append(once.run)
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.run() }
        }
    }

    private func saved(_ url: URL, showNotices: Bool = true) {
        unsaved.remove(url)
        guard unsaved.isEmpty else { return }
        let waiters = savedWaiters
        savedWaiters = []
        waiters.forEach { $0() }
        if showNotices { showPendingNotices() }
    }

    func noteRecovered(_ name: String) {
        message = "Recuperata una registrazione interrotta: \(name)"
    }

    /// Recupero abbandonato dopo tre tentativi: l'audio grezzo è in ~/Music/Cornetta. L'avviso aspetta
    /// come gli altri rimandati: mai in chiamata.
    func noteRecoveryFailed(_ folder: URL) {
        message = "Registrazione interrotta non recuperata: l'audio è in Musica › Cornetta › \(folder.lastPathComponent)"
        pendingRecoveryFailures.append(folder)
        showPendingNotices()
    }

    private func showRecoveryFailedNotice(_ folder: URL) {
        showNotice(kind: "recovery", NoticeView(
            icon: "exclamationmark.triangle.fill", tint: .orange,
            title: "Registrazione non recuperata",
            message: "Cornetta non riesce a convertire una registrazione interrotta. L'audio grezzo è in Musica › Cornetta › \(folder.lastPathComponent) e si apre con QuickTime.",
            primary: "Mostra nel Finder", secondary: "Chiudi",
            onPrimary: { [weak self] in self?.closeNotice(); NSWorkspace.shared.activateFileViewerSelecting([folder]) },
            onSecondary: { [weak self] in self?.closeNotice() }))
        requeueNotice = { [weak self] in self?.pendingRecoveryFailures.insert(folder, at: 0) }
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
        if levels.mic > 0 || levels.system > 0 { lastSoundAt = Date() }
        checkAudioArrives(recorder)
        guard checkForgotten() else { return }
        checkDiskSpace(recorder)
    }

    /// Se macOS non dà l'audio (permesso negato, dispositivo bloccato), lo si dice subito, non a fine chiamata.
    /// Ogni avviso parte una volta sola; dopo «nessun audio» non serve anche quello sulla voce degli altri.
    /// La voce degli altri che sparisce a metà chiamata la segue CallRecorder (`othersSilent`).
    private func checkAudioArrives(_ recorder: CallRecorder) {
        if !noAudioWarned, elapsed > 8, recorder.callbackCount == 0 || recorder.restartCount >= 3 {
            noAudioWarned = true
            Diagnostics.log("Avviso: nessun audio in arrivo")
            showError(title: "Cornetta non riceve audio",
                      message: "macOS non sta passando l'audio a Cornetta. Controlla in Impostazioni › Privacy e sicurezza che Cornetta possa usare microfono e audio di sistema.")
        } else if !noAudioWarned, !noOthersWarned, elapsed > 25, systemPeak == 0, !callAppsSeen.isEmpty {
            noOthersWarned = true
            Diagnostics.log("Avviso: audio di sistema muto durante una chiamata")
            showError(title: "Non sento la voce degli altri",
                      message: "La chiamata è in corso ma l'audio di sistema è muto. Controlla in Impostazioni › Privacy e sicurezza › Registrazione schermo e audio di sistema che Cornetta sia attiva.")
        }
    }

    /// Voce degli altri sparita a metà chiamata (#3820): CallRecorder ha già ricreato la cattura e non riprova
    /// più finché il segnale non torna. Solo con un'app di chiamata, al massimo una volta ogni 20 minuti.
    /// Niente suono né pulsante per la privacy: le callback arrivano, quindi il permesso c'è.
    private func showOthersSilent() {
        guard isRecording, noticeKind != "error", !callAppsSeen.isEmpty else { return }
        if let last = othersWarnedAt, Date().timeIntervalSince(last) < Self.othersWarningInterval { return }
        othersWarnedAt = Date()
        Diagnostics.log("Avviso: voce degli altri sparita a metà chiamata")
        showStopOffer(kind: "others", icon: "speaker.slash.fill",
                      title: "Non sento più la voce degli altri",
                      message: "Da più di un minuto l'audio della chiamata è muto, anche dopo che Cornetta ha riprovato a prendere la voce degli altri. Se stanno parlando, ferma e riavvia la registrazione.")
    }

    /// Registrazione dimenticata: la chiamata è finita da 10 minuti e da 10 minuti non si sente niente
    /// (né tu né gli altri sopra -50 dB): si ferma e si salva da sola. Senza app di chiamata (riunione dal
    /// vivo) non si ferma mai da sola: dopo 3 ore avvisa e basta. false se ha fermato la registrazione.
    private func checkForgotten() -> Bool {
        let now = Date()
        if let lastCall = lastCallAppSeenAt, callAppsSeen.isEmpty,
           now.timeIntervalSince(lastCall) >= Self.forgottenAfter,
           now.timeIntervalSince(lastSoundAt ?? now) >= Self.forgottenAfter {
            Diagnostics.log("Chiamata finita da 10 minuti e nessun suono: fermo e salvo la registrazione")
            stopAndTell("La chiamata era finita da 10 minuti e non si sentiva più nessuno.")
            return false
        }
        if !longRecordingWarned, elapsed >= Self.longRecording, callAppsSeen.isEmpty {
            longRecordingWarned = true
            Diagnostics.log("Avviso: registrazione aperta da 3 ore senza app di chiamata")
            showStopOffer(kind: "long", icon: "clock.fill", title: "Cornetta registra da 3 ore",
                          message: "Nessuna app di chiamata è attiva. Se hai finito, ferma e salva la registrazione.")
        }
        return true
    }

    /// Spazio libero sul disco della cartella di lavoro, ogni 10 s: sotto 1 GB avvisa, sotto 200 MB ferma
    /// e salva, così resta posto per la conversione in .m4a. Conta anche lo spazio che macOS può liberare.
    private func checkDiskSpace(_ recorder: CallRecorder) {
        let now = Date()
        guard now >= nextDiskCheck else { return }
        nextDiskCheck = now.addingTimeInterval(10)
        let values = try? recorder.workingDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < Self.diskStopBytes {
            Diagnostics.log("Spazio libero \(free / 1_000_000) MB: fermo e salvo la registrazione")
            stopAndTell("Sul disco restano meno di 200 MB. Libera spazio prima di registrare di nuovo.")
        } else if free < Self.diskWarnBytes, !lowDiskWarned {
            lowDiskWarned = true
            Diagnostics.log("Avviso: spazio libero \(free / 1_000_000) MB")
            showStopOffer(kind: "disk", icon: "externaldrive.fill.badge.exclamationmark", title: "Disco quasi pieno",
                          message: "Sul disco resta meno di 1 GB. Sotto i 200 MB Cornetta ferma e salva la registrazione da sola.")
        }
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
            Telemetry.send(.registrazione, outcome: "errore", code: "interrotta", seconds: Date().timeIntervalSince(startedAt ?? Date()))
            finish()
            message = text
            showError(title: "Registrazione interrotta", message: text + " Quello che era già registrato viene salvato.")
        case .othersSilent:
            showOthersSilent()
        case .othersBack:
            if noticeKind == "others" { closeNotice() }
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
        if let noticeKind, Self.recordingNotices.contains(noticeKind) { closeNotice() }
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
            recorder?.callActive = !apps.isEmpty
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
        // Un avviso informativo rimasto a schermo (Mac in stop durante la notte) non blocca la proposta.
        guard proposeOnCall, noticeKind.map({ Self.replacedByCall.contains($0) }) ?? true else { return }
        // Avviso solo se l'app usa il microfono da almeno 4 secondi (niente falsi allarmi da dettatura).
        if let app = apps.first(where: { !promptedApps.contains($0) && now.timeIntervalSince(callAppsSeen[$0] ?? now) >= 4 }) {
            promptedApps.insert(app)
            // Aggiornamento, recupero e trascrizioni tornano in coda e ricompaiono dopo la proposta;
            // lo stop automatico no: l'esito resta nella libreria.
            if let kind = noticeKind {
                Diagnostics.log("La proposta di chiamata sostituisce l'avviso \(kind)")
                requeueNotice?()
            }
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
        showStopOffer(kind: "ended", icon: "phone.down.fill", title: "La chiamata sembra finita",
                      message: "Cornetta sta ancora registrando.") { [weak self] in self?.dismissCallEnded() }
    }

    /// Avviso durante la registrazione con «Ferma e salva» e «Continua».
    private func showStopOffer(kind: String, icon: String, title: String, message: String, onContinue: (() -> Void)? = nil) {
        showNotice(kind: kind, NoticeView(
            icon: icon, tint: .orange, title: title, message: message,
            primary: "Ferma e salva", secondary: "Continua",
            onPrimary: { [weak self] in self?.closeNotice(); self?.stop() },
            onSecondary: { [weak self] in self?.closeNotice(); onContinue?() }))
    }

    static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: - Aggiornamenti

    func announceUpdate(_ version: String) {
        // Durante una registrazione l'avviso aspetta che sia salvata: niente distrazioni in chiamata,
        // e «Aggiorna ora» non riavvia l'app a conversione in corso.
        guard !hasUnsavedWork else { pendingUpdateNotice = version; return }
        showNotice(kind: "update", NoticeView(
            icon: "arrow.down.circle.fill", tint: .blue,
            title: "Aggiornamento disponibile",
            message: "È pronta Cornetta \(version). L'installazione richiede pochi secondi e l'app si riapre da sola.",
            primary: "Aggiorna ora", secondary: "Più tardi",
            onPrimary: { [weak self] in self?.closeNotice(); UpdateManager.shared.installOrCheck() },
            onSecondary: { [weak self] in self?.closeNotice() }))
        requeueNotice = { [weak self] in self?.pendingUpdateNotice = version }
        NSSound(named: "Glass")?.play()
    }

    // MARK: - Trascrizioni

    /// Durante una registrazione o con un altro avviso aperto la trascrizione aspetta il suo turno.
    private func announceTranscript(_ recording: Library.Recording) {
        pendingTranscripts.removeAll { $0.id == recording.id }
        pendingTranscripts.append(recording)
        showPendingNotices()
    }

    /// Più trascrizioni arrivate insieme diventano un solo avviso, che le somma a quelle già mostrate.
    private func showTranscriptNotice() {
        let shown = noticeKind == "transcript" ? transcriptsInNotice : []
        let ready = shown.filter { old in !pendingTranscripts.contains { $0.id == old.id } } + pendingTranscripts
        pendingTranscripts = []
        guard let last = ready.last else { return }
        transcriptsInNotice = ready
        showNotice(kind: "transcript", NoticeView(
            icon: "text.bubble.fill", tint: Color(red: 0.11, green: 0.50, blue: 0.24),
            title: ready.count == 1 ? "Trascrizione pronta" : "\(ready.count) trascrizioni pronte",
            message: ready.count == 1
                ? "\(Library.shared.title(for: last)) è trascritta, con la tua voce e quella degli altri separate."
                : "\(ready.count) chiamate sono trascritte, con la tua voce e quella degli altri separate.",
            primary: "Apri", secondary: "Chiudi",
            onPrimary: { [weak self] in self?.closeNotice(); LibraryWindow.show(select: last.id) },
            onSecondary: { [weak self] in self?.closeNotice() }))
        requeueNotice = { [weak self] in
            guard let self else { return }
            self.pendingTranscripts = ready.filter { old in !self.pendingTranscripts.contains { $0.id == old.id } } + self.pendingTranscripts
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.noticeKind == "transcript", self?.transcriptsInNotice.last?.id == last.id { self?.closeNotice() }
        }
    }

    // MARK: - Avvisi

    /// Avvisi rimandati (aggiornamento, recuperi abbandonati, trascrizioni pronte): partono a registrazione
    /// salvata e con il posto libero, in quest'ordine.
    private func showPendingNotices() {
        guard !isRecording, !isStarting, !hasUnsavedWork else { return }
        if let version = pendingUpdateNotice, noticeKind == nil {
            pendingUpdateNotice = nil
            announceUpdate(version)
        } else if !pendingRecoveryFailures.isEmpty, noticeKind == nil {
            showRecoveryFailedNotice(pendingRecoveryFailures.removeFirst())
        } else if !pendingTranscripts.isEmpty, noticeKind == nil || noticeKind == "transcript" {
            showTranscriptNotice()
        }
    }

    private func showNotice<V: View>(kind: String, _ view: V) {
        noticePanel?.orderOut(nil)
        noticePanel = FloatingPanel(rootView: view, autosaveName: "CornettaNotice")
        noticeKind = kind
        requeueNotice = nil
        noticePanel?.show()
    }

    private func closeNotice() {
        noticePanel?.orderOut(nil)
        noticePanel = nil
        noticeKind = nil
        requeueNotice = nil
        transcriptsInNotice = []
        // Un avviso rimandato può partire ora che il posto è libero. Mezzo secondo di attesa: chi chiude
        // l'avviso per registrare ha già fatto partire start(), che lo blocca.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPendingNotices() }
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

/// Un'azione che parte una volta sola, da chi arriva prima fra l'attesa e il tetto di tempo.
@MainActor
private final class Once {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}
