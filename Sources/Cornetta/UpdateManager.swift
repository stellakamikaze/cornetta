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
    private var raiseTimer: Timer?

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
        keepSparkleWindowsInFront()
    }

    /// Un'app della barra dei menu non diventa attiva dal clic su un pannello: macOS lascia le finestre
    /// di Sparkle dietro le altre app e chi ha premuto «Aggiorna ora» non vede niente. Le porta davanti
    /// per tutta la sessione di aggiornamento (novità, scaricamento, «Installa e Riavvia»).
    private func keepSparkleWindowsInFront() {
        raiseTimer?.invalidate()
        let sparkle = Bundle(for: SPUUpdater.self)
        var raised = Set<ObjectIdentifier>()
        raiseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    guard let owner = window.windowController, Bundle(for: type(of: owner)) == sparkle else { continue }
                    guard raised.insert(ObjectIdentifier(window)).inserted else { continue }
                    window.level = .floating
                    window.orderFrontRegardless()
                    window.makeKey()
                }
            }
        }
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

    /// «Installa e riavvia» durante una registrazione o una conversione: il riavvio aspetta che sia salvata.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            let model = RecorderModel.shared
            guard model.hasUnsavedWork else { return false }
            Diagnostics.log("Aggiornamento rimandato: c'è una registrazione da finire o da salvare")
            model.whenSaved(installHandler)
            return true
        }
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
        Task { @MainActor in
            self.availableVersion = nil
            self.raiseTimer?.invalidate()
            self.raiseTimer = nil
        }
    }
}
