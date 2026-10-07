import Analysis
import DeckhandCore
import MusicSource
import Testing
@testable import Sync

@Suite struct CueBuilderTests {
    let mik = MixedInKeyLibrary.Track(
        tempo: 120, key: nil, keyConfidence: nil, energy: 6, beatTimes: [],
        cues: (0..<10).map { (time: Double($0) * 16 + 0.03, energy: 5 + $0 % 3) }
    )

    func analysis() -> TrackAnalysis {
        let beats = (0..<400).map { TrackAnalysis.Beat(barPosition: $0 % 4 + 1, timeMs: 25 + $0 * 500, bpm: 120) }
        return TrackAnalysis(durationSeconds: 200, sampleRate: 44100, bpm: 120, beats: beats, key: nil,
                             waveforms: .init(peak: [], rms: [], low: [], mid: [], high: []))
    }

    @Test func snapsToBeats() {
        #expect(CueBuilder.snap(16_030, to: [15_525, 16_025, 16_525]) == 16_025)
        #expect(CueBuilder.snap(16_300, to: [16_025, 16_525]) == 16_300) // too far from either beat
        #expect(CueBuilder.snap(10, to: []) == 10)
    }

    @Test func modes() {
        let both = CueBuilder.cues(mik: mik, detected: nil, analysis: analysis(), source: .auto, mode: .both)
        let hot = both.filter { if case .hot = $0.kind { true } else { false } }
        #expect(both.count - hot.count == 10)
        #expect(hot.count == 8)
        #expect(hot.first?.kind == .hot(1) && hot.last?.kind == .hot(8))
        #expect(hot.first?.timeMs == 25)
        #expect(hot.first?.comment == "Energy 5")
        #expect(CueBuilder.cues(mik: mik, detected: nil, analysis: analysis(), source: .auto, mode: .none).isEmpty)
        #expect(CueBuilder.cues(mik: nil, detected: nil, analysis: analysis(), source: .auto, mode: .both).isEmpty)
        #expect(CueBuilder.fingerprint(both) != CueBuilder.fingerprint(CueBuilder.cues(mik: mik, detected: nil, analysis: analysis(), source: .auto, mode: .memory)))
    }

    @Test func sources() {
        let detected = CueAnalyzer.Result(cues: [.init(timeMs: 525, energy: 8), .init(timeMs: 16_525, energy: 4)], energy: 7)
        let own = CueBuilder.cues(mik: mik, detected: detected, analysis: analysis(), source: .deckhand, mode: .hot)
        #expect(own.map(\.timeMs) == [525, 16_525])
        #expect(own.first?.rgb == CueBuilder.color(energy: 8))
        // auto prefers MIK when it has cues, falls back to Deckhand's otherwise.
        #expect(CueBuilder.cues(mik: mik, detected: detected, analysis: analysis(), source: .auto, mode: .hot).count == 8)
        #expect(CueBuilder.cues(mik: nil, detected: detected, analysis: analysis(), source: .auto, mode: .hot).count == 2)
        #expect(CueBuilder.cues(mik: nil, detected: detected, analysis: analysis(), source: .mik, mode: .hot).isEmpty)
    }
}
