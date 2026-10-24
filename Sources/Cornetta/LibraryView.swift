import AppKit
import AVFoundation
import CornettaCore
import SwiftUI

/// Finestra «Registrazioni»: elenco delle chiamate e trascrizione divisa per voce.
@MainActor
enum LibraryWindow {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?
    private static var spaceMonitor: Any?

    static func show(select id: String? = nil) {
        Library.shared.reload()
        if let id { LibrarySelection.shared.selected = id }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Registrazioni"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LibraryView(library: .shared, selection: .shared))
            window.setFrameAutosaveName("CornettaLibrary")
            if window.frame.width < 700 { window.center() }
            let delegate = WindowDelegate()
            window.delegate = delegate
            self.delegate = delegate
            self.window = window
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                playPause(on: event) ? nil : event
            }
        }
        // Finché la finestra è aperta Cornetta compare nel Dock e in ⌘-Tab, come un'app normale.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Spazio = ascolta o pausa, ma solo se non si sta scrivendo: una scorciatoia sul pulsante
    /// passerebbe prima del campo di ricerca e ruberebbe lo spazio fra le parole.
    private static func playPause(on event: NSEvent) -> Bool {
        guard event.keyCode == 49, !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window, event.window === window, !(window.firstResponder is NSText),
              let id = LibrarySelection.shared.selected,
              let recording = Library.shared.recordings.first(where: { $0.id == id }) else { return false }
        AudioPlayer.shared.toggle(recording)
        return true
    }

    final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                AudioPlayer.shared.stop()
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

@MainActor
final class LibrarySelection: ObservableObject {
    static let shared = LibrarySelection()
    @Published var selected: String?
}

/// Riproduce una registrazione e dice a che punto è, per evidenziare la battuta in corso.
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()
    @Published private(set) var playingID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ recording: Library.Recording, from time: Double? = nil) {
        if playingID != recording.id {
            stop()
            player = try? AVAudioPlayer(contentsOf: recording.url)
            playingID = recording.id
        }
        guard let player else { return }
        if let time { player.currentTime = time }
        player.play()
        isPlaying = true
        currentTime = player.currentTime
        timer?.invalidate()
        // Gira solo mentre suona: in pausa o a fine file la finestra non si ridisegna più.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if abs(player.currentTime - self.currentTime) >= 0.1 { self.currentTime = player.currentTime }
                if !player.isPlaying { self.pause() }
            }
        }
    }

    func toggle(_ recording: Library.Recording) {
        if isPlaying, playingID == recording.id { pause() } else { play(recording) }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        playingID = nil
        currentTime = 0
    }
}

struct LibraryView: View {
    @ObservedObject var library: Library
    @ObservedObject var selection: LibrarySelection
    @State private var search = ""

    private var filtered: [Library.Recording] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return library.recordings }
        return library.recordings.filter { library.matches($0, query: query) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection.selected) { recording in
                RecordingRow(recording: recording, library: library, query: search)
                    .tag(recording.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Cerca nelle trascrizioni")
            .overlay {
                if library.recordings.isEmpty {
                    ContentUnavailableView("Nessuna registrazione", systemImage: "phone",
                                           description: Text("Avvia una registrazione dalla cornetta nella barra dei menu."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let id = selection.selected, let recording = library.recordings.first(where: { $0.id == id }) {
                RecordingDetail(recording: recording, library: library, player: .shared)
                    .id(recording.id)
            } else {
                ContentUnavailableView("Scegli una registrazione", systemImage: "waveform",
                                       description: Text("La trascrizione compare qui, divisa fra la tua voce e quella degli altri."))
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if selection.selected == nil { selection.selected = library.recordings.first?.id }
        }
    }
}

struct RecordingRow: View {
    let recording: Library.Recording
    @ObservedObject var library: Library
    let query: String

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE d MMM, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.capitalizedFirst(Self.dateFormatter.string(from: recording.date)))
                .font(.body.weight(.semibold))
            HStack(spacing: 6) {
                Text(TranscriptFormatter.timestamp(recording.duration)).monospacedDigit()
                Text("·")
                StatusLabel(status: library.status(recording))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Con una ricerca attiva mostra la frase che contiene la parola cercata.
    private var snippet: String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let transcript = library.transcripts[recording.id] else { return nil }
        return transcript.segments.first { $0.text.lowercased().contains(q) }.map { "\($0.speaker.label): \($0.text)" }
    }
}

struct StatusLabel: View {
    let status: Library.Status

    var body: some View {
        switch status {
        case .done: Label("Trascritta", systemImage: "text.bubble").labelStyle(.titleOnly)
        case .queued: Text("In coda")
        case .transcribing(let p, _): Text("Trascrivo \(Int(p * 100))%").monospacedDigit()
        case .failed: Text("Errore").foregroundStyle(.red)
        case .notTranscribed: Text(SpeechEngine.isAvailable ? "Da trascrivere" : "Solo audio")
        }
    }
}

struct RecordingDetail: View {
    let recording: Library.Recording
    @ObservedObject var library: Library
    @ObservedObject var player: AudioPlayer
    @State private var confirmDelete = false
    @State private var copied = false

    private var transcript: Transcript? { library.transcripts[recording.id] }
    private var playingThis: Bool { player.playingID == recording.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Eliminare questa registrazione?", isPresented: $confirmDelete) {
            Button("Sposta nel Cestino", role: .destructive) { library.delete(recording) }
        } message: {
            Text("L'audio e la trascrizione vanno nel Cestino. Puoi recuperarli da lì.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                player.toggle(recording)
            } label: {
                Image(systemName: playingThis && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(playingThis && player.isPlaying ? "Pausa" : "Ascolta")

            VStack(alignment: .leading, spacing: 2) {
                Text(library.title(for: recording)).font(.title3.weight(.semibold))
                Text(meta).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if transcript != nil {
                Button(copied ? "Copiato" : "Copia testo") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(library.markdown(for: recording) ?? "", forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("Esporta…") { export() }
            }
            Menu {
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                if transcript != nil, SpeechEngine.isAvailable, !inProgress {
                    Button("Trascrivi di nuovo") { library.enqueue(recording.url) }
                }
                Divider()
                Button("Elimina…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    /// In coda o in trascrizione: «Trascrivi di nuovo» rifarebbe lo stesso lavoro.
    private var inProgress: Bool {
        switch library.status(recording) {
        case .queued, .transcribing: return true
        default: return false
        }
    }

    private var meta: String {
        var parts = ["Durata \(TranscriptFormatter.timestamp(recording.duration))"]
        if playingThis { parts.insert(TranscriptFormatter.timestamp(player.currentTime), at: 0) }
        if transcript != nil { parts.append(recording.hasTracks ? "Tu e Altri separati" : "Voci non separate") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch library.status(recording) {
        case .done:
            if let transcript, !transcript.segments.isEmpty {
                TranscriptView(turns: library.turns(for: recording), recording: recording, player: player)
            } else {
                ContentUnavailableView("Nessuna voce riconosciuta", systemImage: "waveform.slash",
                                       description: Text("La registrazione sembra vuota o troppo bassa."))
            }
        case .transcribing(let progress, let message):
            VStack(spacing: 12) {
                ProgressView(value: progress).frame(maxWidth: 280)
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .queued:
            ContentUnavailableView("In coda", systemImage: "clock", description: Text("La trascrizione parte appena finisce quella in corso."))
        case .failed(let error):
            ContentUnavailableView {
                Label("Trascrizione non riuscita", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Riprova") { library.enqueue(recording.url) }
            }
        case .notTranscribed:
            if SpeechEngine.isAvailable {
                ContentUnavailableView {
                    Label("Non ancora trascritta", systemImage: "text.bubble")
                } description: {
                    Text(recording.hasTracks
                         ? "La trascrizione avviene sul Mac: niente esce dal computer."
                         : "Registrazione fatta prima della trascrizione: le voci non saranno separate.")
                } actions: {
                    Button("Trascrivi") { library.enqueue(recording.url) }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Trascrizione non disponibile", systemImage: "text.bubble",
                                       description: Text("La trascrizione sul Mac richiede macOS 26 o successivo. L'audio resta disponibile."))
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.url.deletingPathExtension().lastPathComponent + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? library.markdown(for: recording)?.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct TranscriptView: View {
    let turns: [Transcript.Segment]
    let recording: Library.Recording
    @ObservedObject var player: AudioPlayer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        TurnRow(turn: turn, active: isActive(index)) {
                            player.play(recording, from: turn.start)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .onChange(of: activeIndex) { _, index in
                if let index { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private var activeIndex: Int? {
        guard player.playingID == recording.id, player.isPlaying else { return nil }
        return turns.lastIndex { $0.start <= player.currentTime + 0.2 }
    }

    private func isActive(_ index: Int) -> Bool { activeIndex == index }
}

struct TurnRow: View {
    let turn: Transcript.Segment
    let active: Bool
    let onPlay: () -> Void

    private var color: Color {
        switch turn.speaker {
        case .me: return SpeakerColors.me
        case .others: return SpeakerColors.others
        case .mixed: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(action: onPlay) {
                Text(TranscriptFormatter.timestamp(turn.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Ascolta da qui")
            .accessibilityLabel("Ascolta da \(TranscriptFormatter.timestamp(turn.start))")
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.speaker.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(turn.text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Voce e testo in una lettura sola. La battuta in ascolto si vede solo dallo sfondo:
            // VoiceOver la dice «selezionata».
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(active ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Colori delle voci leggibili sul bianco e sul tema scuro (contrasto ≥ 4,5:1 per il testo piccolo).
enum SpeakerColors {
    static let me = dynamic(light: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.82, alpha: 1),
                            dark: NSColor(srgbRed: 0.45, green: 0.66, blue: 1.0, alpha: 1))
    static let others = dynamic(light: NSColor(srgbRed: 0.09, green: 0.45, blue: 0.20, alpha: 1),
                                dark: NSColor(srgbRed: 0.40, green: 0.82, blue: 0.50, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
