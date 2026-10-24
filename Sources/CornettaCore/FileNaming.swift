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
        uniqueURL(in: directory, baseName: "Chiamata \(formatter.string(from: date))", fileExists: fileExists)
    }

    /// Nome per una registrazione nuova. Conta come preso anche quello di una registrazione dello stesso minuto
    /// ancora in conversione («.m4a.parziale») o in attesa di recupero (cartella di lavoro in `workingRoot`):
    /// mai due registrazioni negli stessi CAF.
    public static func newRecordingURL(
        in directory: URL,
        workingRoot: URL,
        date: Date = Date(),
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        recordingURL(in: directory, date: date) { candidate in
            [candidate, candidate.appendingPathExtension("parziale"), workingDirectory(for: candidate, in: workingRoot)]
                .contains(where: fileExists)
        }
    }

    /// Cartella di lavoro di una registrazione: i CAF grezzi, con lo stesso nome del .m4a senza estensione.
    public static func workingDirectory(for recording: URL, in workingRoot: URL) -> URL {
        workingRoot.appendingPathComponent(recording.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Uno solo per tutti i nomi: la libreria ne legge la data per ogni file a ogni apertura.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    /// «<base>.m4a» nella cartella, con « (2)», « (3)» se il nome è già preso.
    public static func uniqueURL(in directory: URL, baseName: String,
                                 fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) (\(counter)).m4a")
            counter += 1
        }
        return candidate
    }

    /// Data e ora lette dal nome «Chiamata 2026-10-14 09.12» (anche con « (2)» in fondo). Nil se il nome è diverso.
    public static func date(fromFileName name: String) -> Date? {
        let pattern = #"(\d{4}-\d{2}-\d{2} \d{2}\.\d{2})"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return formatter.date(from: String(name[range]))
    }
}
