import AVFoundation
import CoreAudio
import Foundation

/// Registra in un file la voce dal microfono e l'audio di sistema (la voce degli altri in chiamata).
public final class CallRecorder {
    public struct Stats: Codable, Sendable {
        public var micPeakRMS: Float = 0
        public var systemPeakRMS: Float = 0
        public var seconds: Double = 0
        public var hadMicrophone = false

        mutating func record(micRMS: Float, systemRMS: Float, frames: Int, sampleRate: Double, hasMicrophone: Bool) {
            micPeakRMS = max(micPeakRMS, micRMS)
            systemPeakRMS = max(systemPeakRMS, systemRMS)
            seconds += Double(frames) / sampleRate
            hadMicrophone = hadMicrophone || hasMicrophone
        }
    }

    public enum Event {
        case microphoneChanged(String?)
        case failure(String)
        /// L'audio degli altri resta a zero anche dopo i reset completi della cattura (#3820).
        case othersSilent
        /// L'audio degli altri è tornato dopo un `othersSilent`.
        case othersBack
    }

    /// Perché si ricostruisce la cattura. Tutti tranne microfono e watchdog ricreano anche il tap.
    enum RebuildReason: String {
        case microphone = "microfono", output = "uscita", format = "formato", zeros = "zeri", watchdog
        var recreatesTap: Bool { self != .microphone && self != .watchdog }
    }

    /// Un listener Core Audio registrato, da togliere con gli stessi dati.
    private struct Listener {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    /// Formato con cui è partita la cattura: un listener che scatta senza cambiarlo non ricostruisce.
    private struct CaptureFormat: Equatable {
        var rate: Double
        var tapRate: Double
        var tapChannels: UInt32
    }

    public let outputURL: URL
    /// Chiamato sulla coda principale.
    public var onEvent: ((Event) -> Void)?
    public private(set) var microphoneName: String?
    public private(set) var isRunning = false
    /// Descrizione tecnica del dispositivo aggregato, per la diagnosi.
    public private(set) var diagnostics: String = ""
    private let callbackCounter = Counter()
    public var callbackCount: Int { callbackCounter.value }
    /// Stato del dispositivo aggregato, per la diagnosi.
    public var deviceState: String {
        guard let aggregate else { return "nessun dispositivo" }
        let running = (try? CoreAudio.value(aggregate.deviceID, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(0))) ?? 99
        let alive = (try? CoreAudio.value(aggregate.deviceID, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 99
        return "running=\(running) alive=\(alive) proc=\(procID != nil)"
    }

    private let debugDirectory: URL?
    private let tracksDirectory: URL?
    private let writerQueue = DispatchQueue(label: "com.stellakamikaze.cornetta.writer", qos: .userInitiated)
    private var writer: TrackWriter?
    private var tap: SystemAudioTap?
    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private var systemListeners: [Listener] = []
    private var tapListener: Listener?
    private var rateListener: Listener?
    private var pendingReasons: Set<RebuildReason> = []
    private var pendingRebuild: DispatchWorkItem?
    private var captureFormat: CaptureFormat?
    private var lastRouting: AudioRouting?
    private var failed = false
    private var watchdog: Timer?
    private var lastCallbackCount = 0
    private var usesMicrophone = true
    public private(set) var restartCount = 0
    /// Reset completi per zeri dagli altri (#3820). Separato da `restartCount`, che fa partire l'avviso sul permesso.
    public private(set) var zeroResets = 0
    /// App di chiamata attiva, dalla coda principale. Senza chiamata gli zeri vanno solo nel log:
    /// in una riunione dal vivo ricreare la cattura toglierebbe pezzi all'unica voce, quella del microfono.
    public var callActive = false
    /// La serie di zeri in corso ha ricreato la cattura: solo allora log e avvisi seguono l'esito.
    private var rebuiltForZeros = false
    /// Reset per zeri scartati senza app di chiamata, dalla coda principale: limita le righe di log.
    private var idleZeroResets = 0
    private var rebuildFailures = 0
    /// Usati solo dalla coda del writer.
    private var silenceMonitor = TapSilenceMonitor()
    private var captureGap = CaptureGap()
    /// Tenuto dall'avvio alla fine della conversione (vedi `WorkingFolderLock`).
    private var folderLock: WorkingFolderLock?
    /// Livelli in tempo reale di microfono e chiamata.
    public let meter = LevelMeter()

    /// Cartella dei CAF durante la registrazione. Se l'app si chiude male, resta lì per il recupero.
    public let workingDirectory: URL
    /// Chiamato sulla coda principale quando il file .m4a definitivo è pronto (o la conversione fallisce).
    public var onFinalized: ((Result<RecordingFinalizer.Result, Error>) -> Void)?

    public init(outputURL: URL, workingDirectory: URL? = nil, debugDirectory: URL? = nil, tracksDirectory: URL? = nil) {
        self.outputURL = outputURL
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Cornetta-\(UUID().uuidString)", isDirectory: true)
        self.debugDirectory = debugDirectory
        self.tracksDirectory = tracksDirectory
    }

    deinit { stop() }

    /// Chiede il permesso del microfono. Senza permesso si registra solo l'audio di sistema.
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Fa comparire subito la richiesta di macOS per la «Registrazione audio di sistema» con una cattura
    /// di un secondo, così il primo avvio la chiede una volta e la prima chiamata vera non viene interrotta.
    public static func primeSystemAudioPermission() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { done.resume() }
                guard let tap = try? SystemAudioTap() else { return }
                defer { tap.destroy() }
                guard let device = try? AggregateDevice(tap: tap, microphone: nil) else { return }
                defer { device.destroy() }
                var proc: AudioDeviceIOProcID?
                guard AudioDeviceCreateIOProcIDWithBlock(&proc, device.deviceID, nil, { _, _, _, _, _ in }) == noErr,
                      let proc else { return }
                AudioDeviceStart(device.deviceID, proc)
                Thread.sleep(forTimeInterval: 1)
                AudioDeviceStop(device.deviceID, proc)
                AudioDeviceDestroyIOProcID(device.deviceID, proc)
            }
        }
    }

    /// Avvia la registrazione. Va chiamato dalla coda principale.
    public func start(useMicrophone: Bool = true) throws {
        guard !isRunning else { return }
        // Il lock prima dei CAF: un'altra Cornetta aperta (copia dal disco di installazione) non li prende
        // per una registrazione interrotta. Senza lock si registra lo stesso: la chiamata conta di più.
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        folderLock = WorkingFolderLock(folder: workingDirectory)
        if folderLock == nil { Diagnostics.log("Lock della cartella di lavoro non riuscito: registro lo stesso") }
        do {
            writer = try TrackWriter(workingDirectory: workingDirectory, debugDirectory: debugDirectory,
                                     withTracks: tracksDirectory != nil, meter: meter)
        } catch {
            releaseFolderLock()
            throw error
        }
        do {
            tap = try SystemAudioTap()
            try startCapture(useMicrophone: useMicrophone, reason: "avvio")
        } catch {
            teardownCapture()
            tap?.destroy()
            tap = nil
            closeWriter()
            try? FileManager.default.removeItem(at: workingDirectory)
            releaseFolderLock()
            throw error
        }
        isRunning = true
        usesMicrophone = useMicrophone
        listenForChanges()
        startWatchdog()
    }

    /// Ferma la registrazione e chiude il file. Restituisce le statistiche della sessione.
    @discardableResult
    public func stop() -> Stats {
        guard isRunning else { return Stats() }
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        stopListening()
        teardownCapture()
        tap?.destroy()
        tap = nil
        let stats = closeWriter()
        finalize()
        return stats
    }

    /// Ferma senza convertire: i CAF restano nella cartella di lavoro e li recupera il prossimo avvio.
    /// Serve quando l'app sta per chiudersi e non c'è tempo per la conversione.
    public func stopForTermination() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate()
        stopListening()
        teardownCapture()
        tap?.destroy()
        tap = nil
        closeWriter()
        // I CAF sono chiusi: da qui la cartella è di chi la recupera.
        releaseFolderLock()
    }

    private func releaseFolderLock() {
        folderLock?.release()
        folderLock = nil
    }

    private func finalize() {
        // Il callback si tiene forte: chi ha avviato la registrazione può già aver rilasciato il registratore.
        // Il lock resta fino a conversione finita: un'altra Cornetta non converte la stessa cartella in parallelo.
        let working = workingDirectory, output = outputURL, tracks = tracksDirectory, callback = onFinalized
        let lock = folderLock
        folderLock = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RecordingFinalizer.finalize(workingDirectory: working, output: output, tracksDirectory: tracks) }
            lock?.release()
            if case .failure(let error) = result { Diagnostics.log("Conversione non riuscita: \(error.localizedDescription)") }
            DispatchQueue.main.async { callback?(result) }
        }
    }

    // MARK: - Cattura

    private func startCapture(useMicrophone: Bool, reason: String) throws {
        // Un reset completo può aver perso il tap: la ricostruzione deve risultare fallita, non riuscita a vuoto.
        guard let tap else { throw CoreAudioError("Accesso all'audio di sistema", kAudioHardwareBadObjectError) }
        let microphone = useMicrophone ? CoreAudio.defaultInputDevice() : nil
        let device = try AggregateDevice(tap: tap, microphone: microphone)
        aggregate = device
        microphoneName = device.micName

        let tapFormat = tap.format
        captureFormat = CaptureFormat(rate: device.sampleRate, tapRate: tapFormat?.mSampleRate ?? 0,
                                      tapChannels: tapFormat?.mChannelsPerFrame ?? 0)
        diagnostics = "streams=\(device.streamChannels) leading=\(device.leadingStreamCount) mic=\(device.leadingStreamsAreMicrophone) rate=\(device.sampleRate) tapFormat=\(tapFormat.map { "\($0.mSampleRate)Hz \($0.mChannelsPerFrame)ch" } ?? "?")"
        let counter = callbackCounter
        let startedAt = Date()
        // Uscite e processi solo se cambiati: il feedback allega le ultime 120 righe del log.
        let routing = AudioRouting.current()
        Diagnostics.log("Cattura avviata (\(reason)\(routing == lastRouting ? ", uscite invariate" : "")): \(diagnostics)")
        if routing != lastRouting { routing.logLines.forEach(Diagnostics.log) }
        lastRouting = routing
        rateListener = listen(device.deviceID, kAudioDevicePropertyNominalSampleRate) { $0.formatMaybeChanged() }
        let leadingStreams = device.leadingStreamCount
        let leadingIsMic = device.leadingStreamsAreMicrophone
        let sampleRate = device.sampleRate
        let queue = writerQueue

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device.deviceID, nil) { [weak self] _, inputData, inputTime, _, _ in
            if counter.increment() == 1 {
                Diagnostics.log(String(format: "Primo blocco audio dopo %.3f s", Date().timeIntervalSince(startedAt)))
            }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            var mic: [[Float]] = []
            var system: [[Float]] = []
            var frameCount = 0
            for (index, buffer) in buffers.enumerated() {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let raw = buffer.mData else { continue }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                frameCount = max(frameCount, frames)
                let samples = raw.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    var data = [Float](repeating: 0, count: frames)
                    for frame in 0..<frames { data[frame] = samples[frame * channels + channel] }
                    if index >= leadingStreams { system.append(data) } else if leadingIsMic { mic.append(data) }
                }
            }
            guard frameCount > 0 else { return }
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : 0
            queue.async { self?.write(mic: mic, system: system, frameCount: frameCount, sampleRate: sampleRate, hostTime: hostTime) }
        }
        try check(status, "Creazione della callback audio")
        procID = newProcID
        try check(AudioDeviceStart(device.deviceID, newProcID), "Avvio della cattura audio")
    }

    private func teardownCapture() {
        remove(rateListener)
        rateListener = nil
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.deviceID, procID)
            AudioDeviceDestroyIOProcID(aggregate.deviceID, procID)
        }
        procID = nil
        aggregate?.destroy()
        aggregate = nil
    }

    private func write(mic: [[Float]], system: [[Float]], frameCount: Int, sampleRate: Double, hostTime: UInt64) {
        guard let writer, !failed, sampleRate > 0 else { return }
        let duration = Double(frameCount) / sampleRate
        let start = hostTime == 0 ? nil : Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
        let silence = captureGap.silenceBefore(start: start, duration: duration)
        do {
            if silence > 0 {
                try writer.writeSilence(seconds: silence, sampleRate: sampleRate)
                Diagnostics.log(String(format: "Buco di %.2f s nella ricostruzione: scritto come silenzio", silence))
            }
            try writer.write(mic: mic, system: system, frameCount: frameCount, sampleRate: sampleRate)
            if !system.isEmpty,
               let outcome = silenceMonitor.record(allZero: TapSilenceMonitor.isDigitalSilence(system), seconds: duration) {
                DispatchQueue.main.async { [weak self] in self?.handleSilence(outcome) }
            }
        } catch {
            failed = true
            let message = "Errore di scrittura: \(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.onEvent?(.failure(message))
            }
        }
    }

    @discardableResult
    private func closeWriter() -> Stats {
        writerQueue.sync {
            let stats = writer?.stats ?? Stats()
            writer?.close()
            writer = nil
            return stats
        }
    }

    // MARK: - Cambi di dispositivo e formato (es. AirPods collegate a metà chiamata)

    private func listenForChanges() {
        if usesMicrophone, let listener = listen(CoreAudio.system, kAudioHardwarePropertyDefaultInputDevice, { $0.scheduleRebuild(.microphone) }) {
            systemListeners.append(listener)
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            if let listener = listen(CoreAudio.system, selector, { $0.scheduleRebuild(.output) }) { systemListeners.append(listener) }
        }
        listenToTap()
    }

    private func listenToTap() {
        guard let tap else { return }
        tapListener = listen(tap.tapID, kAudioTapPropertyFormat) { $0.formatMaybeChanged() }
    }

    private func stopListening() {
        for listener in systemListeners { remove(listener) }
        systemListeners = []
        remove(tapListener)
        tapListener = nil
        pendingRebuild?.cancel()
        pendingRebuild = nil
        pendingReasons = []
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ action: @escaping (CallRecorder) -> Void) -> Listener? {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if let self { action(self) }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr else { return nil }
        return Listener(object: object, selector: selector, block: block)
    }

    private func remove(_ listener: Listener?) {
        guard let listener else { return }
        var addr = address(listener.selector)
        AudioObjectRemovePropertyListenerBlock(listener.object, &addr, DispatchQueue.main, listener.block)
    }

    private func formatMaybeChanged() {
        guard isRunning, let tap, let aggregate else { return }
        let format = tap.format
        let current = CaptureFormat(rate: aggregate.sampleRate, tapRate: format?.mSampleRate ?? 0,
                                    tapChannels: format?.mChannelsPerFrame ?? 0)
        if current != captureFormat { scheduleRebuild(.format) }
    }

    /// Con le cuffie Bluetooth ingresso e uscita cambiano insieme: un solo debounce, una sola ricostruzione.
    private func scheduleRebuild(_ reason: RebuildReason) {
        guard isRunning else { return }
        pendingReasons.insert(reason)
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildCapture([]) }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuildCapture(_ reasons: Set<RebuildReason>) {
        guard isRunning else { return }
        let reasons = reasons.union(pendingReasons)
        pendingReasons = []
        pendingRebuild?.cancel()
        pendingRebuild = nil
        teardownCapture()
        // Dopo lo stop non arrivano più blocchi vecchi: il primo blocco nuovo misura il buco.
        writerQueue.async { [weak self] in self?.captureGap.markRebuild() }
        do {
            if tap == nil || reasons.contains(where: \.recreatesTap) { try recreateTap() }
            try startCapture(useMicrophone: usesMicrophone, reason: reasons.map(\.rawValue).sorted().joined(separator: "+"))
            rebuildFailures = 0
            if reasons.contains(.microphone) { onEvent?(.microphoneChanged(microphoneName)) }
        } catch {
            // Core Audio in transizione (cuffie scollegate, risveglio): non si ferma, riprova il watchdog.
            rebuildFailures += 1
            Diagnostics.log("Ricostruzione della cattura non riuscita (\(rebuildFailures)): \(error.localizedDescription)")
            if rebuildFailures >= 15 {
                let message = "Il dispositivo audio non risponde da 30 secondi: registrazione fermata e salvata."
                stop()
                onEvent?(.failure(message))
            }
        }
    }

    /// Un tap bloccato nell'HAL si cura solo distruggendolo e ricreandolo (forum Apple 825780).
    private func recreateTap() throws {
        remove(tapListener)
        tapListener = nil
        tap?.destroy()
        tap = nil
        tap = try SystemAudioTap()
        listenToTap()
    }

    // MARK: - Zeri dagli altri (#3820)

    private func handleSilence(_ outcome: TapSilenceMonitor.Outcome) {
        guard isRunning else { return }
        switch outcome {
        case .reset(let count, let seconds):
            guard callActive else {
                // La serie riparte da capo: una chiamata che parte ora trova la prima soglia (20 s) e l'avviso.
                writerQueue.async { [weak self] in self?.silenceMonitor.restartSeries() }
                // Un reset scartato ogni 20 s di zeri: nel log il primo e poi uno ogni 5 minuti.
                idleZeroResets += 1
                if idleZeroResets == 1 || idleZeroResets % 15 == 0 {
                    Diagnostics.log("Audio di sistema a zero da \(Int(seconds)) s senza app di chiamata: non ricreo la cattura (\(idleZeroResets))")
                }
                return
            }
            idleZeroResets = 0
            zeroResets += 1
            rebuiltForZeros = true
            Diagnostics.log("Audio degli altri a zero da \(Int(seconds)) s: ricreo tap e dispositivo (\(count))")
            rebuildCapture([.zeros])
        case .stillSilent(let count, let warn):
            guard rebuiltForZeros else { return }
            Diagnostics.log("Audio degli altri ancora a zero \(Int(TapSilenceMonitor.checkDelay)) s dopo il reset (\(count))")
            if warn { onEvent?(.othersSilent) }
        case .back(let seconds, let warn):
            guard rebuiltForZeros else { return }
            rebuiltForZeros = false
            Diagnostics.log(String(format: "Audio degli altri tornato %.1f s dopo il reset", seconds))
            if warn { onEvent?(.othersBack) }
        }
    }

    // MARK: - Watchdog
    // Se l'audio smette di arrivare (es. permesso concesso a cattura già avviata), ricrea il dispositivo.

    private func startWatchdog() {
        lastCallbackCount = callbackCount
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let current = self.callbackCount
            if current == self.lastCallbackCount {
                self.restartCount += 1
                Diagnostics.log("Nessun audio da 2 s: riavvio la cattura (\(self.restartCount))")
                self.rebuildCapture([.watchdog])
            }
            self.lastCallbackCount = self.callbackCount
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

/// Contatore condiviso fra il thread audio e il resto dell'app.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

/// Livelli correnti per gli indicatori dell'interfaccia (aggiornati dal writer, letti dalla UI).
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    private var gain: Float = 1

    public init() {}

    func update(mic: Float, system: Float, micGain: Float) {
        lock.withLock {
            // Discesa lenta: l'indicatore non sfarfalla.
            micLevel = max(mic, micLevel * 0.85)
            systemLevel = max(system, systemLevel * 0.85)
            gain = micGain
        }
    }

    /// Livelli 0...1 su scala in dB (da -50 dB a 0 dB).
    public var levels: (mic: Float, system: Float) {
        lock.withLock { (Self.scale(micLevel), Self.scale(systemLevel)) }
    }

    public var micGain: Float { lock.withLock { gain } }

    static func scale(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 50) / 50, 0), 1)
    }
}
