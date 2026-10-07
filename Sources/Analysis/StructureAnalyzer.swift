import DeckhandCore
import Foundation

/// Song structure: the track split into DJ-meaningful sections (intro, build, breakdown, drop, outro),
/// modeled on Rekordbox's phrase analysis for electronic music ("high" mood).
public enum StructureAnalyzer {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case intro, build, breakdown, drop, outro

        /// Rekordbox high-mood PSSI kind: 1 Intro, 2 Up, 3 Down, 5 Chorus, 6 Outro.
        public var pssiKind: Int {
            switch self {
            case .intro: 1
            case .build: 2
            case .breakdown: 3
            case .drop: 5
            case .outro: 6
            }
        }

        /// Maps a PSSI kind for any mood onto the five sections. Mid/low moods (pop/ballad) use
        /// verse → build and bridge → breakdown.
        public init?(pssiKind k: Int, mood: Int) {
            switch (mood, k) {
            case (1, 1), (2, 1), (3, 1): self = .intro
            case (1, 2), (2, 2...7), (3, 2...7): self = .build
            case (1, 3), (2, 8), (3, 8): self = .breakdown
            case (1, 5), (2, 9), (3, 9): self = .drop
            case (1, 6), (2, 10), (3, 10): self = .outro
            default: return nil
            }
        }

        /// Class index used by the model.
        public var index: Int { Self.allCases.firstIndex(of: self)! }
    }

    public struct Section: Sendable, Equatable {
        public var kind: Kind
        /// Index into `analysis.beats` of the section's first beat.
        public var startBeat: Int
        public var startMs: Int
        public var endMs: Int
        /// Mean loudness of the section relative to the track's loudest section, 0–1.
        public var energy: Double

        public init(kind: Kind, startBeat: Int, startMs: Int, endMs: Int, energy: Double) {
            self.kind = kind
            self.startBeat = startBeat
            self.startMs = startMs
            self.endMs = endMs
            self.energy = energy
        }
    }

    /// Bump when the model or decoding changes.
    public static let version = 1

    public static func analyze(_ audio: DecodedAudio, analysis: TrackAnalysis) -> [Section] {
        guard analysis.beats.count > 64 else { return [] }
        let beatTimes = analysis.beats.map { Double($0.timeMs) / 1000 }
        let features = BeatFeatures(audio: audio, waveforms: analysis.waveforms, beatTimes: beatTimes + [analysis.durationSeconds],
                                    timelineOffset: audio.timelineOffsetSeconds)
        return analyze(audio, analysis: analysis, features: features.rows)
    }

    public static func analyze(_ audio: DecodedAudio, analysis: TrackAnalysis, features: [[Float]]) -> [Section] {
        guard analysis.beats.count > 64 else { return [] }
        let beatTimes = analysis.beats.map { Double($0.timeMs) / 1000 } + [analysis.durationSeconds]
        let rhythm = RhythmFeatures.perBeat(analysis.waveforms, beatTimes: beatTimes)
        return analyze(features: features, rhythm: rhythm, analysis: analysis)
    }

    /// `features` are BeatFeatures rows; `rhythm` RhythmFeatures rows, one per beat.
    public static func analyze(features: [[Float]], rhythm: [[Float]], analysis: TrackAnalysis) -> [Section] {
        let beats = analysis.beats
        guard beats.count > 64, features.count >= 16, let models else { return [] }
        guard let (path, starts, rms) = barPath(features: features, rhythm: rhythm, bars: beats.map(\.barPosition)) else { return [] }

        // Runs of equal labels become sections; energy is mean loudness relative to the loudest section.
        var runs: [(kind: Int, from: Int, to: Int)] = []
        for (i, k) in path.enumerated() {
            if let last = runs.last, last.kind == k { runs[runs.count - 1].to = i + 1 } else { runs.append((k, i, i + 1)) }
        }
        let means = runs.map { r in rms[r.from..<r.to].reduce(0, +) / Double(r.to - r.from) }
        let loudest = means.max() ?? 0
        let durationMs = Int((analysis.durationSeconds * 1000).rounded())
        return runs.enumerated().map { j, r in
            let startBeat = j == 0 ? 0 : starts[r.from]
            let endMs = j + 1 < runs.count ? beats[starts[runs[j + 1].from]].timeMs : durationMs
            return Section(kind: Kind.allCases[r.kind], startBeat: startBeat, startMs: beats[startBeat].timeMs,
                           endMs: endMs, energy: exp(means[j] - loudest))
        }
    }

    /// Rekordbox-style phrase analysis (PSSI, "high" mood) for the sections, ready to serialize.
    ///
    /// Each section is split into 8-bar (32-beat) phrases — Rekordbox's most common phrase length —
    /// with a remainder shorter than 4 bars folded into the section's last phrase. Beat numbers are
    /// 1-based indices into `analysis.beats`. Drops use variant flag k1 = 1, as Rekordbox's do.
    public static func phrases(sections: [Section], analysis: TrackAnalysis) -> PhraseAnalysis? {
        let beatCount = analysis.beats.count
        guard !sections.isEmpty, beatCount > 64 else { return nil }
        var phrases: [PhraseAnalysis.Phrase] = []
        for (j, section) in sections.enumerated() {
            let end = j + 1 < sections.count ? sections[j + 1].startBeat : beatCount
            var starts = Array(stride(from: section.startBeat, to: end, by: 32))
            if starts.count > 1, end - starts.last! < 16 { starts.removeLast() }
            for b in starts {
                phrases.append(.init(beat: b + 1, kind: section.kind.pssiKind, k1: section.kind == .drop ? 1 : 0))
            }
        }
        return PhraseAnalysis(mood: 1, endBeat: beatCount, phrases: phrases)
    }

    /// Per-bar class indices (Kind.allCases order), bar start beat indices and per-bar log RMS.
    public static func barPath(features: [[Float]], rhythm: [[Float]], bars: [Int]) -> (path: [Int], starts: [Int], rms: [Double])? {
        guard features.count >= 16, let models else { return nil }
        let (X, starts, rms) = barFeatures(transform(features, rhythm), bars: bars)
        guard X.count >= 4 else { return nil }
        let logPost = X.map { row in logSoftmax(models.map { $0.raw(row) }) }
        let k0 = (bars.firstIndex(of: 1) ?? 0) > 0 ? 1 : 0
        return (decode(logPost, k0: k0), starts, rms)
    }

    // MARK: - Model (mirrors Scripts/structure-model/train.py)

    static let eps = 1e-4
    static let context = [-16, -8, -4, 4, 8, 16]
    static let phraseBars = 4
    static let emissionWeight = 2.0
    static let offPhasePenalty = -2.0
    static let priorWeight = 1.0

    nonisolated(unsafe) private static var models: [TreeEnsemble]? = {
        let m = StructureModelData.classes.compactMap { TreeEnsemble(base64: $0) }
        return m.count == Kind.allCases.count ? m : nil
    }()

    /// Log where the source columns are linear (envelopes, flatness, onsets); rhythm columns as is.
    static func transform(_ features: [[Float]], _ rhythm: [[Float]]) -> [[Double]] {
        let nEnv = BeatFeatures.envelopeNames.count, nBand = BeatFeatures.bandEdges.count - 1
        return features.enumerated().map { i, f in
            var row = f.enumerated().map { j, v -> Double in
                let x = Double(v)
                return (j < nEnv || j >= nEnv + nBand) ? log(x + eps) : x
            }
            if i < rhythm.count { row += rhythm[i].map(Double.init) }
            return row
        }
    }

    /// One row per bar (4 beats from the first downbeat, plus a leading partial bar), the bar start
    /// beat indices, and each bar's mean log RMS.
    static func barFeatures(_ G: [[Double]], bars: [Int]) -> (rows: [[Double]], starts: [Int], rms: [Double]) {
        let n = G.count
        let fd = bars.firstIndex(of: 1) ?? 0
        var starts = fd > 0 ? [0] : []
        if n - 3 > fd { starts += stride(from: fd, to: n - 3, by: 4) }
        let cols = G[0].count
        let B: [[Double]] = starts.map { s in
            let e = min(n, s + 4)
            var m = [Double](repeating: 0, count: cols)
            for i in s..<e { for c in 0..<cols { m[c] += G[i][c] } }
            return m.map { $0 / Double(e - s) }
        }
        let m = B.count
        let med = (0..<cols).map { c in median(B.map { $0[c] }) }
        let sd = (0..<cols).map { c -> Double in
            let col = B.map { $0[c] }
            let mean = col.reduce(0, +) / Double(m)
            return (col.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(m)).squareRoot() + 1e-6
        }
        let Z = B.map { row in (0..<cols).map { (row[$0] - med[$0]) / sd[$0] } }
        let top = percentile(B.map { $0[3] }, 90)
        var rows: [[Double]] = []
        rows.reserveCapacity(m)
        for i in 0..<m {
            var r = Z[i]
            r += (0..<cols).map { B[i][$0] - med[$0] }
            r += i > 0 ? (0..<cols).map { Z[i][$0] - Z[i - 1][$0] } : [Double](repeating: 0, count: cols)
            for w in context {
                var (a, b) = w < 0 ? (i + w, i) : (i + 1, i + 1 + w)
                a = max(0, a); b = min(m, b)
                var seg = Z[i]
                if b > a {
                    seg = [Double](repeating: 0, count: cols)
                    for j in a..<b { for c in 0..<cols { seg[c] += Z[j][c] } }
                    seg = seg.map { $0 / Double(b - a) }
                }
                r += (0..<cols).map { seg[$0] - Z[i][$0] }
            }
            let k = i - (fd > 0 ? 1 : 0)
            r += [Double(i) / Double(m), Double(m - i) / Double(m), log1p(Double(i)), log1p(Double(m - i)), B[i][3] - top,
                  k % 4 == 0 ? 1 : 0, k % 8 == 0 ? 1 : 0, k % 16 == 0 ? 1 : 0]
            rows.append(r)
        }
        return (rows, starts, B.map { $0[3] })
    }

    /// Viterbi over bars: section changes on 4-bar phrase lines from the first downbeat are cheap,
    /// elsewhere penalized. Emissions are scaled posteriors over class priors.
    static func decode(_ logPost: [[Double]], k0: Int) -> [Int] {
        let K = Kind.allCases.count
        let A = StructureModelData.logTransition
        let prior = StructureModelData.logPrior
        let emit = logPost.map { lp in (0..<K).map { emissionWeight * (lp[$0] - priorWeight * prior[$0]) } }
        var V = (0..<K).map { StructureModelData.logStart[$0] + emit[0][$0] }
        var back: [[Int]] = []
        for i in 1..<emit.count {
            let onPhrase = (i - k0) % phraseBars == 0
            var next = [Double](repeating: 0, count: K)
            var b = [Int](repeating: 0, count: K)
            for to in 0..<K {
                var best = -Double.infinity, arg = 0
                for from in 0..<K {
                    let t = A[from][to] + (from != to && !onPhrase ? offPhasePenalty : 0)
                    let v = V[from] + t
                    if v > best { best = v; arg = from }
                }
                next[to] = best + emit[i][to]
                b[to] = arg
            }
            V = next
            back.append(b)
        }
        var k = 0
        for j in 1..<K where V[j] > V[k] { k = j }
        var path = [k]
        for b in back.reversed() { k = b[k]; path.append(k) }
        return path.reversed()
    }

    static func logSoftmax(_ raw: [Double]) -> [Double] {
        let m = raw.max()!
        let z = raw.map { exp($0 - m) }.reduce(0, +)
        return raw.map { log(exp($0 - m) / z + 1e-9) }
    }

    static func median(_ x: [Double]) -> Double { percentile(x, 50) }

    /// numpy's default (linear interpolation) percentile.
    static func percentile(_ x: [Double], _ q: Double) -> Double {
        let s = x.sorted()
        guard s.count > 1 else { return s.first ?? 0 }
        let pos = q / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}

/// Per-beat rhythm descriptors from the 150 fps envelopes: what makes EDM sections audible
/// (kick present or not, off-beat hats, sidechain pumping).
///
/// Columns: kick transient (log onset peak vs. rest of beat, low band), off-beat hat (log high-band
/// peak around the half-beat vs. beat mean), low-band pumping (std / mean within the beat),
/// mid-band transient (snare/clap). Must match `rhythm_features` expectations in train.py.
public enum RhythmFeatures {
    public static let names = ["kick", "hat", "pump", "snare"]
    static let eps: Float = 1e-4

    public static func perBeat(_ w: TrackAnalysis.Waveforms, beatTimes: [Double]) -> [[Float]] {
        let fps = Double(TrackAnalysis.Waveforms.framesPerSecond)
        let n = w.frameCount
        guard n > 0, beatTimes.count > 1 else { return [] }
        func frame(_ t: Double) -> Int { max(0, min(n - 1, Int((t * fps).rounded()))) }
        func maxIn(_ x: [Float], _ a: Int, _ b: Int) -> Float {
            var m: Float = 0
            for f in max(0, a)..<min(n, max(a + 1, b)) { m = max(m, x[f]) }
            return m
        }
        func meanIn(_ x: [Float], _ a: Int, _ b: Int) -> Float {
            let lo = max(0, a), hi = min(n, max(lo + 1, b))
            var s: Float = 0
            for f in lo..<hi { s += x[f] }
            return s / Float(hi - lo)
        }
        return (0..<(beatTimes.count - 1)).map { i in
            let a = frame(beatTimes[i]), b = max(a + 2, frame(beatTimes[i + 1]))
            let len = b - a
            let head = a + max(1, len / 8), tailStart = a + len / 4
            let kick = log(maxIn(w.low, a - 1, head + 1) + eps) - log(meanIn(w.low, tailStart, b) + eps)
            let half = a + len / 2
            let hat = log(maxIn(w.high, half - len / 8, half + len / 8 + 1) + eps) - log(meanIn(w.high, a, b) + eps)
            let m = meanIn(w.low, a, b)
            var v: Float = 0
            for f in a..<min(n, b) { v += (w.low[f] - m) * (w.low[f] - m) }
            let pump = (v / Float(len)).squareRoot() / (m + eps)
            let snare = log(maxIn(w.mid, a - 1, head + 1) + eps) - log(meanIn(w.mid, tailStart, b) + eps)
            return [kick, hat, pump, snare]
        }
    }
}
