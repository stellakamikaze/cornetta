import Foundation
import Testing
@testable import CornettaCore

/// I campi della telemetria devono stare nelle forme che il servizio accetta (worker/src/index.js).
struct TelemetryFieldsTests {
    @Test func durationsAreBroadBuckets() {
        #expect(TelemetryFields.durationBucket(12) == "<1m")
        #expect(TelemetryFields.durationBucket(60) == "1-5m")
        #expect(TelemetryFields.durationBucket(899) == "5-15m")
        #expect(TelemetryFields.durationBucket(1800) == "15-60m")
        #expect(TelemetryFields.durationBucket(7200) == ">60m")
    }

    @Test func errorCodeKeepsOnlyDomainAndCode() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -10868,
                            userInfo: [NSLocalizedDescriptionKey: "Impossibile aprire /Users/mario/Music/Chiamata con Anna.m4a"])
        let code = TelemetryFields.errorCode(error, prefix: "salvataggio")
        #expect(code == "salvataggio.NSOSStatusErrorDomain_-10868")
        #expect(!code.contains("mario"))
        #expect(code.range(of: "^[A-Za-z0-9_.-]{0,60}$", options: .regularExpression) != nil)
    }

    @Test func errorCodeIsCleanedAndCut() {
        let error = NSError(domain: "dominio con spazi/e:simboli" + String(repeating: "x", count: 80), code: 7)
        let code = TelemetryFields.errorCode(error)
        #expect(code.count <= 60)
        #expect(code.range(of: "^[A-Za-z0-9_.-]{0,60}$", options: .regularExpression) != nil)
    }

    @Test func systemVersionIsShort() {
        #expect(TelemetryFields.systemVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 1)) == "macOS 26.3.1")
        #expect(TelemetryFields.systemVersion(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) == "macOS 15.0")
    }
}
