import Foundation

/// Cartella e nome dei file registrati.
public enum FileNaming {
    /// ~/Music/Cornetta
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Cornetta", isDirectory: true)
    }

    /// «Chiamata 2026-10-14 09.12.m4a». Se il file esiste aggiunge « (2)», « (3)» e così via.
    public static func recordingURL(
        in directory: URL,
        date: Date = Date(),
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "Chiamata \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent("\(base).m4a")
        var counter = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).m4a")
            counter += 1
        }
        return candidate
    }
}
