import DeckhandCore
import Foundation

/// Automatic cue points and energy levels, modeled on Mixed In Key's: cues on phrase boundaries
/// (multiples of 4 bars) where the music changes, each labeled with the energy (1–10) of the
/// section it starts, plus an overall track energy.
///
/// Candidates are scored by a gradient-boosted model trained against MIK's cues on the user's
/// library (see Scripts/cue-model). Feature code here must match `feats3.py` exactly.
public enum CueAnalyzer {
    public struct DetectedCue: Sendable, Equatable {
        public var timeMs: Int
        public var energy: Int
    }

    public struct Result: Sendable, Equatable {
        public var cues: [DetectedCue]
        public var energy: Int?
    }

    /// Bump when the models or features change.
    public static let version = 1

    static let maxCues = 8
    static let minGapBeats = 32
    static let maxPosition = 0.9
    static let window = [4, 8, 16, 32]
    static let step = 4
    static let eps = 1e-4

    nonisolated(unsafe) private static var models: (cue: TreeEnsemble, energy: TreeEnsemble)? = {
        guard let c = TreeEnsemble(base64: CueModelData.cue), let e = TreeEnsemble(base64: CueModelData.energy) else { return nil }
        return (c, e)
    }()

    public static func analyze(_ audio: DecodedAudio, analysis: TrackAnalysis) -> TrackEnrichment {
        let r = detect(audio, analysis: analysis)
        return TrackEnrichment(
            cues: r.cues.map { CuePoint(kind: .memory, timeMs: $0.timeMs, comment: "Energy \($0.energy)") },
            energy: r.energy
        )
    }

    public static func detect(_ audio: DecodedAudio, analysis: TrackAnalysis) -> Result {
        guard analysis.beats.count > 64 else { return Result(cues: [], energy: nil) }
        let beatTimes = analysis.beats.map { Double($0.timeMs) / 1000 }
        let features = BeatFeatures(audio: audio, waveforms: analysis.waveforms, beatTimes: beatTimes + [analysis.durationSeconds],
                                    timelineOffset: audio.timelineOffsetSeconds)
        return detect(features: features.rows, beatTimesMs: analysis.beats.map(\.timeMs),
                      barPositions: analysis.beats.map(\.barPosition), bpm: analysis.bpm)
    }

    /// Cue detection from precomputed `BeatFeatures` rows (used by evaluation tools).
    public static func detect(features rows: [[Float]], beatTimesMs: [Int], barPositions: [Int], bpm: Double) -> Result {
        guard let models, rows.count > 64 else { return Result(cues: [], energy: nil) }
        let g = transform(rows)
        let (x, cands) = cueFeatures(g, bars: barPositions)
        let scores = x.map { models.cue.probability($0) }
        let picked = select(scores: scores, cands: cands, n: g.count)

        let td = trackDescriptor(g, bpm: bpm > 0 ? bpm : 120)
        var cues: [DetectedCue] = []
        for (k, i) in picked.enumerated() {
            let j = k + 1 < picked.count ? picked[k + 1] : min(g.count, i + 64)
            let e = j - i >= 4 ? models.energy.raw(segmentFeatures(g, i, j, td)) : 6
            cues.append(DetectedCue(timeMs: beatTimesMs[i], energy: max(1, min(10, Int(e.rounded())))))
        }
        // MIK's track energy tracks the second-highest section energy.
        let sorted = cues.map(\.energy).sorted()
        let energy = sorted.count > 1 ? sorted[sorted.count - 2] : sorted.last
        return Result(cues: cues, energy: energy)
    }

    // MARK: - Features (mirror of feats3.py)

    /// Logs the linear columns; band columns are already log power.
    static func transform(_ rows: [[Float]]) -> [[Double]] {
        rows.map { r in
            r.enumerated().map { j, v in
                let d = Double(v)
                return (j < 6 || j >= 16) ? log(d + eps) : d
            }
        }
    }

    static func mean(_ g: [[Double]], _ a: Int, _ b: Int) -> [Double] {
        let width = g[0].count
        var m = [Double](repeating: 0, count: width)
        guard b > a else { return m }
        for i in a..<b { for j in 0..<width { m[j] += g[i][j] } }
        return m.map { $0 / Double(b - a) }
    }

    static func boundary(_ g: [[Double]], _ c: Int, _ n: Int) -> [Double] {
        var out: [Double] = []
        for w in window {
            let a = mean(g, max(0, c - w), c)
            let b = mean(g, c, min(n, c + w))
            out += zip(b, a).map { $0 - $1 }
            out += b
        }
        return out
    }

    static func candidates(_ n: Int) -> [Int] {
        stride(from: step, to: n - 16, by: step).map { $0 }
    }

    static func cueFeatures(_ g: [[Double]], bars: [Int]) -> ([[Double]], [Int]) {
        let n = g.count
        let cands = candidates(n)
        guard !cands.isEmpty else { return ([], []) }
        let b = cands.map { boundary(g, $0, n) }
        let width = b[0].count
        var mu = [Double](repeating: 0, count: width), sd = [Double](repeating: 0, count: width)
        for row in b { for j in 0..<width { mu[j] += row[j] } }
        mu = mu.map { $0 / Double(b.count) }
        for row in b { for j in 0..<width { sd[j] += (row[j] - mu[j]) * (row[j] - mu[j]) } }
        sd = sd.map { ($0 / Double(b.count)).squareRoot() + 1e-6 }

        let nov = b.map { abs($0[0]) + abs($0[3]) + abs($0[2]) }
        var classSum = [Double](repeating: 0, count: 16), classCount = [Double](repeating: 0, count: 16)
        for (j, c) in cands.enumerated() { classSum[c % 16] += nov[j]; classCount[c % 16] += 1 }
        let cls = (0..<16).map { classCount[$0] > 0 ? classSum[$0] / classCount[$0] : 0 }
        let clsMax = (cls.max() ?? 0) + 1e-9
        let clsRank = cls.map { $0 / clsMax }

        let rms = g.map { $0[3] }
        let threshold = log(0.1) + median(rms)
        let firstAudible = rms.firstIndex { $0 > threshold } ?? 0
        let novMax = (nov.max() ?? 0) + 1e-9
        let firstDownbeat = bars.prefix(n).firstIndex(of: 1) ?? 0

        var x: [[Double]] = []
        x.reserveCapacity(cands.count)
        for (j, c) in cands.enumerated() {
            let r = c % 16
            let z = (0..<width).map { (b[j][$0] - mu[$0]) / sd[$0] }
            let p = Double(c) / Double(n)
            x.append(b[j] + z + [
                p, p * p, r == 0 ? 1 : 0, r == 8 ? 1 : 0, r % 4 == 0 ? 1 : 0, c % 32 == 0 ? 1 : 0,
                clsRank[r], clsRank[r] == 1.0 ? 1 : 0, ((c - firstAudible) % 16 + 16) % 16 == 0 ? 1 : 0, nov[j] / novMax,
                c < bars.count && bars[c] == 1 ? 1 : 0,
                ((c - firstDownbeat) % 16 + 16) % 16 == 0 ? 1 : 0, ((c - firstDownbeat) % 32 + 32) % 32 == 0 ? 1 : 0,
            ])
        }
        return (x, cands)
    }

    /// Greedy top-scoring candidates at least 8 bars apart, skipping the outro; the first beat is always a cue.
    static func select(scores: [Double], cands: [Int], n: Int) -> [Int] {
        let order = scores.indices.sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }
        var chosen: [Int] = []
        for o in order {
            let c = cands[o]
            if Double(c) / Double(n) > maxPosition { continue }
            if chosen.allSatisfy({ abs(c - $0) >= minGapBeats }) { chosen.append(c) }
            if chosen.count == maxCues - 1 { break }
        }
        return ([0] + chosen).sorted()
    }

    static func trackDescriptor(_ g: [[Double]], bpm: Double) -> [Double] {
        var out: [Double] = []
        for j in 0..<g[0].count {
            let col = g.map { $0[j] }
            out += [25.0, 50, 75, 90].map { percentile(col, $0) }
        }
        out.append(log(bpm + 1))
        return out
    }

    static func segmentFeatures(_ g: [[Double]], _ a: Int, _ b: Int, _ td: [Double]) -> [Double] {
        let m = mean(g, a, b)
        let peakRMS = (a..<b).map { g[$0][3] }.max() ?? 0
        let rel = m.enumerated().map { j, v in v - td[1 + 4 * j] }
        return m + [peakRMS] + rel + [log(Double(b - a))] + td
    }

    // numpy-compatible (linear interpolation) percentile.
    static func percentile(_ x: [Double], _ p: Double) -> Double {
        let s = x.sorted()
        guard !s.isEmpty else { return 0 }
        let pos = p / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func median(_ x: [Double]) -> Double { percentile(x, 50) }
}
