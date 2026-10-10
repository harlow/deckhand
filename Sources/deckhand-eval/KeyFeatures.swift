import Analysis
import CKeyFinder
import CryptoKit
import DeckhandCore
import EvalSupport
import Foundation

/// `deckhand-eval key-features <music root> <out dir>`: dumps libKeyFinder chromagrams and
/// tag keys for every tagged audio file, for offline key-model experiments.
func dumpKeyFeatures(root: String, out: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    let exts: Set<String> = ["mp3", "m4a", "aif", "aiff", "wav", "flac"]
    var files: [String] = []
    if let e = fm.enumerator(atPath: root) {
        for case let rel as String in e where exts.contains((rel as NSString).pathExtension.lowercased()) {
            files.append((root as NSString).appendingPathComponent(rel))
        }
    }
    files.sort()
    print("\(files.count) audio files")

    struct Entry: Encodable { let i: Int; let path: String; let tag: String; let baseline: String?; let hops: Int; let seconds: Double }
    let lock = NSLock()
    nonisolated(unsafe) var entries: [Entry] = []
    let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: files.count, by: workers) {
            let path = files[i]
            guard let tag = FileTagReader.read(URL(fileURLWithPath: path)).key else { continue }
            guard let decoded = try? AudioDecoder.decodeMono(URL(fileURLWithPath: path)) else { continue }
            let audio = TrackAnalyzer.reducedRate(decoded)
            let start = Date()
            guard let (values, hops) = KeyAnalyzer.chromagram(audio) else { continue }
            let seconds = Date().timeIntervalSince(start)
            let floats = values.map(Float.init)
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: URL(fileURLWithPath: "\(out)/\(i).f32"))
            let baseline: String? = nil
            lock.withLock {
                entries.append(Entry(i: i, path: path, tag: tag.alphanumeric, baseline: baseline, hops: hops, seconds: seconds))
                if entries.count % 100 == 0 { print("\(entries.count) done") }
            }
        }
    }
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    try enc.encode(entries.sorted { $0.i < $1.i }).write(to: URL(fileURLWithPath: "\(out)/index.json"))
    print("wrote \(entries.count) tracks")
}

/// `deckhand-eval key-eval <features dir> <mik.json>`: runs the shipping KeyAnalyzer on the held-out
/// split (album folders whose MD5 ≡ 0 mod 5) and scores it against Mixed In Key.
func evaluateKeys(featuresDir: String, mikPath: String) throws {
    struct Entry: Decodable { let path: String; let tag: String }
    struct Mik: Decodable { let path: String; let conf: Double }
    let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: "\(featuresDir)/index.json")))
    let conf = Dictionary(try JSONDecoder().decode([Mik].self, from: Data(contentsOf: URL(fileURLWithPath: mikPath)))
        .map { ($0.path, $0.conf) }, uniquingKeysWith: { a, _ in a })
    let held = entries.filter {
        let digest = Insecure.MD5.hash(data: Data(($0.path as NSString).deletingLastPathComponent.utf8))
        let value = digest.reduce(BigMod5()) { $0.appending($1) }
        return value.remainder == 0
    }
    let lock = NSLock()
    nonisolated(unsafe) var results: [(truth: MusicalKey, pred: MusicalKey?, conf: Double, seconds: Double)] = []
    let env = ProcessInfo.processInfo.environment
    let workers = env["KEY_EVAL_WORKERS"].flatMap(Int.init) ?? 8
    let limit = min(held.count, env["KEY_EVAL_LIMIT"].flatMap(Int.init) ?? held.count)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: limit, by: workers) {
            let e = held[i]
            guard let truth = MusicalKey(parsing: e.tag),
                  let decoded = try? AudioDecoder.decodeMono(URL(fileURLWithPath: e.path)) else { continue }
            let start = Date()
            let pred = KeyAnalyzer.analyze(decoded)
            let seconds = Date().timeIntervalSince(start)
            lock.withLock { results.append((truth, pred, conf[e.path] ?? 0.5, seconds)) }
        }
    }
    func line(_ name: String, _ rs: [(truth: MusicalKey, pred: MusicalKey?, conf: Double, seconds: Double)]) {
        let exact = rs.filter { $0.pred == $0.truth }.count
        print(String(format: "%-12@ n=%d exact %.1f%%", name as NSString, rs.count, 100 * Double(exact) / Double(max(1, rs.count))))
    }
    line("held-out", results)
    line("conf>=0.8", results.filter { $0.conf >= 0.8 })
    line("conf<0.5", results.filter { $0.conf < 0.5 })
    print(String(format: "key analysis %.2fs/track (avg, chromagram + model)", results.map(\.seconds).reduce(0, +) / Double(max(1, results.count))))
}

/// Remainder mod 5 of a big-endian byte string.
struct BigMod5 {
    var remainder = 0
    func appending(_ byte: UInt8) -> BigMod5 { BigMod5(remainder: (remainder * 256 + Int(byte)) % 5) }
}

/// `deckhand-eval key-features-dataset <audio dir> <labels dir> <out dir>`: dumps chromagrams for a
/// key dataset (e.g. GiantSteps, Beatport EDM Key) whose labels are `<labels dir>/<audio name>.txt`.
/// Labels are stored verbatim; the training script normalizes them.
func dumpDatasetKeyFeatures(audioDir: String, labelsDir: String, out: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    let files = try fm.contentsOfDirectory(atPath: audioDir)
        .filter { !$0.hasPrefix("._") && $0.lowercased().hasSuffix(".mp3") }
        .sorted()
    print("\(files.count) audio files")

    struct Entry: Encodable { let i: Int; let path: String; let label: String; let hops: Int }
    let lock = NSLock()
    nonisolated(unsafe) var entries: [Entry] = []
    let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: files.count, by: workers) {
            let name = files[i]
            let labelPath = (labelsDir as NSString).appendingPathComponent((name as NSString).deletingPathExtension + ".txt")
            guard let label = try? String(contentsOfFile: labelPath, encoding: .utf8) else { continue }
            let path = (audioDir as NSString).appendingPathComponent(name)
            guard let decoded = try? AudioDecoder.decodeMono(URL(fileURLWithPath: path)),
                  let (values, hops) = KeyAnalyzer.chromagram(TrackAnalyzer.reducedRate(decoded)) else { continue }
            let data = values.map(Float.init).withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: URL(fileURLWithPath: "\(out)/\(i).f32"))
            lock.withLock {
                entries.append(Entry(i: i, path: path, label: label.trimmingCharacters(in: .whitespacesAndNewlines), hops: hops))
            }
        }
    }
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    try enc.encode(entries.sorted { $0.i < $1.i }).write(to: URL(fileURLWithPath: "\(out)/index.json"))
    print("wrote \(entries.count) tracks")
}

/// `deckhand-eval key-eval-dataset <audio dir> <labels dir> [linear]`: scores the shipping key
/// analyzer (or, with `linear`, the linear model alone) on a labelled dataset. Labels: `<name>.txt`
/// ("F minor", "Eb major", GiantSteps+ modal names) or GiantSteps `<id>.LOFI.key` files.
func evaluateKeyDataset(audioDir: String, labelsDir: String, linearOnly: Bool) throws {
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(atPath: audioDir).filter { !$0.hasPrefix("._") && $0.lowercased().hasSuffix(".mp3") }.sorted()
    let labelFiles = try fm.contentsOfDirectory(atPath: labelsDir)
    func label(for name: String) -> MusicalKey? {
        let base = (name as NSString).deletingPathExtension
        let id = base.split(separator: " ").first.map(String.init) ?? base
        let candidates = [base + ".txt", id + ".LOFI.key", id + ".key"]
        guard let f = candidates.first(where: labelFiles.contains),
              let text = try? String(contentsOfFile: (labelsDir as NSString).appendingPathComponent(f), encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, !text.contains("|"), !text.contains("/") else { return nil }
        let minor: Set<String> = ["minor", "aeolian", "dorian", "phrygian", "locrian"]
        let major: Set<String> = ["major", "ionian", "mixolydian", "lydian"]
        let mode = parts[1].lowercased()
        guard minor.contains(mode) || major.contains(mode) else { return nil }
        return MusicalKey(parsing: String(parts[0]) + (minor.contains(mode) ? "m" : ""))
    }
    let lock = NSLock()
    nonisolated(unsafe) var results: [(truth: MusicalKey, pred: MusicalKey?, seconds: Double)] = []
    let workers = ProcessInfo.processInfo.environment["KEY_EVAL_WORKERS"].flatMap(Int.init) ?? 6
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: files.count, by: workers) {
            guard let truth = label(for: files[i]),
                  let decoded = try? AudioDecoder.decodeMono(URL(fileURLWithPath: (audioDir as NSString).appendingPathComponent(files[i]))) else { continue }
            let start = Date()
            let pred = KeyAnalyzer.candidates(decoded, useSKey: !linearOnly).first?.key
            let seconds = Date().timeIntervalSince(start)
            lock.withLock { results.append((truth, pred, seconds)) }
        }
    }
    let weights: [KeyRelation: Double] = [.exact: 1, .fifth: 0.5, .relative: 0.3, .parallel: 0.2, .other: 0, .missing: 0]
    let rel = results.map { relation($0.pred, $0.truth.classic) }
    let n = Double(max(1, rel.count))
    let exact = Double(rel.filter { $0 == .exact }.count) / n
    let mirex = rel.reduce(0) { $0 + weights[$1]! } / n
    let majors = results.filter { $0.truth.mode == .major }
    let majorExact = Double(majors.filter { $0.pred == $0.truth }.count) / Double(max(1, majors.count))
    let secs = results.map(\.seconds).sorted()
    print(String(format: "n=%d exact %.1f%%  MIREX %.1f  major exact %.1f%% (n=%d)  key analysis median %.3fs/track",
                 rel.count, 100 * exact, 100 * mirex, 100 * majorExact, majors.count, secs.isEmpty ? 0 : secs[secs.count / 2]))
}

/// `deckhand-eval key-dump <paths.txt> <out dir>`: for each audio file listed (one path per line),
/// writes the key ensemble's inputs as the shipping code computes them, for offline S-KEY fine-tuning:
/// `index.jsonl` lines {path, linear (24 log-probs), skey (24 probs or null), clips, file} and
/// `<file>` with the clips' log-CQTs as float16 (clips × 84 × 646). Resumable: listed paths
/// already in the index are skipped.
func dumpKeyComponents(list: String, out: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    let indexPath = (out as NSString).appendingPathComponent("index.jsonl")
    struct Entry: Codable { let path: String; let linear: [Double]; let skey: [Double]?; let clips: Int; let file: String }
    let done = Set(((try? String(contentsOfFile: indexPath, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)).path })
    let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        .filter { !$0.isEmpty && !done.contains($0) }
    if !fm.fileExists(atPath: indexPath) { fm.createFile(atPath: indexPath, contents: nil) }
    let index = try FileHandle(forWritingTo: URL(fileURLWithPath: indexPath))
    index.seekToEndOfFile()
    let lock = NSLock()
    nonisolated(unsafe) var finished = 0
    let workers = ProcessInfo.processInfo.environment["KEY_EVAL_WORKERS"].flatMap(Int.init) ?? 8
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: paths.count, by: workers) {
            let path = paths[i]
            guard let audio = try? AudioDecoder.decodeMono(URL(fileURLWithPath: path)),
                  let c = KeyAnalyzer.components(audio) else { continue }
            let file = Insecure.SHA1.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".f16"
            var half = [Float16]()
            half.reserveCapacity(c.clips.count * 84 * 646)
            for clip in c.clips { half += clip.map(Float16.init) }
            try? half.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent(file)))
            guard let line = try? JSONEncoder().encode(Entry(path: path, linear: c.linear, skey: c.skey, clips: c.clips.count, file: file)) else { continue }
            lock.withLock {
                index.write(line + Data("\n".utf8))
                finished += 1
                if finished % 100 == 0 { print("\(finished)/\(paths.count)") }
            }
        }
    }
    try index.close()
    print("dumped \(finished) of \(paths.count)")
}

/// `deckhand-eval mik-keys <out.json>`: Mixed In Key's key and confidence per file, [{path, key, conf}].
func dumpMixedInKeyKeys(out: String) throws {
    guard let lib = MixedInKeyLibrary.load() else { throw NSError(domain: "mik", code: 1, userInfo: [NSLocalizedDescriptionKey: "no MIK library"]) }
    struct Row: Encodable { let path: String; let key: String; let conf: Double? }
    let rows = lib.tracks.compactMap { path, t in t.key.map { Row(path: path, key: $0.classic, conf: t.keyConfidence) } }
    try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: out))
    print("\(rows.count) MIK keys")
}
