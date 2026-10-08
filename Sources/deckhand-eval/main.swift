// Evaluates BPM, beat grid and key analysis against a ground-truth JSON exported from Rekordbox.
// Usage: deckhand-eval groundtruth.json [limit]   (ground truth from Scripts/export-groundtruth.py)
// Env: EVAL_HINTS=1 use TBPM tags as BPM hints; EVAL_VERBOSE / EVAL_TIMING / EVAL_PHASE / EVAL_PHASE_LIST print details.
import Analysis
import DeckhandCore
import Foundation

struct Truth: Decodable {
    let path: String
    let bpm: Double
    let key: String?
    let firstBeatMs: Int
    let firstBar: Int
    let tagBpm: Double?
    let tagKey: String?
}

struct Outcome {
    let truth: Truth
    let bpm: Double
    let grid: BeatGrid?
    let key: MusicalKey?
    let seconds: Double
    let error: String?
}

let args = CommandLine.arguments
if args.count >= 4, args[1] == "key-eval" {
    try evaluateKeys(featuresDir: args[2], mikPath: args[3])
    exit(0)
}
if args.count >= 3, args[1] == "key-review" {
    try reviewKeys(out: args[2], limit: args.count >= 4 ? Int(args[3]) : nil,
                   render: args.count >= 5 ? Int(args[4]) ?? 20 : 20)
    exit(0)
}
if args.count >= 4, args[1] == "key-eval-dataset" {
    try evaluateKeyDataset(audioDir: args[2], labelsDir: args[3], linearOnly: args.count >= 5 && args[4] == "linear")
    exit(0)
}
if args.count >= 5, args[1] == "key-features-dataset" {
    try dumpDatasetKeyFeatures(audioDir: args[2], labelsDir: args[3], out: args[4])
    exit(0)
}
if args.count >= 4, args[1] == "key-features" {
    try dumpKeyFeatures(root: args[2], out: args[3])
    exit(0)
}
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: deckhand-eval groundtruth.json [limit]\n".data(using: .utf8)!)
    exit(2)
}
var truths = try JSONDecoder().decode([Truth].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
if args.count >= 3, let n = Int(args[2]) { truths = Array(truths.prefix(n)) }

// EVAL_HINTS=1 passes the file's TBPM tag as a BPM hint (key is still analyzed for comparison).
let useHints = ProcessInfo.processInfo.environment["EVAL_HINTS"] != nil
let lock = NSLock()
var outcomes = [Outcome?](repeating: nil, count: truths.count)
let workers = 6
DispatchQueue.concurrentPerform(iterations: workers) { w in
  for i in stride(from: w, to: truths.count, by: workers) {
    let t = truths[i]
    let start = Date()
    var outcome: Outcome
    do {
        var marks = [Date()]
        let decoded = try AudioDecoder.decodeMono(URL(fileURLWithPath: t.path))
        marks.append(Date())
        let waveforms = WaveformAnalyzer.analyze(decoded)
        marks.append(Date())
        let full = decoded
        let audio = ProcessInfo.processInfo.environment["FULL_RATE"] != nil ? full : TrackAnalyzer.reducedRate(full)
        let hint = useHints ? t.tagBpm : nil
        let grid = BeatAnalyzer.analyze(audio, lowBand: waveforms.low, bpmHint: hint)?.shifted(by: full.timelineOffsetSeconds)
        marks.append(Date())
        let key = KeyAnalyzer.analyze(audio)
        marks.append(Date())
        if ProcessInfo.processInfo.environment["EVAL_PHASE"] != nil, let g = grid {
            let raw = BeatAnalyzer.analyze(audio, lowBand: waveforms.low)!
            print(String(format: "phase: rb first %d ms | ours player %.1f ms (decoded %.1f, offset %d frames) period %.1f ms  %@", t.firstBeatMs, g.firstBeat * 1000, raw.firstBeat * 1000, audio.timelineOffsetFrames, g.period * 1000, (t.path as NSString).lastPathComponent))
        }
        if ProcessInfo.processInfo.environment["EVAL_TIMING"] != nil {
            let d = zip(marks.dropFirst(), marks).map { String(format: "%.2f", $0.timeIntervalSince($1)) }
            print("timing decode/wave/beats/key: \(d.joined(separator: " / ")) sr=\(audio.sampleRate)")
        }
        outcome = Outcome(truth: t, bpm: grid?.bpm ?? 0, grid: grid, key: key,
                          seconds: Date().timeIntervalSince(start), error: nil)
    } catch {
        outcome = Outcome(truth: t, bpm: 0, grid: nil, key: nil, seconds: 0, error: "\(error)")
        print("FAILED: \(error)")
    }
    lock.lock(); outcomes[i] = outcome; lock.unlock()
  }
}

let results = outcomes.compactMap { $0 }.filter { $0.error == nil }
let n = Double(results.count)
func pct(_ c: Int) -> String { String(format: "%5.1f%%", 100 * Double(c) / n) }

let bpmExact = results.filter { abs($0.bpm - $0.truth.bpm) <= 0.05 }
let bpmClose = results.filter { abs($0.bpm - $0.truth.bpm) <= 0.5 }
let octave = results.filter { r in [2.0, 0.5, 1.5, 2.0 / 3].contains { abs(r.bpm - r.truth.bpm * $0) <= 0.1 } }

enum KeyRelation { case exact, relative, fifth, parallel, other, missing }
func relation(_ ours: MusicalKey?, _ truthText: String?) -> KeyRelation {
    guard let ours, let truthText, let truth = MusicalKey(parsing: truthText) else { return .missing }
    if ours == truth { return .exact }
    if ours.camelotNumber == truth.camelotNumber { return .relative }
    if ours.mode == truth.mode, [1, 11].contains((ours.camelotNumber - truth.camelotNumber + 12) % 12) { return .fifth }
    if ours.tonic == truth.tonic { return .parallel }
    return .other
}
func keyReport(_ label: String, _ pick: (Outcome) -> MusicalKey?) {
    let rel = results.map { relation(pick($0), $0.truth.key) }
    func c(_ r: KeyRelation) -> Int { rel.filter { $0 == r }.count }
    print("  \(label): exact \(pct(c(.exact)))  relative \(pct(c(.relative)))  fifth \(pct(c(.fifth)))  parallel \(pct(c(.parallel)))  other \(pct(c(.other)))  missing \(pct(c(.missing)))")
}

// Phase error at Rekordbox's first beat, for tracks with matching BPM.
var phaseErrors = [Double]()
var signedPhaseErrors = [Double]()
var downbeatMatches = 0
for r in bpmExact {
    guard let g = r.grid else { continue }
    let p = g.period * 1000
    let rbFirst = Double(r.truth.firstBeatMs)
    var d = (rbFirst - g.firstBeat * 1000).truncatingRemainder(dividingBy: p)
    if d > p / 2 { d -= p }
    if d < -p / 2 { d += p }
    phaseErrors.append(abs(d))
    if ProcessInfo.processInfo.environment["EVAL_PHASE_LIST"] != nil { print(String(format: "PH %.0f\t%@", d, r.truth.path)) }
    signedPhaseErrors.append(d)
    let beatIndex = Int(((rbFirst - g.firstBeat * 1000) / p).rounded())
    let ourBar = ((g.firstBarPosition - 1 + beatIndex) % 4 + 4) % 4 + 1
    if ourBar == r.truth.firstBar { downbeatMatches += 1 }
}
phaseErrors.sort()
let pe = phaseErrors.isEmpty ? 0 : phaseErrors[phaseErrors.count / 2]

print("mode: \(useHints ? "BPM tag hints" : "audio only")")
print("tracks evaluated: \(results.count) (\(outcomes.count - results.count) failed)")
print("BPM  exact ±0.05: \(pct(bpmExact.count))  within ±0.5: \(pct(bpmClose.count))  octave/ratio errors: \(pct(octave.count))")
print(String(format: "Grid phase (BPM-matched, n=%d): median %.1f ms, ≤10ms %.1f%%, ≤20ms %.1f%%, downbeat match %.1f%%",
             phaseErrors.count, pe,
             100 * Double(phaseErrors.filter { $0 <= 10 }.count) / Double(max(1, phaseErrors.count)),
             100 * Double(phaseErrors.filter { $0 <= 20 }.count) / Double(max(1, phaseErrors.count)),
             100 * Double(downbeatMatches) / Double(max(1, phaseErrors.count))))
let sortedSigned = signedPhaseErrors.sorted()
if !sortedSigned.isEmpty {
    print(String(format: "  signed phase error (truth - ours) median %.1f ms; all: %@", sortedSigned[sortedSigned.count / 2],
                 sortedSigned.map { String(format: "%.0f", $0) }.joined(separator: " ")))
}
print("Key:")
keyReport("libKeyFinder vs Rekordbox", { $0.key })
// Second reference: the files' own ID3 tags (integer TBPM, Camelot TKEY).
func bpmMatches(_ a: Double, _ tag: Double, octaveTolerant: Bool) -> Bool {
    let ratios = octaveTolerant ? [1.0, 2.0, 0.5] : [1.0]
    return ratios.contains { abs(a - tag * $0) <= 0.5 }
}
let tagged = results.filter { $0.truth.tagBpm != nil }
func tagPct(_ c: Int, _ total: Int) -> String { String(format: "%5.1f%%", 100 * Double(c) / Double(max(1, total))) }
print("Vs file tags (n=\(tagged.count) with TBPM, \(results.filter { $0.truth.tagKey != nil }.count) with TKEY):")
print("  BPM ±0.5: ours \(tagPct(tagged.filter { bpmMatches($0.bpm, $0.truth.tagBpm!, octaveTolerant: false) }.count, tagged.count))"
    + "  octave-tolerant \(tagPct(tagged.filter { bpmMatches($0.bpm, $0.truth.tagBpm!, octaveTolerant: true) }.count, tagged.count))"
    + " | Rekordbox \(tagPct(tagged.filter { bpmMatches($0.truth.bpm, $0.truth.tagBpm!, octaveTolerant: false) }.count, tagged.count))"
    + "  octave-tolerant \(tagPct(tagged.filter { bpmMatches($0.truth.bpm, $0.truth.tagBpm!, octaveTolerant: true) }.count, tagged.count))")
func tagKeyReport(_ label: String, _ pick: (Outcome) -> MusicalKey?) {
    let withKey = results.filter { $0.truth.tagKey != nil }
    let rel = withKey.map { relation(pick($0), $0.truth.tagKey) }
    func c(_ r: KeyRelation) -> String { tagPct(rel.filter { $0 == r }.count, withKey.count) }
    print("  \(label): exact \(c(.exact))  relative \(c(.relative))  fifth \(c(.fifth))  parallel \(c(.parallel))  other \(c(.other))")
}
tagKeyReport("key ours (libKeyFinder)", { $0.key })
tagKeyReport("key Rekordbox          ", { $0.truth.key.flatMap(MusicalKey.init(parsing:)) })

print(String(format: "Avg analysis time per track (concurrent): %.2f s", results.map(\.seconds).reduce(0, +) / n))

if ProcessInfo.processInfo.environment["EVAL_VERBOSE"] != nil {
    for r in results where abs(r.bpm - r.truth.bpm) > 0.05 {
        print(String(format: "  BPM miss: ours %.2f truth %.2f  %@", r.bpm, r.truth.bpm, (r.truth.path as NSString).lastPathComponent))
    }
}
