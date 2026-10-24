import Foundation
import Testing
@testable import CornettaCore

/// Guasto #3820: callback regolari, audio degli altri fatto di zeri esatti.
struct TapSilenceMonitorTests {
    let block = 0.01

    /// Manda `seconds` di blocchi tutti uguali e raccoglie gli esiti.
    func feed(_ monitor: inout TapSilenceMonitor, zero: Bool, seconds: Double) -> [TapSilenceMonitor.Outcome] {
        (0..<Int((seconds / block).rounded())).compactMap { _ in monitor.record(allZero: zero, seconds: block) }
    }

    /// Prima del primo suono gli zeri non contano: può non esserci nessuna chiamata.
    @Test func zerosBeforeAnySignalNeverReset() {
        var monitor = TapSilenceMonitor()
        #expect(feed(&monitor, zero: true, seconds: 400).isEmpty)
    }

    /// Le pause di Firefox (fino a 7 s di zeri esatti) non ricreano niente.
    @Test func firefoxPausesAreIgnored() {
        var monitor = TapSilenceMonitor()
        for _ in 0..<20 {
            #expect(feed(&monitor, zero: false, seconds: 2).isEmpty)
            #expect(feed(&monitor, zero: true, seconds: 7).isEmpty)
        }
    }

    /// Primo reset a 20 s, secondo dopo altri 40; poi uno ogni 5 minuti finché il segnale non torna.
    @Test func resetsSlowDownAfterTheSecond() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 2)
        var resetsAt: [Double] = []
        var elapsed = 0.0
        for _ in 0..<Int(1510 / block) {
            elapsed += block
            if case .reset = monitor.record(allZero: true, seconds: block) { resetsAt.append(elapsed.rounded()) }
        }
        #expect(resetsAt == [20, 60, 360, 660, 960, 1260])
        #expect(monitor.threshold == TapSilenceMonitor.slowRetry)
    }

    /// Il segnale che torna azzera soglia e contatore.
    @Test func signalResetsThresholdAndCounter() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 2)
        _ = feed(&monitor, zero: true, seconds: 61)
        #expect(monitor.resets == 2)
        _ = feed(&monitor, zero: false, seconds: 2)
        #expect(monitor.resets == 0)
        #expect(monitor.threshold == TapSilenceMonitor.firstThreshold)
        #expect(monitor.zeroSeconds == 0)
        let again = feed(&monitor, zero: true, seconds: 20)
        #expect(again.count == 1)
        guard case .reset(let count, _)? = again.first else {
            Issue.record("dopo il segnale la prima soglia torna a 20 s")
            return
        }
        #expect(count == 1)
    }

    /// Dopo ogni reset il log dice se il segnale torna entro 10 s; l'avviso parte solo dal secondo reset.
    @Test func warningOnlyAfterTwoResetsAndOnce() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 2)
        // Margine di 1 s sugli istanti esatti: la somma dei blocchi non è esatta.
        let first = feed(&monitor, zero: true, seconds: 31)
        #expect(first.count == 2)
        #expect(first.last == .stillSilent(count: 1, warn: false))
        let second = feed(&monitor, zero: true, seconds: 40)
        #expect(second.count == 2)
        #expect(second.last == .stillSilent(count: 2, warn: true))
        // Il tentativo lento non ripete l'avviso.
        let slow = feed(&monitor, zero: true, seconds: 300)
        #expect(slow.count == 2)
        guard case .reset(3, _)? = slow.first else {
            Issue.record("dopo il secondo reset manca il tentativo lento")
            return
        }
        #expect(slow.last == .stillSilent(count: 3, warn: false))
        guard case .back(_, let warn)? = feed(&monitor, zero: false, seconds: 2).first else {
            Issue.record("il segnale tornato non è segnalato")
            return
        }
        #expect(warn)
    }

    /// Una notifica breve fra gli zeri non arma il controllo e non chiude una serie.
    @Test func shortSignalInsideZerosKeepsTheSeries() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 0.5)
        #expect(feed(&monitor, zero: true, seconds: 40).isEmpty)
        _ = feed(&monitor, zero: false, seconds: 2)
        _ = feed(&monitor, zero: true, seconds: 31)
        #expect(monitor.resets == 1)
        #expect(feed(&monitor, zero: false, seconds: 0.5).isEmpty)
        #expect(monitor.resets == 1)
        // Gli 11 s di zeri dopo il reset restano: il secondo reset arriva dopo altri 29 s, non 20.
        let rest = feed(&monitor, zero: true, seconds: 30)
        #expect(rest.count == 1)
        guard case .reset(let count, _)? = rest.first else {
            Issue.record("la serie è ripartita da capo dopo la notifica")
            return
        }
        #expect(count == 2)
    }

    /// Reset scartato senza app di chiamata: la serie riparte da capo. Una chiamata che parte dopo un minuto
    /// di zeri trova la prima soglia (20 s), non quella lenta (300 s), e nessun controllo pendente.
    @Test func restartSeriesAfterDiscardedReset() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 2)
        let first = feed(&monitor, zero: true, seconds: 20.5)
        guard case .reset(1, _)? = first.first, first.count == 1 else {
            Issue.record("manca il primo reset a 20 s")
            return
        }
        monitor.restartSeries()
        #expect(monitor.resets == 0)
        #expect(monitor.threshold == TapSilenceMonitor.firstThreshold)
        let again = feed(&monitor, zero: true, seconds: 20)
        #expect(again.count == 1)
        guard case .reset(let count, _)? = again.first else {
            Issue.record("dopo restartSeries la serie non riparte dalla prima soglia")
            return
        }
        #expect(count == 1)
        // Dopo tre reset scartati di fila l'avviso non è consumato: arriva al secondo reset vero.
        monitor.restartSeries()
        _ = feed(&monitor, zero: true, seconds: 20)
        monitor.restartSeries()
        let call = feed(&monitor, zero: true, seconds: 71)
        #expect(call.last == .stillSilent(count: 2, warn: true))
    }

    /// Segnale tornato poco dopo un reset: esito dopo un secondo di segnale, senza avviso da togliere.
    @Test func signalBackSoonAfterReset() {
        var monitor = TapSilenceMonitor()
        _ = feed(&monitor, zero: false, seconds: 2)
        _ = feed(&monitor, zero: true, seconds: 23)
        let back = feed(&monitor, zero: false, seconds: 2)
        #expect(back.count == 1)
        guard case .back(let seconds, let warn)? = back.first else {
            Issue.record("il segnale tornato non è segnalato")
            return
        }
        #expect(abs(seconds - 3) < 0.05)
        #expect(!warn)
    }

    @Test func digitalSilenceIsExactZeroOnEveryChannel() {
        #expect(TapSilenceMonitor.isDigitalSilence([[0, 0, -0.0], [0, 0, 0]]))
        #expect(!TapSilenceMonitor.isDigitalSilence([[0, 0, 0], [0, 1e-30, 0]]))
        #expect(!TapSilenceMonitor.isDigitalSilence([]))
    }

    // MARK: - CaptureGap

    @Test func gapAfterRebuildBecomesSilenceWithCap() {
        var gap = CaptureGap()
        #expect(gap.silenceBefore(start: 100, duration: 0.01) == 0)
        // Senza ricostruzione un salto negli orari non si riempie (sovraccarico del Mac, non un buco nostro).
        #expect(gap.silenceBefore(start: 101, duration: 0.01) == 0)
        gap.markRebuild()
        #expect(abs(gap.silenceBefore(start: 101.31, duration: 0.01) - 0.3) < 1e-9)
        // Solo il primo blocco dopo la ricostruzione.
        #expect(gap.silenceBefore(start: 102, duration: 0.01) == 0)
        gap.markRebuild()
        #expect(gap.silenceBefore(start: 200, duration: 0.01) == CaptureGap.maximum)
        gap.markRebuild()
        #expect(gap.silenceBefore(start: 200.04, duration: 0.01) == 0)
    }

    @Test func gapWithoutValidTimeIsIgnored() {
        var gap = CaptureGap()
        _ = gap.silenceBefore(start: 10, duration: 0.01)
        gap.markRebuild()
        #expect(gap.silenceBefore(start: nil, duration: 0.01) == 0)
        gap.markRebuild()
        #expect(gap.silenceBefore(start: 20, duration: 0.01) == 0)
    }
}
