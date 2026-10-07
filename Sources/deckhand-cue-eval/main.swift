import Analysis
import DeckhandCore
import Foundation
import MusicSource

// Evaluates Deckhand's automatic cue points and energy levels against Mixed In Key.
//
//   deckhand-cue-eval dump <out.jsonl> [limit]   per-beat features + MIK labels for every MIK track
//   deckhand-cue-eval eval-dump <dump.jsonl>     CueAnalyzer on dumped features (parity with training script)
//   deckhand-cue-eval eval [limit]               full pipeline from audio on held-out tracks, with timing
//
// The held-out set is every track whose path hash falls in bucket 0–3 of 20 (~20%); never tune on it.

func isHeldOut(_ path: String) -> Bool {
    var h: UInt64 = 1469598103934665603
    for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h % 20 < 4
}

struct Item: Sendable {
    let url: URL
    let mik: MixedInKeyLibrary.Track
}

func items() -> [Item] {
    guard let mik = MixedInKeyLibrary.load() else { fatalError("No MIK database") }
    return mik.tracks.sorted { $0.key < $1.key }.compactMap { path, t in
        FileManager.default.fileExists(atPath: path) && !t.cues.isEmpty ? Item(url: URL(fileURLWithPath: path), mik: t) : nil
    }
}

func analyze(_ url: URL) throws -> (DecodedAudio, TrackAnalysis) {
    let audio = try AudioDecoder.decodeMono(url)
    let tags = FileTagReader.read(url)
    let a = TrackAnalyzer.analyze(audio, hints: AnalysisHints(bpm: tags.bpm, key: tags.key ?? MusicalKey(tonic: 0, mode: .minor)))
    return (audio, a)
}

func parallel<T: Sendable>(_ items: [Item], _ f: @escaping @Sendable (Item) -> T?) -> [T] {
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

func dump(_ out: String, limit: Int?) {
    var list = items()
    if let limit { list = Array(list.prefix(limit)) }
    let lines: [String] = parallel(list) { item in
        guard let (audio, a) = try? analyze(item.url), !a.beats.isEmpty else { return nil }
        let ours = a.beats.map { Double($0.timeMs) / 1000 }
        let feats = BeatFeatures(audio: audio, waveforms: a.waveforms, beatTimes: ours + [a.durationSeconds],
                                 timelineOffset: audio.timelineOffsetSeconds)
        let row: [String: Any] = [
            "path": item.url.path,
            "heldOut": isHeldOut(item.url.path),
            "duration": a.durationSeconds,
            "bpm": a.bpm,
            "beats": ours,
            "bars": a.beats.map(\.barPosition),
            "feats": feats.rows.map(round4),
            "mikBeats": item.mik.beatTimes,
            "mikCues": item.mik.cues.map { [$0.time, Double($0.energy)] },
            "mikEnergy": item.mik.energy ?? 0,
            "mikTempo": item.mik.tempo ?? 0,
            // MIK times are on the decoded timeline; add this to compare with our player-timeline beats.
            "offset": audio.timelineOffsetSeconds,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    try! (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(lines.count) tracks")
}

struct Score {
    var tp = [0, 0], predicted = [0, 0], hit = [0, 0], labeled = [0, 0]
    var cueExact = 0, cuePm1 = 0, cueN = 0, trackExact = 0, trackPm1 = 0, trackN = 0, tracks = 0

    /// `mikCues` already shifted onto the player timeline.
    mutating func add(_ r: CueAnalyzer.Result, beatsMs: [Int], mikCues: [(Double, Int)], mikEnergy: Int) {
        tracks += 1
        func index(_ ms: Int) -> Int { beatsMs.indices.min { abs(beatsMs[$0] - ms) < abs(beatsMs[$1] - ms) }! }
        let pred = r.cues.map { index($0.timeMs) }
        let lab = mikCues.map { index(Int(($0.0 * 1000).rounded())) }
        for (k, tol) in [1, 4].enumerated() {
            tp[k] += pred.filter { p in lab.contains { abs(p - $0) <= tol } }.count
            predicted[k] += pred.count
            hit[k] += lab.filter { l in pred.contains { abs(l - $0) <= tol } }.count
            labeled[k] += lab.count
        }
        for (p, cue) in zip(pred, r.cues) {
            guard let m = lab.firstIndex(where: { abs(p - $0) <= 1 }) else { continue }
            cueN += 1
            cueExact += cue.energy == mikCues[m].1 ? 1 : 0
            cuePm1 += abs(cue.energy - mikCues[m].1) <= 1 ? 1 : 0
        }
        if mikEnergy > 0, let e = r.energy {
            trackN += 1
            trackExact += e == mikEnergy ? 1 : 0
            trackPm1 += abs(e - mikEnergy) <= 1 ? 1 : 0
        }
    }

    func report() {
        for (k, tol) in ["±1 beat", "±1 bar"].enumerated() {
            let p = Double(tp[k]) / Double(predicted[k]), r = Double(hit[k]) / Double(labeled[k])
            print(String(format: "cues %@: precision %.3f recall %.3f F1 %.3f  cues/track %.2f (MIK %.2f)",
                         tol, p, r, 2 * p * r / (p + r), Double(predicted[k]) / Double(tracks), Double(labeled[k]) / Double(tracks)))
        }
        print(String(format: "cue energy (matched): exact %.3f ±1 %.3f   track energy: exact %.3f ±1 %.3f   (%d tracks)",
                     Double(cueExact) / Double(cueN), Double(cuePm1) / Double(cueN),
                     Double(trackExact) / Double(trackN), Double(trackPm1) / Double(trackN), tracks))
    }
}

/// Runs CueAnalyzer on dumped features: must reproduce the Python training-script numbers.
func evalDump(_ path: String) {
    var score = Score()
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    for line in text.split(separator: "\n") {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              row["heldOut"] as? Bool == true,
              let beats = row["beats"] as? [Double], beats.count > 64,
              let feats = row["feats"] as? [[Double]], !feats.isEmpty,
              let cues = row["mikCues"] as? [[Double]], !cues.isEmpty else { continue }
        let offset = row["offset"] as? Double ?? 0
        let beatsMs = beats.map { Int(($0 * 1000).rounded()) }
        let r = CueAnalyzer.detect(features: feats.map { $0.map(Float.init) }, beatTimesMs: beatsMs,
                                   barPositions: row["bars"] as? [Int] ?? [], bpm: row["bpm"] as? Double ?? 120)
        score.add(r, beatsMs: beatsMs, mikCues: cues.map { ($0[0] + offset, Int($0[1])) }, mikEnergy: row["mikEnergy"] as? Int ?? 0)
    }
    score.report()
}

/// Full pipeline from audio on `limit` held-out tracks; reports accuracy and CueAnalyzer's own cost.
func evalAudio(limit: Int) {
    let list = Array(items().filter { isHeldOut($0.url.path) }.prefix(limit))
    let lock = NSLock()
    nonisolated(unsafe) var score = Score()
    nonisolated(unsafe) var seconds: [Double] = []
    _ = parallel(list) { item -> Int? in
        guard let (audio, a) = try? analyze(item.url), a.beats.count > 64 else { return nil }
        let start = Date()
        let r = CueAnalyzer.detect(audio, analysis: a)
        let t = Date().timeIntervalSince(start)
        let off = audio.timelineOffsetSeconds
        lock.withLock {
            seconds.append(t)
            score.add(r, beatsMs: a.beats.map(\.timeMs), mikCues: item.mik.cues.map { ($0.time + off, $0.energy) },
                      mikEnergy: item.mik.energy ?? 0)
        }
        return 0
    }
    score.report()
    let s = seconds.sorted()
    print(String(format: "CueAnalyzer time per track: median %.3fs p90 %.3fs", s[s.count / 2], s[s.count * 9 / 10]))
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "dump": dump(args[2], limit: args.count > 3 ? Int(args[3]) : nil)
case "eval-dump": evalDump(args[2])
case "eval": evalAudio(limit: args.count > 2 ? Int(args[2]) ?? 100 : 100)
default: print("usage: deckhand-cue-eval dump <out.jsonl> [limit] | eval-dump <dump.jsonl> | eval [limit]")
}
