import AppKit
import CornettaCore

/// Se Cornetta parte dal disco di installazione, propone di spostarla in Applicazioni.
/// Da lì può aggiornarsi da sola e macOS ricorda i permessi.
@MainActor
enum AppMover {
    /// Copia sul disco di installazione o copia temporanea di macOS («traslocazione»).
    nonisolated static func isInstallerCopy(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// true se la copia in Applicazioni sta partendo: questa copia non deve proseguire l'avvio (recupero,
    /// trascrizioni), perché si chiude appena l'altra è aperta e lascerebbe il lavoro a metà.
    @discardableResult
    static func offerMoveIfNeeded() -> Bool {
        let path = Bundle.main.bundlePath
        guard isInstallerCopy(path), !path.hasPrefix("/Applications/") else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let others = otherInstances()
        let alert = NSAlert()
        alert.messageText = "Sposta Cornetta in Applicazioni"
        alert.informativeText = "Cornetta è aperta dal disco di installazione. Spostala in Applicazioni: così si aggiorna da sola e ricorda i permessi."
            + (others.isEmpty ? "" : " La Cornetta già aperta si chiude: una registrazione in corso si ferma e si salva.")
        alert.addButton(withTitle: "Sposta in Applicazioni")
        alert.addButton(withTitle: "Non ora")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let destination = URL(fileURLWithPath: "/Applications/Cornetta.app")
        // Mai un ritorno indietro silenzioso: in Applicazioni c'è già una versione più nuova di questa.
        if let installed = version(of: destination)?.short, let running = version(of: Bundle.main.bundleURL)?.short,
           installed.compare(running, options: .numeric) == .orderedDescending {
            let newer = NSAlert()
            newer.messageText = "In Applicazioni c'è già una Cornetta più recente"
            newer.informativeText = "La versione in Applicazioni è la \(installed), questa è la \(running). Apri Cornetta da Applicazioni ed espelli il disco di installazione."
            newer.runModal()
            return false
        }
        // Una Cornetta vecchia ancora aperta resterebbe in memoria sopra il pacchetto nuovo, e la copia
        // nuova le lascerebbe il posto (handOffToRunningInstance): si chiude prima di installare.
        guard closeAll(others) else {
            let busy = NSAlert()
            busy.messageText = "Non riesco a chiudere la Cornetta già aperta"
            busy.informativeText = "Chiudila dal suo menu con «Esci da Cornetta», poi apri di nuovo questa copia dal disco di installazione."
            busy.runModal()
            return false
        }
        do {
            // Dal disco di installazione si copia sempre il pacchetto originale, non la copia temporanea di macOS.
            let source = originalBundleURL() ?? Bundle.main.bundleURL
            try AppInstaller.install(source, at: destination)
            Diagnostics.log("Spostata in Applicazioni da \(source.path)")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        let alert = NSAlert()
                        alert.messageText = "Cornetta è in Applicazioni"
                        alert.informativeText = "Aprila da lì con un doppio clic. (\(error.localizedDescription))"
                        alert.runModal()
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "Non riesco a spostare Cornetta"
            failure.informativeText = "Trascina Cornetta nella cartella Applicazioni dal disco di installazione. (\(error.localizedDescription))"
            failure.runModal()
            return false
        }
    }

    /// Le altre Cornette aperte fuori dal disco di installazione.
    static func otherInstances() -> [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.processIdentifier != getpid() && !isInstallerCopy($0.bundleURL?.path ?? "")
        }
    }

    /// Chiede l'uscita come il menu Esci: applicationShouldTerminate ferma e salva una registrazione
    /// e aspetta fino a 60 s una conversione. false se dopo 70 s qualcuna è ancora aperta.
    private static func closeAll(_ apps: [NSRunningApplication]) -> Bool {
        guard !apps.isEmpty else { return true }
        Diagnostics.log("Chiudo \(apps.count) Cornetta già aperta prima dello spostamento")
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(70)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    /// Con la «traslocazione» macOS esegue una copia temporanea: cerca l'originale sui dischi montati.
    /// Solo un pacchetto della stessa versione: un disco di installazione vecchio ancora montato non conta.
    private static func originalBundleURL() -> URL? {
        guard let running = version(of: Bundle.main.bundleURL) else { return nil }
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return volumes
            .map { URL(fileURLWithPath: "/Volumes/\($0)/Cornetta.app") }
            .first { version(of: $0).map { $0 == running } ?? false }
    }

    /// Versione e build dall'Info.plist del pacchetto. Nil se il pacchetto non c'è.
    private static func version(of bundle: URL) -> (short: String, build: String)? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return (short, build)
    }
}
