import DeckhandCore
import Foundation
import Testing
@testable import Analysis

@Suite struct StructureAnalyzerTests {
    typealias Kind = StructureAnalyzer.Kind

    /// A 128 BPM grid (468.75 ms per beat) of `bars` bars starting on a downbeat.
    func analysis(bars: Int) -> TrackAnalysis {
        let beats = (0..<(bars * 4)).map { TrackAnalysis.Beat(barPosition: $0 % 4 + 1, timeMs: Int((Double($0) * 468.75).rounded()), bpm: 128) }
        return TrackAnalysis(durationSeconds: Double(bars * 4) * 0.46875, sampleRate: 44100, bpm: 128, beats: beats, key: nil,
                             waveforms: .init(peak: [0], rms: [0], low: [0], mid: [0], high: [0]))
    }

    func section(_ kind: Kind, bar: Int, endBar: Int, in a: TrackAnalysis) -> StructureAnalyzer.Section {
        let end = endBar * 4 < a.beats.count ? a.beats[endBar * 4].timeMs : Int(a.durationSeconds * 1000)
        return .init(kind: kind, startBeat: bar * 4, startMs: a.beats[bar * 4].timeMs, endMs: end, energy: 1)
    }

    @Test func pssiKindMapping() {
        #expect(Kind(pssiKind: 5, mood: 1) == .drop)
        #expect(Kind(pssiKind: 3, mood: 1) == .breakdown)
        #expect(Kind(pssiKind: 4, mood: 1) == nil)          // unused in high mood
        #expect(Kind(pssiKind: 9, mood: 2) == .drop)        // mid-mood chorus
        #expect(Kind(pssiKind: 8, mood: 3) == .breakdown)   // low-mood bridge
        #expect(Kind(pssiKind: 4, mood: 3) == .build)       // low-mood verse
        for k in Kind.allCases { #expect(Kind(pssiKind: k.pssiKind, mood: 1) == k) }
    }

    @Test func modelLoads() {
        #expect(StructureModelData.classes.compactMap { TreeEnsemble(base64: $0) }.count == Kind.allCases.count)
    }

    @Test func percentileMatchesNumpy() {
        // numpy.percentile([1, 2, 3, 4], 90) == 3.7; median of [3, 1, 2] == 2.
        #expect(abs(StructureAnalyzer.percentile([1, 2, 3, 4], 90) - 3.7) < 1e-12)
        #expect(StructureAnalyzer.median([3, 1, 2]) == 2)
    }

    /// Build→drop posteriors that switch at bar 6, between phrase lines (0, 4, 8 with k0 = 0).
    /// `margin` is how far the winning class leads (build vs drop; the other classes stay small).
    func switchAtBar6(margin: Double) -> [Int] {
        func post(_ winner: Int) -> [Double] {
            var p = [0.01, 0, 0.01, 0, 0.01]
            p[1] = winner == 1 ? 0.485 + margin / 2 : 0.485 - margin / 2
            p[3] = 0.97 - p[1]
            return p.map { log($0) }
        }
        return StructureAnalyzer.decode((0..<16).map { $0 < 6 ? post(1) : post(3) }, k0: 0)
    }

    func firstChange(_ path: [Int]) -> Int? { path.indices.first { $0 > 0 && path[$0] != path[$0 - 1] } }

    @Test func weakEvidenceSnapsToPhraseLines() {
        let path = switchAtBar6(margin: 0.24)
        #expect([4, 8].contains(firstChange(path) ?? -1))
        #expect(path.last == 3)
    }

    @Test func strongEvidenceCanChangeOffPhrase() {
        // The phrase constraint is soft: a clear change between phrase lines is kept.
        #expect(firstChange(switchAtBar6(margin: 0.95)) == 6)
    }

    @Test func rhythmFeaturesSeeTheKick() {
        // 150 fps envelopes with a 128 BPM kick: low-band spikes on each beat, silence elsewhere.
        let frames = 150 * 8
        var low = [Float](repeating: 0.01, count: frames)
        let beatTimes = (0..<16).map { Double($0) * 0.46875 }
        for t in beatTimes { let f = Int(t * 150); for i in f..<min(frames, f + 3) { low[i] = 0.8 } }
        let kick = TrackAnalysis.Waveforms(peak: low, rms: low, low: low, mid: [Float](repeating: 0.1, count: frames),
                                           high: [Float](repeating: 0.1, count: frames))
        let flat = TrackAnalysis.Waveforms(peak: low, rms: low, low: [Float](repeating: 0.4, count: frames),
                                           mid: [Float](repeating: 0.1, count: frames), high: [Float](repeating: 0.1, count: frames))
        let withKick = RhythmFeatures.perBeat(kick, beatTimes: beatTimes)
        let without = RhythmFeatures.perBeat(flat, beatTimes: beatTimes)
        #expect(withKick.count == 15 && withKick[0].count == RhythmFeatures.names.count)
        #expect(withKick[3][0] > 3)       // strong kick transient
        #expect(abs(without[3][0]) < 0.1) // sustained bass, no kick
    }

    @Test func namedCuesFollowTheArrangement() {
        let a = analysis(bars: 160)
        let sections = [
            section(.intro, bar: 0, endBar: 16, in: a), section(.build, bar: 16, endBar: 32, in: a),
            section(.drop, bar: 32, endBar: 64, in: a), section(.breakdown, bar: 64, endBar: 80, in: a),
            section(.build, bar: 80, endBar: 88, in: a), section(.drop, bar: 88, endBar: 120, in: a),
            section(.breakdown, bar: 120, endBar: 128, in: a), section(.drop, bar: 128, endBar: 152, in: a),
            section(.outro, bar: 152, endBar: 160, in: a),
        ]
        let cues = CueAnalyzer.namedHotCues(sections: sections, analysis: a)
        let byName = Dictionary(uniqueKeysWithValues: cues.map { ($0.name, $0) })
        func bar(_ name: String) -> Int? {
            guard let cue = byName[name] else { return nil }
            return a.beats.firstIndex { $0.timeMs == cue.timeMs }! / 4
        }
        #expect(bar("Mix In") == 0)
        #expect(bar("Drop 1") == 32)
        #expect(bar("Break") == 64)
        #expect(bar("Build") == 80)       // 8 bars before the main drop
        #expect(bar("Main Drop") == 88)
        #expect(bar("Break 2") == 120)
        #expect(bar("Last Drop") == 128)
        #expect(bar("Mix Out") == 152)
        #expect(cues.map(\.slot) == Array(1...8))
        #expect(byName["Main Drop"]?.rgb == CueAnalyzer.Role.mainDrop.rgb)
    }

    @Test func namedCuesSkipMissingRoles() {
        // No breakdown: no Break / Main Drop / Break 2 / Last Drop.
        let a = analysis(bars: 96)
        let sections = [section(.intro, bar: 0, endBar: 16, in: a), section(.drop, bar: 16, endBar: 80, in: a),
                        section(.outro, bar: 80, endBar: 96, in: a)]
        let names = CueAnalyzer.namedHotCues(sections: sections, analysis: a).map(\.name)
        // With no breakdown the only drop is also the main drop: Build sits 8 bars ahead of it.
        #expect(names == ["Mix In", "Drop 1", "Build", "Mix Out"])
    }

    @Test func phraseAnalysisForRekordbox() {
        let a = analysis(bars: 50)
        let sections = [section(.intro, bar: 0, endBar: 8, in: a), section(.drop, bar: 8, endBar: 26, in: a),
                        section(.outro, bar: 26, endBar: 50, in: a)]
        let p = StructureAnalyzer.phrases(sections: sections, analysis: a)!
        #expect(p.mood == 1 && p.endBeat == 200)
        // Drop of 18 bars: phrases at bars 8 and 16; the 2-bar remainder folds into the second.
        #expect(p.phrases.map(\.beat) == [1, 33, 65, 105, 137, 169])
        #expect(p.phrases.map(\.kind) == [1, 5, 5, 6, 6, 6])
        #expect(p.phrases.filter { $0.kind == 5 }.allSatisfy { $0.k1 == 1 })
    }
}

@Suite struct NamedCueGapTests {
    @Test func buildDoesNotKnockOutMainDrop() {
        // 128 BPM grid; sections: intro, drop at bar 16, breakdown at bar 32, main drop at bar 48, outro at bar 80.
        // Slight tempo drift: local beats near the main drop are a little shorter than the track average,
        // so an exact 8-bar lead measures just under 8 average bars.
        var t = 100.0
        let beats = (0..<400).map { i -> TrackAnalysis.Beat in
            defer { t += i < 200 ? 467.5 : 470 }
            return TrackAnalysis.Beat(barPosition: i % 4 + 1, timeMs: Int(t.rounded()), bpm: 128)
        }
        let analysis = TrackAnalysis(durationSeconds: 190, sampleRate: 44100, bpm: 128, beats: beats, key: nil,
                                     waveforms: .init(peak: [], rms: [], low: [], mid: [], high: []))
        func section(_ k: StructureAnalyzer.Kind, _ bar: Int, _ end: Int) -> StructureAnalyzer.Section {
            .init(kind: k, startBeat: bar * 4, startMs: beats[bar * 4].timeMs, endMs: beats[min(399, end * 4)].timeMs, energy: 0.5)
        }
        let sections = [section(.intro, 0, 16), section(.drop, 16, 32), section(.breakdown, 32, 48),
                        section(.drop, 48, 80), section(.outro, 80, 99)]
        let cues = CueAnalyzer.namedHotCues(sections: sections, analysis: analysis, leadBars: 8)
        let slots = Set(cues.map(\.slot))
        #expect(slots.contains(CueAnalyzer.Role.build.rawValue))
        #expect(slots.contains(CueAnalyzer.Role.mainDrop.rawValue))
    }
}
