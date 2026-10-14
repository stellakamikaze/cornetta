import AppKit
import CornettaCore

/// Se Cornetta parte dal disco di installazione, propone di spostarla in Applicazioni.
/// Da lì può aggiornarsi da sola e macOS ricorda i permessi.
@MainActor
enum AppMover {
    static func offerMoveIfNeeded() {
        let path = Bundle.main.bundlePath
        let fromInstaller = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
        guard fromInstaller, !path.hasPrefix("/Applications/") else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sposta Cornetta in Applicazioni"
        alert.informativeText = "Cornetta è aperta dal disco di installazione. Spostala in Applicazioni: così si aggiorna da sola e ricorda i permessi."
        alert.addButton(withTitle: "Sposta in Applicazioni")
        alert.addButton(withTitle: "Non ora")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications/Cornetta.app")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            // Dal disco di installazione si copia sempre il pacchetto originale, non la copia temporanea di macOS.
            let source = originalBundleURL() ?? Bundle.main.bundleURL
            try FileManager.default.copyItem(at: source, to: destination)
            Diagnostics.log("Spostata in Applicazioni da \(source.path)")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Non riesco a spostare Cornetta"
            failure.informativeText = "Trascina Cornetta nella cartella Applicazioni dal disco di installazione. (\(error.localizedDescription))"
            failure.runModal()
        }
    }

    /// Con la «traslocazione» macOS esegue una copia temporanea: cerca l'originale sui dischi montati.
    private static func originalBundleURL() -> URL? {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for volume in volumes {
            let candidate = URL(fileURLWithPath: "/Volumes/\(volume)/Cornetta.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
