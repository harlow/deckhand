import Analysis
import CKeyFinder
import CryptoKit
import DeckhandCore
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
            let audio = TrackAnalyzer.reducedRate(decoded)
            let start = Date()
            let pred = KeyAnalyzer.analyze(audio)
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
