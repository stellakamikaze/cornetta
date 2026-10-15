import AppKit
import CornettaCore
import SwiftUI

struct CornettaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RecorderModel.shared
    @StateObject private var updates = UpdateManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updates: updates)
        } label: {
            if model.isRecording {
                Image(nsImage: Self.recordingIcon)
                Text(model.elapsedText)
            } else if updates.availableVersion != nil {
                Image(systemName: "phone.arrow.down.left")
                Image(nsImage: Self.updateBadge)
            } else {
                Image(systemName: "phone")
            }
        }
    }

    /// Pallino rosso non template: il rosso resta visibile nella barra dei menu.
    private static let recordingIcon = coloredSymbol("record.circle.fill", .systemRed, "In registrazione")
    private static let updateBadge = coloredSymbol("arrow.down.circle.fill", .systemBlue, "Aggiornamento disponibile")

    private static func coloredSymbol(_ name: String, _ color: NSColor, _ label: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

struct MenuContent: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var updates: UpdateManager

    var body: some View {
        if let version = updates.availableVersion {
            Button("Installa l'aggiornamento a Cornetta \(version)…") { updates.installOrCheck() }
            Divider()
        }
        Button(model.isRecording ? "Ferma registrazione" : "Avvia registrazione") { model.toggle() }
            .keyboardShortcut("r")
        if model.isRecording {
            Text("In registrazione · \(model.elapsedText)")
            Text("Microfono: \(model.microphoneName ?? "nessuno")")
        }
        if let message = model.message {
            Text(message)
        }
        if model.message?.hasPrefix("Microfono non autorizzato") == true {
            Button("Apri le impostazioni del microfono…") { model.openMicrophoneSettings() }
        }
        Divider()
        Button("Registrazioni e trascrizioni…") { LibraryWindow.show() }
            .keyboardShortcut("t")
        Button("Apri cartella registrazioni") { model.openFolder() }
        if model.lastFile != nil {
            Button("Mostra l'ultima registrazione") { model.revealLastFile() }
        }
        Divider()
        Button("Invia un feedback…") { model.openFeedback() }
        Toggle("Mostra il pannello durante la registrazione", isOn: $model.showOverlay)
        Toggle("Proponi di registrare quando inizia una chiamata", isOn: $model.proposeOnCall)
        if SpeechEngine.isAvailable {
            Toggle("Trascrivi ogni chiamata sul Mac", isOn: Library.shared.$autoTranscribe)
        }
        Toggle("Invia dati di funzionamento", isOn: Binding(get: { Telemetry.isEnabled }, set: { Telemetry.isEnabled = $0 }))
        Toggle("Apri all'accensione del Mac", isOn: Binding(get: { LaunchAtLogin.isEnabled }, set: { LaunchAtLogin.set($0) }))
        Button("Controlla aggiornamenti…") { updates.installOrCheck() }
        Divider()
        Text("Cornetta \(AppInfo.version)")
        Button("Esci da Cornetta") {
            model.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("Avvio Cornetta \(AppInfo.version) da \(Bundle.main.bundlePath)")
        MainActor.assumeIsolated {
            if let index = CommandLine.arguments.firstIndex(of: "--demo-library"), index + 1 < CommandLine.arguments.count {
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                Library.shared.useDemoFolders(recordings: root.appendingPathComponent("Registrazioni"),
                                              support: root.appendingPathComponent("Supporto"))
                // Dopo l'avvio di SwiftUI: aperta prima, la finestra non arriva sullo schermo.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { LibraryWindow.show() }
                return
            }
            if CommandLine.arguments.contains("--demo") {
                RecorderModel.shared.showDemo()
                return
            }
            AppMover.offerMoveIfNeeded()
            Telemetry.appLaunched()
            _ = RecorderModel.shared
            Library.shared.reload()
            Library.shared.resumePendingTranscriptions()
            Library.shared.recoverInterruptedRecordings { name in
                RecorderModel.shared.noteRecovered(name)
            }
            if WelcomeWindow.shouldShow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WelcomeWindow.show() }
            }
        }
    }

    /// Doppio clic sull'app già aperta: mostra la finestra Registrazioni invece di non fare niente.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { LibraryWindow.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Chiude il file anche se l'app esce durante una registrazione.
        MainActor.assumeIsolated { RecorderModel.shared.stopForTermination() }
    }
}
