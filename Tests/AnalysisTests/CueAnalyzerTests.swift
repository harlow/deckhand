import DeckhandCore
import Foundation
import Testing
@testable import Analysis

@Suite struct CueAnalyzerTests {
    /// A one-split tree: x[1] <= 0.5 → 2.0 else 3.0, baseline 0.25.
    static func tinyEnsemble() -> TreeEnsemble {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Int32(1)); put(Double(0.25)); put(Int32(3))
        put(Float(0.5)); put(Int32(1)); put(Int32(1)); put(Int32(2))
        put(Float(2.0)); put(Int32(-1)); put(Int32(0)); put(Int32(0))
        put(Float(3.0)); put(Int32(-1)); put(Int32(0)); put(Int32(0))
        return TreeEnsemble(base64: d.base64EncodedString())!
    }

    @Test func treeEnsembleFollowsSplits() {
        let t = Self.tinyEnsemble()
        #expect(t.raw([9, 0.5]) == 2.25)
        #expect(t.raw([9, 0.6]) == 3.25)
        #expect(abs(t.probability([0, 0]) - 1 / (1 + exp(-2.25))) < 1e-12)
    }

    @Test func shippedModelsLoad() {
        #expect(TreeEnsemble(base64: CueModelData.cue) != nil)
        #expect(TreeEnsemble(base64: CueModelData.energy) != nil)
    }

    @Test func percentileMatchesNumpy() {
        // numpy.percentile([1, 2, 3, 4], [25, 50, 90]) == [1.75, 2.5, 3.7]
        #expect(abs(CueAnalyzer.percentile([4, 1, 3, 2], 25) - 1.75) < 1e-12)
        #expect(abs(CueAnalyzer.percentile([4, 1, 3, 2], 50) - 2.5) < 1e-12)
        #expect(abs(CueAnalyzer.percentile([4, 1, 3, 2], 90) - 3.7) < 1e-12)
    }

    /// Synthetic track: quiet 16-bar intro, loud 32 bars, 16-bar breakdown, loud 32 bars, outro.
    @Test func cuesFollowPhraseRules() {
        let beats = 512
        let level: (Int) -> Float = { b in
            switch b {
            case ..<64: 0.05
            case ..<192: 0.4
            case ..<256: 0.1
            case ..<384: 0.45
            default: 0.08
            }
        }
        let rows: [[Float]] = (0..<beats).map { b in
            let v = level(b) * (b % 4 == 0 ? 1.2 : 1)
            return [v, v * 0.8, v * 0.3, v, min(1, v * 2), v * 0.1] + (0..<10).map { Float(-3 + Double($0) * 0.1) + log10(v) } + [0.2, v * 5]
        }
        let ms = (0..<beats).map { 30 + $0 * 500 }
        let r = CueAnalyzer.detect(features: rows, beatTimesMs: ms, barPositions: (0..<beats).map { $0 % 4 + 1 }, bpm: 120)

        #expect(r.cues.first?.timeMs == 30)
        #expect(r.cues.count <= 8 && r.cues.count >= 4)
        let idx = r.cues.map { ($0.timeMs - 30) / 500 }
        #expect(idx.allSatisfy { $0 % 4 == 0 })
        #expect(zip(idx, idx.dropFirst()).allSatisfy { $1 - $0 >= 32 })
        #expect(idx.allSatisfy { Double($0) / Double(beats) <= 0.9 })
        #expect(r.cues.allSatisfy { (1...10).contains($0.energy) })
        #expect(r.energy.map { (1...10).contains($0) } == true)
        // The big structural changes should be found.
        #expect(idx.contains(64) || idx.contains(192) || idx.contains(256))
    }

    @Test func tooShortTrackHasNoCues() {
        let r = CueAnalyzer.detect(features: Array(repeating: Array(repeating: 0.1, count: 18), count: 40),
                                   beatTimesMs: Array(0..<40), barPositions: [], bpm: 120)
        #expect(r.cues.isEmpty && r.energy == nil)
    }
}
