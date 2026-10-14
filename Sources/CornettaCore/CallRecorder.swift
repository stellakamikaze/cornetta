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
    private let writerQueue = DispatchQueue(label: "com.stellakamikaze.cornetta.writer", qos: .userInitiated)
    private var writer: TrackWriter?
    private var tap: SystemAudioTap?
    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var failed = false
    private var watchdog: Timer?
    private var lastCallbackCount = 0
    private var usesMicrophone = true
    public private(set) var restartCount = 0
    /// Livelli in tempo reale di microfono e chiamata.
    public let meter = LevelMeter()

    public init(outputURL: URL, debugDirectory: URL? = nil) {
        self.outputURL = outputURL
        self.debugDirectory = debugDirectory
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

    /// Avvia la registrazione. Va chiamato dalla coda principale.
    public func start(useMicrophone: Bool = true) throws {
        guard !isRunning else { return }
        writer = try TrackWriter(outputURL: outputURL, debugDirectory: debugDirectory, meter: meter)
        do {
            tap = try SystemAudioTap()
            try startCapture(useMicrophone: useMicrophone)
        } catch {
            teardownCapture()
            closeWriter()
            throw error
        }
        isRunning = true
        usesMicrophone = useMicrophone
        if useMicrophone { listenForInputChanges() }
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
        return closeWriter()
    }

    // MARK: - Cattura

    private func startCapture(useMicrophone: Bool) throws {
        guard let tap else { return }
        let microphone = useMicrophone ? CoreAudio.defaultInputDevice() : nil
        let device = try AggregateDevice(tap: tap, microphone: microphone)
        aggregate = device
        microphoneName = device.micName

        diagnostics = "streams=\(device.streamChannels) leading=\(device.leadingStreamCount) mic=\(device.leadingStreamsAreMicrophone) rate=\(device.sampleRate) tapFormat=\(tap.format.map { "\($0.mSampleRate)Hz \($0.mChannelsPerFrame)ch" } ?? "?")"
        let counter = callbackCounter
        let startedAt = Date()
        Diagnostics.log("Cattura avviata: \(diagnostics)")
        let leadingStreams = device.leadingStreamCount
        let leadingIsMic = device.leadingStreamsAreMicrophone
        let sampleRate = device.sampleRate
        let queue = writerQueue

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device.deviceID, nil) { [weak self] _, inputData, _, _, _ in
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
            queue.async { self?.write(mic: mic, system: system, frameCount: frameCount, sampleRate: sampleRate) }
        }
        try check(status, "Creazione della callback audio")
        procID = newProcID
        try check(AudioDeviceStart(device.deviceID, newProcID), "Avvio della cattura audio")
    }

    private func teardownCapture() {
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.deviceID, procID)
            AudioDeviceDestroyIOProcID(aggregate.deviceID, procID)
        }
        procID = nil
        aggregate?.destroy()
        aggregate = nil
    }

    private func write(mic: [[Float]], system: [[Float]], frameCount: Int, sampleRate: Double) {
        guard let writer, !failed else { return }
        do {
            try writer.write(mic: mic, system: system, frameCount: frameCount, sampleRate: sampleRate)
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

    // MARK: - Cambio microfono (es. AirPods collegate a metà chiamata)

    private func listenForInputChanges() {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildCapture()
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudio.system, &addr, DispatchQueue.main, block) == noErr {
            inputListener = block
        }
    }

    private func stopListening() {
        guard let inputListener else { return }
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(CoreAudio.system, &addr, DispatchQueue.main, inputListener)
        self.inputListener = nil
    }

    private func rebuildCapture(notifyMicrophone: Bool = true) {
        guard isRunning else { return }
        teardownCapture()
        do {
            try startCapture(useMicrophone: usesMicrophone)
            if notifyMicrophone { onEvent?(.microphoneChanged(microphoneName)) }
        } catch {
            let message = "Riavvio della cattura non riuscito: \(error.localizedDescription)"
            stop()
            onEvent?(.failure(message))
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
                self.rebuildCapture(notifyMicrophone: false)
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
