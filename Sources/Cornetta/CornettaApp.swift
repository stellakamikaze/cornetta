import AppKit
import SwiftUI

struct CornettaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RecorderModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            if model.isRecording {
                Image(nsImage: Self.recordingIcon)
                Text(model.elapsedText)
            } else {
                Image(systemName: "phone")
            }
        }
    }

    /// Pallino rosso non template: il rosso resta visibile nella barra dei menu.
    private static let recordingIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "In registrazione")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

struct MenuContent: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
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
        Button("Apri cartella registrazioni") { model.openFolder() }
        if model.lastFile != nil {
            Button("Mostra l'ultima registrazione") { model.revealLastFile() }
        }
        Divider()
        Button("Esci da Cornetta") {
            model.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Chiude il file anche se l'app esce durante una registrazione.
        MainActor.assumeIsolated { RecorderModel.shared.stop() }
    }
}

extension RecorderModel {
    static let shared = RecorderModel()
}
