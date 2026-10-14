import Foundation
import Testing
@testable import CornettaCore

struct TranscriptTests {
    typealias S = Transcript.Segment

    @Test func echoOfTheOtherPersonIsDropped() {
        let others = [S(speaker: .others, start: 2, end: 6, text: "Ciao, mi senti bene?")]
        let me = [
            S(speaker: .me, start: 2.1, end: 5.9, text: "ciao mi senti bene"),   // eco degli altoparlanti
            S(speaker: .me, start: 7, end: 9, text: "Sì, ti sento benissimo."),
        ]
        let merged = TranscriptMerger.merge(me: me, others: others)
        #expect(merged.map(\.text) == ["Ciao, mi senti bene?", "Sì, ti sento benissimo."])
    }

    @Test func echoInsideALongerSentenceIsCutOut() {
        let others = [S(speaker: .others, start: 2, end: 6, text: "Questa è una prova della trascrizione automatica.")]
        let me = [S(speaker: .me, start: 0, end: 9, text: "Allora domani ci sentiamo questa è una prova della trascrizione e poi ti mando il preventivo.")]
        let merged = TranscriptMerger.merge(me: me, others: others)
        let mine = merged.first { $0.speaker == .me }
        #expect(mine?.text == "Allora domani ci sentiamo e poi ti mando il preventivo.")
    }

    @Test func shortCommonWordsAreNotTreatedAsEcho() {
        let others = [S(speaker: .others, start: 0, end: 4, text: "Sì, va bene per me.")]
        let me = [S(speaker: .me, start: 1, end: 5, text: "Per me va bene domani.")]
        let merged = TranscriptMerger.merge(me: me, others: others)
        #expect(merged.contains { $0.speaker == .me && $0.text == "Per me va bene domani." })
    }

    @Test func overlappingButDifferentSpeechIsKept() {
        let others = [S(speaker: .others, start: 0, end: 5, text: "Domani alle dieci va bene?")]
        let me = [S(speaker: .me, start: 1, end: 3, text: "Aspetta che controllo")]
        let merged = TranscriptMerger.merge(me: me, others: others)
        #expect(merged.count == 2)
        #expect(merged.first?.speaker == .others)
    }

    @Test func noiseFragmentsAreDropped() {
        let merged = TranscriptMerger.merge(me: [S(speaker: .me, start: 0, end: 0.4, text: "I"), S(speaker: .me, start: 1, end: 2, text: "Sì.")],
                                            others: [S(speaker: .others, start: 3, end: 4, text: "…")])
        #expect(merged.map(\.text) == ["Sì."])
    }

    @Test func segmentsAreSortedByTime() {
        let merged = TranscriptMerger.merge(
            me: [S(speaker: .me, start: 10, end: 11, text: "due")],
            others: [S(speaker: .others, start: 1, end: 2, text: "uno"), S(speaker: .others, start: 20, end: 21, text: "tre")])
        #expect(merged.map(\.text) == ["uno", "due", "tre"])
    }

    @Test func consecutiveSentencesOfTheSameSpeakerBecomeOneTurn() {
        let turns = TranscriptFormatter.turns([
            S(speaker: .me, start: 0, end: 2, text: "Ciao."),
            S(speaker: .me, start: 2.5, end: 4, text: "Come stai?"),
            S(speaker: .others, start: 5, end: 6, text: "Bene."),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].text == "Ciao. Come stai?")
    }

    @Test func timestampFormat() {
        #expect(TranscriptFormatter.timestamp(75) == "01:15")
        #expect(TranscriptFormatter.timestamp(3725) == "1:02:05")
    }

    @Test func markdownHasTitleAndSpeakers() {
        let t = Transcript(recording: "x.m4a", engine: "test", language: "it_IT", segments: [
            S(speaker: .me, start: 0, end: 1, text: "Pronto?"), S(speaker: .others, start: 2, end: 3, text: "Ciao!"),
        ])
        let md = TranscriptFormatter.markdown(t, title: "Chiamata di prova", duration: 65)
        #expect(md.hasPrefix("# Chiamata di prova"))
        #expect(md.contains("Durata 01:05"))
        #expect(md.contains("**Tu** (00:00): Pronto?"))
        #expect(md.contains("**Altri** (00:02): Ciao!"))
    }

    @Test func roundTripsThroughJSON() throws {
        let t = Transcript(recording: "x.m4a", engine: "SpeechTranscriber", language: "it_IT",
                           segments: [S(speaker: .mixed, start: 0, end: 1, text: "Prova")])
        // Il formato su disco usa date ISO 8601: scrittura e lettura devono usare la stessa coppia.
        let data = try Transcript.encoder.encode(t)
        let back = try Transcript.decoder.decode(Transcript.self, from: data)
        #expect(back.segments == t.segments)
        #expect(abs(back.createdAt.timeIntervalSince(t.createdAt)) < 1)
    }
}
