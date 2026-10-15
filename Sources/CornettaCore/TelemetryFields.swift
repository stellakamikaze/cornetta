import Foundation

/// Campi della telemetria di funzionamento, ridotti a valori che non dicono niente di chi usa l'app.
/// Il servizio rifiuta tutto ciò che sta fuori da queste forme (worker/src/index.js, validateTelemetry).
public enum TelemetryFields {
    /// La durata di una registrazione in fasce larghe, mai al secondo.
    public static func durationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<300: return "1-5m"
        case ..<900: return "5-15m"
        case ..<3600: return "15-60m"
        default: return ">60m"
        }
    }

    /// Un errore ridotto a dominio e codice (es. «NSOSStatusErrorDomain_-10868»): il messaggio può contenere
    /// percorsi o nomi, e non parte mai.
    public static func errorCode(_ error: Error, prefix: String = "") -> String {
        let ns = error as NSError
        let raw = (prefix.isEmpty ? "" : prefix + ".") + ns.domain + "_" + String(ns.code)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return String(raw.filter { allowed.contains($0) }.prefix(60))
    }

    /// Versione del sistema nella forma «macOS 26.3.1».
    public static func systemVersion(_ v: OperatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}
