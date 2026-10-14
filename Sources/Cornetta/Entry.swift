import CornettaCore
import Foundation

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--probe"), index + 1 < CommandLine.arguments.count {
            let report = Probe.run().joined(separator: "\n") + "\n"
            try? report.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        } else if CommandLine.arguments.contains("--record") {
            HeadlessRecording.run(arguments: CommandLine.arguments)
        } else {
            CornettaApp.main()
        }
    }
}
