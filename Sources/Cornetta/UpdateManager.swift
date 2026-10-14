import AppKit
import CornettaCore
import Sparkle

/// Aggiornamenti da remoto con Sparkle. Quando c'è una versione nuova, Cornetta mostra il suo avviso
/// in primo piano (non solo la finestra di Sparkle, che in un'app della barra dei menu resterebbe nascosta).
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateManager()

    @Published private(set) var availableVersion: String?
    var onUpdateFound: ((String) -> Void)?
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Un controllo all'avvio, oltre a quelli programmati: chi apre l'app scopre subito la novità.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.controller.updater.checkForUpdatesInBackground()
        }
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// Apre la finestra di Sparkle in primo piano: novità, pulsante Installa, riavvio.
    func installOrCheck() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // Solo per le prove: defaults write com.stellakamikaze.cornetta CornettaFeedOverride <url>
        UserDefaults.standard.string(forKey: "CornettaFeedOverride")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Diagnostics.log("Aggiornamento trovato: \(version)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Diagnostics.log("Controllo aggiornamenti: \(error.localizedDescription)")
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Gli aggiornamenti trovati in background li annuncia Cornetta con il suo avviso.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            self.availableVersion = version
            if !handleShowingUpdate { self.onUpdateFound?(version) }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
