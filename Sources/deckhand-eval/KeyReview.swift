import Analysis
import DeckhandCore
import EvalSupport
import Foundation

/// `deckhand-eval key-review <out dir> [limit] [render]`
///
/// Lists library tracks where Deckhand's key differs from Mixed In Key's, most interesting first
/// (both sides confident), and renders audition WAVs for the top `render` (default 20): the same
/// passage twice, first with a sustained triad of Deckhand's key, then of MIK's. Whichever drone
/// sits comfortably under the music is the right key.
func reviewKeys(out: String, limit: Int?, render: Int) throws {
    guard let mik = MixedInKeyLibrary.load() else {
        print("No readable Mixed In Key 11 database.")
        return
    }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var tracks = mik.tracks.filter { $0.value.key != nil && FileManager.default.fileExists(atPath: $0.key) }
        .sorted { $0.key < $1.key }
    if let limit { tracks = Array(tracks.prefix(limit)) }
    print("Analyzing \(tracks.count) tracks…")

    struct Row {
        let path: String
        let ours: MusicalKey
        let ourProbability: Double
        let theirs: MusicalKey
        let theirConfidence: Double
        var interest: Double { min(ourProbability, theirConfidence) }
    }
    let lock = NSLock()
    nonisolated(unsafe) var rows: [Row] = []
    nonisolated(unsafe) var agreed = 0
    let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for i in stride(from: w, to: tracks.count, by: workers) {
            let (path, t) = tracks[i]
            guard let decoded = try? AudioDecoder.decodeMono(URL(fileURLWithPath: path)),
                  let best = KeyAnalyzer.candidates(decoded).first else { continue }
            lock.withLock {
                if best.key == t.key {
                    agreed += 1
                } else {
                    rows.append(Row(path: path, ours: best.key, ourProbability: best.probability,
                                    theirs: t.key!, theirConfidence: t.keyConfidence ?? 0))
                }
            }
        }
    }
    rows.sort { $0.interest > $1.interest }
    let total = agreed + rows.count
    print(String(format: "\nAgree with MIK on %d of %d (%.1f%%). Disagreements, most confident first:\n",
                 agreed, total, 100 * Double(agreed) / Double(max(1, total))))
    print("  #  DECKHAND        MIK             TRACK")
    for (i, r) in rows.enumerated() {
        let name = ((r.path as NSString).lastPathComponent as NSString).deletingPathExtension
        print(String(format: "%3d  %-4@ %-4@ %3.0f%%   %-4@ %-4@ %3.0f%%   %@", i + 1,
                     r.ours.alphanumeric as NSString, r.ours.classic as NSString, 100 * r.ourProbability,
                     r.theirs.alphanumeric as NSString, r.theirs.classic as NSString, 100 * r.theirConfidence,
                     name as NSString))
    }

    let toRender = rows.prefix(render)
    guard !toRender.isEmpty else { return }
    print("\nRendering \(toRender.count) audition files to \(out)")
    for (i, r) in toRender.enumerated() {
        guard let audio = try? AudioDecoder.decodeMono(URL(fileURLWithPath: r.path)) else { continue }
        let name = ((r.path as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "_")
        let file = String(format: "%03d 1=%@ (Deckhand) 2=%@ (MIK) - %@.wav", i + 1,
                          r.ours.alphanumeric, r.theirs.alphanumeric, name)
        let samples = Audition.render(audio, first: r.ours, second: r.theirs)
        try Audition.writeWAV(samples, sampleRate: audio.sampleRate,
                              to: URL(fileURLWithPath: (out as NSString).appendingPathComponent(file)))
    }
    print("Listen to each file: part 1 has Deckhand's key as a drone, part 2 MIK's. The drone that blends is right.")
}

enum Audition {
    static let passageSeconds = 16.0
    static let gapSeconds = 0.75

    /// The loudest `passageSeconds` window in the middle 60% of the track, played under each key's drone.
    static func render(_ audio: DecodedAudio, first: MusicalKey, second: MusicalKey) -> [Float] {
        let sr = audio.sampleRate
        let x = audio.samples
        let length = min(x.count, Int(passageSeconds * Double(sr)))
        let start = loudestWindow(x, length: length, sampleRate: sr)
        var passage = Array(x[start..<(start + length)])
        let peak = passage.map(abs).max() ?? 1
        if peak > 0 { passage = passage.map { $0 / peak * 0.6 } }

        let a = zip(passage, drone(first, count: length, sampleRate: sr)).map(+)
        let b = zip(passage, drone(second, count: length, sampleRate: sr)).map(+)
        return a + [Float](repeating: 0, count: Int(gapSeconds * Double(sr))) + b
    }

    static func loudestWindow(_ x: [Float], length: Int, sampleRate: Int) -> Int {
        guard x.count > length else { return 0 }
        let lo = Int(Double(x.count) * 0.2), hi = max(lo, min(x.count - length, Int(Double(x.count) * 0.8) - length))
        guard hi > lo else { return max(0, min(lo, x.count - length)) }
        let step = sampleRate / 2
        var best = lo, bestEnergy = -1.0
        for s in stride(from: lo, through: hi, by: step) {
            var e = 0.0
            for i in stride(from: s, to: s + length, by: 64) { e += Double(x[i] * x[i]) }
            if e > bestEnergy { bestEnergy = e; best = s }
        }
        return best
    }

    /// Sustained triad (root, third, fifth around C3–B3) over a root an octave below, with soft
    /// attack/release so it sits under the music.
    static func drone(_ key: MusicalKey, count: Int, sampleRate: Int) -> [Float] {
        let root = 48 + key.tonic
        let notes: [(midi: Int, gain: Float)] = [
            (root - 12, 0.10), (root, 0.08), (root + (key.mode == .minor ? 3 : 4), 0.07), (root + 7, 0.07),
        ]
        let sr = Double(sampleRate)
        let fade = Int(0.3 * sr)
        var out = [Float](repeating: 0, count: count)
        for (midi, gain) in notes {
            let f = 440 * pow(2, Double(midi - 69) / 12)
            let w = 2 * Double.pi * f / sr
            for i in 0..<count {
                let t = Double(i) * w
                out[i] += gain * Float(sin(t) + 0.3 * sin(2 * t) + 0.1 * sin(3 * t))
            }
        }
        for i in 0..<min(fade, count) {
            let g = Float(i) / Float(fade)
            out[i] *= g
            out[count - 1 - i] *= g
        }
        return out
    }

    static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try d.write(to: url)
    }
}
