// Evaluates BPM and beat grids against Mixed In Key (answer key) and Rekordbox (what players expect).
// Usage: deckhand-grid-eval rekordbox-grids.json [--set heldout|train|all] [--limit N] [--hints none|tag|mik] [--dump out.json]
//   rekordbox-grids.json from Scripts/export-grid-groundtruth.py; MIK data is read (read-only) from
//   ~/Library/Application Support/Mixedinkey/Collection11.mikdb or $MIK_DB.
// The held-out set (stable hash of path, ~20%) must never be used for tuning.
import Analysis
import DeckhandCore
import Foundation
import SQLite3

struct RekordboxGrid: Decodable {
    let path: String
    let bpm: Double
    let bars: [Int]
    let beatsMs: [Int]
    let tagBpm: Double?
}

struct MIKTrack {
    let tempo: Double
    let beats: [Double]
}

struct Result: Encodable {
    let path: String
    let ok: Bool
    var bpm = 0.0, rbBpm = 0.0, mikBpm = 0.0
    var phaseRbMs = Double.nan, phaseMikMs = Double.nan, mikVsRbMs = Double.nan
    var downbeatAgree = Double.nan
    var periodMs = 0.0
    var seconds = 0.0
    var offsetMs = 0.0
}

func loadMIK(_ path: String) -> [String: MIKTrack] {
    var db: OpaquePointer?
    guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT ZTEMPO, ZBEATS, ZBOOKMARKDATA FROM ZSONG", -1, &st, nil)
    defer { sqlite3_finalize(st) }
    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(st, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }
    func uid(_ v: Any?) -> Int? {
        guard let v else { return nil }
        let s = "\(v)"
        guard let r = s.range(of: "value = ") else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }
    var out: [String: MIKTrack] = [:]
    while sqlite3_step(st) == SQLITE_ROW {
        guard let bookmark = blob(2), let archive = blob(1) else { continue }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
              let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any], objects.count > 2,
              let root = objects[1] as? [String: Any],
              let arrayIndex = uid(root["MIKBeats_beatTimes"]),
              let array = objects[arrayIndex] as? [String: Any],
              let items = array["NS.objects"] as? [Any] else { continue }
        let beats = items.compactMap { uid($0).flatMap { objects[$0] as? NSNumber }?.doubleValue }
        out[url.path] = MIKTrack(tempo: sqlite3_column_double(st, 0), beats: beats)
    }
    return out
}

func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// Median signed error (seconds) from each reference beat (middle of track) to the nearest grid beat,
/// wrapped to ±period/2.
func phaseError(grid: BeatGrid, reference: [Double]) -> Double? {
    guard reference.count > 16 else { return nil }
    let p = grid.period
    let errs = reference[(reference.count / 8)..<(reference.count * 7 / 8)].map { t -> Double in
        var e = (grid.firstBeat - t).truncatingRemainder(dividingBy: p)
        if e > p / 2 { e -= p }
        if e < -p / 2 { e += p }
        return e
    }
    let s = errs.sorted()
    return s[s.count / 2]
}

/// Fraction of reference downbeats (middle of track) that land on a grid beat with bar position 1.
func downbeatAgreement(grid: BeatGrid, rb: RekordboxGrid) -> Double? {
    let p = grid.period
    var hits = 0, n = 0
    for (i, bar) in rb.bars.enumerated() where bar == 1 && i > rb.bars.count / 8 && i < rb.bars.count * 7 / 8 {
        let t = Double(rb.beatsMs[i]) / 1000
        let k = ((t - grid.firstBeat) / p).rounded()
        guard abs(grid.firstBeat + k * p - t) < p / 4 else { continue }
        let pos = ((grid.firstBarPosition - 1 + Int(k)) % 4 + 4) % 4 + 1
        n += 1
        if pos == 1 { hits += 1 }
    }
    return n > 0 ? Double(hits) / Double(n) : nil
}

// MARK: - Main

let argv = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let args = argv.enumerated().filter { i, a in !a.hasPrefix("--") && (i == 0 || !argv[i - 1].hasPrefix("--")) }.map(\.element)
let set = option("--set") ?? "heldout"
let limit = option("--limit").flatMap(Int.init)
let hintMode = option("--hints") ?? "none"
let dumpPath = option("--dump")
guard let rbPath = args.first else {
    FileHandle.standardError.write(Data("usage: deckhand-grid-eval rekordbox-grids.json [--set heldout|train|all] [--limit N] [--hints none|tag|mik] [--dump out.json]\n".utf8))
    exit(2)
}

let mikPath = ProcessInfo.processInfo.environment["MIK_DB"]
    ?? NSHomeDirectory() + "/Library/Application Support/Mixedinkey/Collection11.mikdb"
let mik = loadMIK(mikPath)
var grids = try JSONDecoder().decode([RekordboxGrid].self, from: Data(contentsOf: URL(fileURLWithPath: rbPath)))
    .filter { mik[$0.path] != nil }
    .filter { g in
        let held = stableHash(g.path) % 5 == 0
        return set == "all" || (set == "heldout") == held
    }
    .sorted { stableHash($0.path) < stableHash($1.path) }
if let limit { grids = Array(grids.prefix(limit)) }
print("tracks: \(grids.count) (\(set)), MIK entries: \(mik.count), hints: \(hintMode)")

let lock = NSLock()
nonisolated(unsafe) var results = [Result?](repeating: nil, count: grids.count)
DispatchQueue.concurrentPerform(iterations: 8) { w in
    for i in stride(from: w, to: grids.count, by: 8) {
        let rb = grids[i]
        let m = mik[rb.path]!
        let start = Date()
        var r = Result(path: rb.path, ok: false)
        r.rbBpm = rb.bpm
        r.mikBpm = m.tempo
        if let audio = try? AudioDecoder.decodeMono(URL(fileURLWithPath: rb.path)) {
            let offset = audio.timelineOffsetSeconds
            r.offsetMs = offset * 1000
            let hint: Double? = switch hintMode {
            case "tag": rb.tagBpm
            case "mik": m.tempo
            default: nil
            }
            let waveforms = WaveformAnalyzer.analyze(audio)
            if let grid = BeatAnalyzer.analyze(TrackAnalyzer.reducedRate(audio), lowBand: waveforms.low, bpmHint: hint)?.shifted(by: offset) {
                r = Result(path: rb.path, ok: true, bpm: grid.bpm, rbBpm: rb.bpm, mikBpm: m.tempo)
                r.offsetMs = offset * 1000
                r.periodMs = grid.period * 1000
                let rbBeats = rb.beatsMs.map { Double($0) / 1000 }
                let mikBeats = m.beats.map { $0 + offset }
                r.phaseRbMs = (phaseError(grid: grid, reference: rbBeats) ?? .nan) * 1000
                r.phaseMikMs = (phaseError(grid: grid, reference: mikBeats) ?? .nan) * 1000
                if let first = mikBeats.first {
                    let mikGrid = BeatGrid(bpm: 60 / ((m.beats.last! - m.beats.first!) / Double(m.beats.count - 1)), firstBeat: first, firstBarPosition: 1)
                    r.mikVsRbMs = (phaseError(grid: mikGrid, reference: rbBeats) ?? .nan) * 1000
                }
                r.downbeatAgree = downbeatAgreement(grid: grid, rb: rb) ?? .nan
            }
        }
        r.seconds = Date().timeIntervalSince(start)
        lock.withLock { results[i] = r }
    }
}

let all = results.compactMap { $0 }
let ok = all.filter(\.ok)
func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%5.1f%%", 100 * Double(n) / Double(d)) }
func ratioError(_ a: Double, _ b: Double) -> Bool {
    let r = a / b
    return [0.5, 2, 2.0 / 3, 1.5, 0.75, 4.0 / 3].contains { abs(r - $0) < 0.02 }
}
func bpmReport(_ name: String, _ ref: (Result) -> Double) {
    let d = ok.map { abs($0.bpm - ref($0)) }
    let octave = ok.filter { ratioError($0.bpm, ref($0)) }.count
    print("  BPM vs \(name): ±0.05 \(pct(d.filter { $0 <= 0.05 }.count, all.count))  ±0.01 \(pct(d.filter { $0 <= 0.0101 }.count, all.count))  ratio errors \(pct(octave, all.count))")
}
func phaseReport(_ name: String, _ e: (Result) -> Double) {
    // Only tracks whose tempo matches the reference within 0.5 BPM.
    let rows = ok.filter { abs($0.bpm - $0.rbBpm) <= 0.5 || abs($0.bpm - $0.mikBpm) <= 0.5 }.map { (e($0), $0.periodMs) }.filter { !$0.0.isNaN }
    let a = rows.map { abs($0.0) }.sorted()
    guard !a.isEmpty else { return }
    let half = rows.filter { abs(abs($0.0) - $0.1 / 2) < $0.1 * 0.1 }.count
    print("  Phase vs \(name) (n=\(a.count)): median \(String(format: "%.1f", a[a.count / 2])) ms  ≤10ms \(pct(a.filter { $0 <= 10 }.count, a.count))  ≤20ms \(pct(a.filter { $0 <= 20 }.count, a.count))  ≥40ms \(pct(a.filter { $0 >= 40 }.count, a.count))  half-beat \(pct(half, a.count))")
}
print("analyzed \(ok.count)/\(all.count)")
bpmReport("MIK", \.mikBpm)
bpmReport("Rekordbox", \.rbBpm)
phaseReport("MIK", \.phaseMikMs)
phaseReport("Rekordbox", \.phaseRbMs)
let db = ok.map(\.downbeatAgree).filter { !$0.isNaN }
print("  Downbeat vs Rekordbox: \(pct(db.filter { $0 >= 0.5 }.count, db.count)) of tracks")
let m = all.map(\.mikVsRbMs).filter { !$0.isNaN }.sorted()
if !m.isEmpty {
    print("  [reference] MIK (+timeline offset) vs Rekordbox phase: median |e| \(String(format: "%.1f", m.map(abs).sorted()[m.count / 2])) ms, signed median \(String(format: "%.1f", m[m.count / 2])) ms, ≤10ms \(pct(m.filter { abs($0) <= 10 }.count, m.count))")
}
let secs = all.map(\.seconds).sorted()
print("  time/track: median \(String(format: "%.2f", secs[secs.count / 2]))s (8 parallel)")
if let dumpPath {
    let e = JSONEncoder()
    e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    try e.encode(all).write(to: URL(fileURLWithPath: dumpPath))
}
