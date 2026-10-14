import CornettaCore
import Foundation

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--probe"), index + 1 < CommandLine.arguments.count {
            let report = Probe.run().joined(separator: "\n") + "\n"
            try? report.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        } else if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), index + 1 < CommandLine.arguments.count {
            HeadlessTranscription.run(file: CommandLine.arguments[index + 1],
                                      tracks: CommandLine.arguments.firstIndex(of: "--tracks").map { CommandLine.arguments[$0 + 1] })
        } else if CommandLine.arguments.contains("--record") {
            HeadlessRecording.run(arguments: CommandLine.arguments)
        } else {
            CornettaApp.main()
        }
    }
}
