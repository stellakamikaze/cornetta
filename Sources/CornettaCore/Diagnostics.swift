import Foundation
import os

/// Log tecnico: va nel log di sistema e in ~/Library/Logs/Cornetta/cornetta.log.
public enum Diagnostics {
    private static let logger = Logger(subsystem: "com.stellakamikaze.cornetta", category: "cornetta")
    private static let queue = DispatchQueue(label: "com.stellakamikaze.cornetta.log")
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Cornetta/cornetta.log")

    public static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter.withFractions.string(from: Date())) \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
