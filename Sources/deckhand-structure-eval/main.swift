import Analysis
import DeckhandCore
import EvalSupport
import Foundation

// Evaluates Deckhand's song-structure analysis against Rekordbox phrase analysis (PSSI).
//
//   deckhand-structure-eval dump <pssi.json> <out.jsonl> [limit]   per-beat features for every PSSI track
//   deckhand-structure-eval eval-dump <dump.jsonl>                 bar-level metrics on dumped features (parity with train.py)
//   deckhand-structure-eval eval <pssi.json> [limit]               full pipeline on held-out tracks, with timing
//
// pssi.json comes from Scripts/structure-model/export-pssi.py. The held-out set is every track whose
// album folder hashes into bucket 0–3 of 20 (~20%); never tune on it.

func isHeldOut(_ path: String) -> Bool {
    let folder = (path as NSString).deletingLastPathComponent
    var h: UInt64 = 1469598103934665603
    for b in folder.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h % 20 < 4
}

struct Truth: Sendable {
    let path: String
    let mood: Int
    let endBeat: Int
    let phrases: [[Int]]
    let beatTimesMs: [Int]
}

func loadTruth(_ path: String) -> [Truth] {
    let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
    return rows.compactMap { r in
        guard let p = r["path"] as? String, FileManager.default.fileExists(atPath: p) else { return nil }
        return Truth(path: p, mood: r["mood"] as! Int, endBeat: r["endBeat"] as! Int,
                     phrases: r["phrases"] as! [[Int]], beatTimesMs: r["beatTimesMs"] as! [Int])
    }
}

func analyze(_ path: String) throws -> (DecodedAudio, TrackAnalysis) {
    let url = URL(fileURLWithPath: path)
    let audio = try AudioDecoder.decodeMono(url)
    let tags = FileTagReader.read(url)
    // A key hint skips key detection, which structure doesn't need.
    let a = TrackAnalyzer.analyze(audio, hints: AnalysisHints(bpm: tags.bpm, key: MusicalKey(tonic: 0, mode: .minor)))
    return (audio, a)
}

func parallel<T: Sendable>(_ items: [Truth], _ f: @escaping @Sendable (Truth) -> T?) -> [T] {
    let lock = NSLock()
    nonisolated(unsafe) var out: [T] = []
    nonisolated(unsafe) var done = 0
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let r = f(items[i])
        lock.withLock {
            if let r { out.append(r) }
            done += 1
            if done % 100 == 0 { FileHandle.standardError.write(Data("\(done)/\(items.count)\n".utf8)) }
        }
    }
    return out
}

func round4(_ x: [Float]) -> [Float] { x.map { ($0 * 10000).rounded() / 10000 } }

/// Rekordbox PSSI → one of Deckhand's five section kinds per phrase start (ms on Rekordbox's grid).
func truthSections(_ t: Truth) -> [(ms: Int, kind: StructureAnalyzer.Kind)] {
    t.phrases.compactMap { p in
        let i = p[0] - 1
        guard i >= 0, i < t.beatTimesMs.count, let k = StructureAnalyzer.Kind(pssiKind: p[1], mood: t.mood) else { return nil }
        return (t.beatTimesMs[i], k)
    }
}

func dump(_ truthPath: String, _ out: String, limit: Int?) {
    var list = loadTruth(truthPath)
    if let limit { list = Array(list.prefix(limit)) }
    let lines: [String] = parallel(list) { t in
        guard let (audio, a) = try? analyze(t.path), a.beats.count > 64 else { return nil }
        let beats = a.beats.map { Double($0.timeMs) / 1000 }
        let feats = BeatFeatures(audio: audio, waveforms: a.waveforms, beatTimes: beats + [a.durationSeconds],
                                 timelineOffset: audio.timelineOffsetSeconds)
        let row: [String: Any] = [
            "path": t.path, "heldOut": isHeldOut(t.path), "duration": a.durationSeconds, "bpm": a.bpm,
            "beats": beats, "bars": a.beats.map(\.barPosition), "feats": feats.rows.map(round4),
            "rhythm": RhythmFeatures.perBeat(a.waveforms, beatTimes: beats + [a.durationSeconds]).map(round4),
            "mood": t.mood, "phrases": t.phrases, "rbBeatsMs": t.beatTimesMs, "endBeat": t.endBeat,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    try! (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(lines.count) tracks")
}

/// Accumulates boundary, label, drop/breakdown and named-cue agreement with PSSI.
struct Score {
    var bTP = 0, bPred = 0, bHit = 0, bLab = 0
    var labelOK = 0, labelN = 0
    var onset: [StructureAnalyzer.Kind: (tp: Int, pred: Int, hit: Int, lab: Int)] = [:]
    var named: [String: (ok: Int, n: Int)] = [:]
    var tracks = 0

    mutating func add(_ sections: [StructureAnalyzer.Section], cues: [CueAnalyzer.NamedCue], truth: [(ms: Int, kind: StructureAnalyzer.Kind)],
                      beatsMs: [Int], durationMs: Int) {
        guard !truth.isEmpty, !sections.isEmpty else { return }
        tracks += 1
        let barMs = beatsMs.count > 8 ? (beatsMs[8] - beatsMs[0]) / 2 : 2000
        // Boundaries: section starts, ignoring the very first (track start).
        let pb = sections.dropFirst().map(\.startMs)
        let tb = merge(truth).dropFirst().map(\.ms)
        bTP += pb.filter { p in tb.contains { abs($0 - p) <= barMs } }.count
        bPred += pb.count
        bHit += tb.filter { l in pb.contains { abs($0 - l) <= barMs } }.count
        bLab += tb.count

        // Per-bar labels, sampled every bar from the first truth phrase to the end.
        let start = truth[0].ms
        var t = start
        while t < durationMs - barMs {
            if let lk = kind(at: t, truth), let pk = sections.last(where: { $0.startMs <= t })?.kind {
                labelN += 1
                if lk == pk { labelOK += 1 }
            }
            t += barMs
        }

        // Onsets of drops (chorus) and breakdowns (down): first phrase of each run.
        for k in [StructureAnalyzer.Kind.drop, .breakdown] {
            let p = sections.filter { $0.kind == k }.map(\.startMs)
            let l = merge(truth).filter { $0.kind == k }.map(\.ms)
            var o = onset[k] ?? (0, 0, 0, 0)
            o.tp += p.filter { x in l.contains { abs($0 - x) <= barMs } }.count
            o.pred += p.count
            o.hit += l.filter { x in p.contains { abs($0 - x) <= barMs } }.count
            o.lab += l.count
            onset[k] = o
        }

        // Named cues: does each land on a truth section start of the expected kind (±1 bar)?
        let starts = merge(truth)
        for c in cues {
            guard let expected = c.expectedKind else { continue }
            var v = named[c.name] ?? (0, 0)
            v.n += 1
            let target = c.timeMs + c.leadMs
            let hit = c.name == "Mix Out"
                // Mix Out counts when on, or up to 8 bars before, Rekordbox's outro.
                ? starts.contains { $0.kind == .outro && target - $0.ms <= barMs && $0.ms - target <= 8 * barMs }
                : starts.contains { $0.kind == expected && abs($0.ms - target) <= barMs }
            if hit { v.ok += 1 }
            named[c.name] = v
        }
    }

    func merge(_ s: [(ms: Int, kind: StructureAnalyzer.Kind)]) -> [(ms: Int, kind: StructureAnalyzer.Kind)] {
        var out: [(ms: Int, kind: StructureAnalyzer.Kind)] = []
        for x in s where out.last?.kind != x.kind { out.append(x) }
        return out
    }

    func kind(at t: Int, _ truth: [(ms: Int, kind: StructureAnalyzer.Kind)]) -> StructureAnalyzer.Kind? {
        truth.last(where: { $0.ms <= t })?.kind
    }

    func report() {
        func f1(_ tp: Int, _ pred: Int, _ hit: Int, _ lab: Int) -> String {
            let p = Double(tp) / Double(max(1, pred)), r = Double(hit) / Double(max(1, lab))
            return String(format: "precision %.3f recall %.3f F1 %.3f", p, r, p + r > 0 ? 2 * p * r / (p + r) : 0)
        }
        print("tracks \(tracks)")
        print("section boundaries ±1 bar: \(f1(bTP, bPred, bHit, bLab))  (pred/track \(String(format: "%.1f", Double(bPred) / Double(max(1, tracks)))), PSSI \(String(format: "%.1f", Double(bLab) / Double(max(1, tracks)))))")
        print(String(format: "per-bar label accuracy %.3f", Double(labelOK) / Double(max(1, labelN))))
        for (k, o) in onset.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("\(k.rawValue) onsets ±1 bar: \(f1(o.tp, o.pred, o.hit, o.lab))")
        }
        for (name, v) in named.sorted(by: { $0.key < $1.key }) {
            print(String(format: "named cue %-10@ on expected PSSI section start: %.3f (%d)", name as NSString, Double(v.ok) / Double(max(1, v.n)), v.n))
        }
    }
}

func evalAudio(_ truthPath: String, limit: Int) {
    let list = Array(loadTruth(truthPath).filter { isHeldOut($0.path) && $0.mood == 1 }.prefix(limit))
    let lock = NSLock()
    nonisolated(unsafe) var score = Score()
    nonisolated(unsafe) var seconds: [Double] = []
    _ = parallel(list) { t -> Int? in
        guard let (audio, a) = try? analyze(t.path), a.beats.count > 64 else { return nil }
        // Cost split: BeatFeatures is shared with CueAnalyzer in the real pipeline, so the extra cost
        // of structure analysis is rhythm features + model + decoding.
        let beatTimes = a.beats.map { Double($0.timeMs) / 1000 }
        let t0 = Date()
        let feats = BeatFeatures(audio: audio, waveforms: a.waveforms, beatTimes: beatTimes + [a.durationSeconds],
                                 timelineOffset: audio.timelineOffsetSeconds)
        let t1 = Date()
        let sections = StructureAnalyzer.analyze(audio, analysis: a, features: feats.rows)
        let cues = CueAnalyzer.namedHotCues(sections: sections, analysis: a)
        let dt = Date().timeIntervalSince(t1)
        _ = t0
        // Truth is on Rekordbox's grid; both grids are on the player timeline.
        lock.withLock {
            seconds.append(dt)
            score.add(sections, cues: cues, truth: truthSections(t), beatsMs: a.beats.map(\.timeMs),
                      durationMs: Int(a.durationSeconds * 1000))
        }
        return 0
    }
    score.report()
    let s = seconds.sorted()
    if !s.isEmpty {
        print(String(format: "extra cost per track (rhythm + model + decode + named cues; BeatFeatures shared): median %.3fs p90 %.3fs",
                     s[s.count / 2], s[s.count * 9 / 10]))
    }
}

/// Bar-level metrics identical to train.py's `Metrics` (labels = PSSI kind at each bar's midpoint).
func evalDump(_ path: String) {
    var ok = 0, n = 0
    var b = [0, 0, 0, 0], o: [Int: [Int]] = [2: [0, 0, 0, 0], 3: [0, 0, 0, 0]]
    func onsets(_ s: [Int]) -> [(Int, Int)] { s.indices.compactMap { i in i > 0 && s[i] != s[i - 1] && s[i] >= 0 ? (i, s[i]) : nil } }
    func acc(_ st: inout [Int], _ P: [(Int, Int)], _ T: [(Int, Int)]) {
        st[0] += P.filter { p in T.contains { abs($0.0 - p.0) <= 1 } }.count; st[1] += P.count
        st[2] += T.filter { t in P.contains { abs($0.0 - t.0) <= 1 } }.count; st[3] += T.count
    }
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    for line in text.split(separator: "\n") {
        guard let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], r["heldOut"] as? Bool == true,
              let feats = r["feats"] as? [[Double]], let rhythm = r["rhythm"] as? [[Double]], let beats = r["beats"] as? [Double],
              let bars = r["bars"] as? [Int], let rb = r["rbBeatsMs"] as? [Int], let phrases = r["phrases"] as? [[Int]],
              let mood = r["mood"] as? Int, let endBeat = r["endBeat"] as? Int,
              let (pred, starts, _) = StructureAnalyzer.barPath(features: feats.map { $0.map(Float.init) },
                                                                 rhythm: rhythm.map { $0.map(Float.init) }, bars: bars) else { continue }
        let ph: [(Double, Int)] = phrases.compactMap { p in
            guard p[0] > 0, p[0] <= rb.count, let k = StructureAnalyzer.Kind(pssiKind: p[1], mood: mood) else { return nil }
            return (Double(rb[p[0] - 1]), k.index)
        }
        guard let first = ph.first, pred.count >= 16 else { continue }
        let endMs = Double(rb[min(rb.count, endBeat) - 1])
        let y: [Int] = starts.indices.map { i in
            let e = i + 1 < starts.count ? starts[i + 1] : beats.count - 1
            let mid = 1000 * (beats[starts[i]] + beats[min(e, beats.count - 1)]) / 2
            if mid < first.0 || mid > endMs { return -1 }
            return ph.last { $0.0 <= mid }!.1
        }
        for (p, t) in zip(pred, y) where t >= 0 { n += 1; if p == t { ok += 1 } }
        guard let lo = y.firstIndex(where: { $0 >= 0 }), let hi = y.lastIndex(where: { $0 >= 0 }) else { continue }
        let P = onsets(Array(pred[lo...hi])), T = onsets(Array(y[lo...hi]))
        acc(&b, P, T)
        for k in [2, 3] { acc(&o[k]!, P.filter { $0.1 == k }, T.filter { $0.1 == k }) }
    }
    func f(_ s: [Int]) -> String {
        let p = Double(s[0]) / Double(max(1, s[1])), r = Double(s[2]) / Double(max(1, s[3]))
        return String(format: "P %.3f R %.3f F1 %.3f", p, r, 2 * p * r / (p + r + 1e-9))
    }
    print(String(format: "[swift] bar acc %.3f", Double(ok) / Double(n)) + " | boundaries \(f(b)) | breakdown \(f(o[2]!)) | drop \(f(o[3]!))")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "dump": dump(args[2], args[3], limit: args.count > 4 ? Int(args[4]) : nil)
case "eval-dump": evalDump(args[2])
case "eval": evalAudio(args[2], limit: args.count > 3 ? Int(args[3]) ?? 1000 : 1000)
default: print("usage: deckhand-structure-eval dump <pssi.json> <out.jsonl> [limit] | eval <pssi.json> [limit]")
}
