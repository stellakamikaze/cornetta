import CornettaCore
import Foundation

/// Telemetria di funzionamento: pochi eventi a lista chiusa verso il servizio di Cornetta, per sapere se
/// l'app funziona sui Mac di chi la usa. Mai audio, testi, nomi di file, dispositivi o contatti.
/// Si spegne dal menu («Invia dati di funzionamento»): spenta, l'id di installazione si cancella.
/// Cosa parte e cosa no lo spiega https://cornetta.stellakamikaze.org/privacy/.
enum Telemetry {
    enum Event: String {
        case avvio, registrazione, trascrizione, aggiornamento
    }

    static let enabledKey = "telemetryEnabled"
    private static let installKey = "telemetryInstallID"
    private static let lastVersionKey = "telemetryLastVersion"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { UserDefaults.standard.removeObject(forKey: installKey) }
            Diagnostics.log("Telemetria \(newValue ? "accesa" : "spenta")")
        }
    }

    /// Id casuale dell'installazione: serve a contare le installazioni attive, non dice chi sei.
    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: installKey)
        return id
    }

    /// All'avvio dell'app: «avvio», più «aggiornamento» se la versione è cambiata dall'ultima volta.
    static func appLaunched() {
        let previous = UserDefaults.standard.string(forKey: lastVersionKey)
        UserDefaults.standard.set(AppInfo.version, forKey: lastVersionKey)
        send(.avvio)
        if let previous, previous != AppInfo.version { send(.aggiornamento) }
    }

    static func send(_ event: Event, outcome: String = "", code: String = "", seconds: Double? = nil) {
        guard isEnabled, AppInfo.version != "dev" else { return }
        var payload: [String: String] = [
            "evento": event.rawValue,
            "piattaforma": "macos",
            "versione": AppInfo.version,
            "os": TelemetryFields.systemVersion(ProcessInfo.processInfo.operatingSystemVersion),
            "arch": AppInfo.arch,
            "installazione": installID,
        ]
        if !outcome.isEmpty { payload["esito"] = outcome }
        if !code.isEmpty { payload["codice"] = code }
        if let seconds { payload["durata"] = TelemetryFields.durationBucket(seconds) }
        var request = URLRequest(url: AppInfo.serviceURL.appendingPathComponent("api/t"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        // Senza rete l'evento si perde: non si ritenta e non si accumula niente sul disco.
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { Diagnostics.log("Telemetria non inviata (\(event.rawValue)): \(error?.localizedDescription ?? "HTTP \(status)")") }
        }.resume()
    }
}
