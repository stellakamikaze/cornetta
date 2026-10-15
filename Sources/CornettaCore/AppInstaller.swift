import Foundation

/// Mette un pacchetto .app al suo posto senza mai lasciare l'utente senza app.
public enum AppInstaller {
    /// Copia prima in una cartella temporanea sullo stesso disco della destinazione, poi sostituisce in un colpo solo.
    /// Se la copia fallisce a metà, la versione già installata resta dov'è.
    public static func install(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: source, to: staged)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }
}
