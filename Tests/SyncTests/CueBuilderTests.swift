import Analysis
import DeckhandCore
import Testing
@testable import Sync

@Suite struct CueBuilderTests {
    let detected = CueAnalyzer.Result(cues: (0..<10).map { .init(timeMs: 25 + $0 * 16_000, energy: 5 + $0 % 3) }, energy: 6)

    func analysis() -> TrackAnalysis {
        let beats = (0..<400).map { TrackAnalysis.Beat(barPosition: $0 % 4 + 1, timeMs: 25 + $0 * 500, bpm: 120) }
        return TrackAnalysis(durationSeconds: 200, sampleRate: 44100, bpm: 120, beats: beats, key: nil,
                             waveforms: .init(peak: [], rms: [], low: [], mid: [], high: []))
    }

    @Test func modes() {
        let both = CueBuilder.cues(detected: detected, analysis: analysis(), mode: .both)
        let hot = both.filter { if case .hot = $0.kind { true } else { false } }
        #expect(both.count - hot.count == 10)
        #expect(hot.count == 8)
        #expect(hot.first?.kind == .hot(1) && hot.last?.kind == .hot(8))
        #expect(hot.first?.timeMs == 25)
        #expect(hot.first?.comment == "Energy 5")
        #expect(hot.first?.rgb == CueBuilder.color(energy: 5))
        #expect(CueBuilder.cues(detected: detected, analysis: analysis(), mode: .none).isEmpty)
        #expect(CueBuilder.cues(detected: nil, analysis: analysis(), mode: .both).isEmpty)
        #expect(CueBuilder.fingerprint(both) != CueBuilder.fingerprint(CueBuilder.cues(detected: detected, analysis: analysis(), mode: .memory)))
    }
}
