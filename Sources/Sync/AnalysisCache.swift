import Analysis
import DeckhandCore
import Foundation

/// Persistent analysis results keyed by audio content hash, independent of any USB drive.
/// Lives in ~/Library/Application Support/Deckhand.
public final class AnalysisCache: @unchecked Sendable {
    let root: URL
    private var fingerprints: [String: String]
    private let lock = NSLock()

    public static func defaultRoot() -> URL {
        if let dir = ProcessInfo.processInfo.environment["DECKHAND_CACHE_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckhand")
    }

    public init(root: URL = AnalysisCache.defaultRoot()) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("analysis"), withIntermediateDirectories: true)
        let fp = root.appendingPathComponent("fingerprints.json")
        fingerprints = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fp))) ?? [:]
    }

    /// Hash of a file's audio payload (ignores tags), reusing a cached hash when path, size and mtime are unchanged.
    public func contentHash(of url: URL) throws -> String {
        let key = "\(AudioHash.scheme)\(url.path)|\(FileOps.size(url))|\(FileOps.modificationDate(url)?.timeIntervalSince1970 ?? 0)"
        if let h = lock.withLock({ fingerprints[key] }) { return h }
        let h = try AudioHash.hash(url)
        lock.withLock { fingerprints[key] = h }
        return h
    }

    public func saveFingerprints() throws {
        let data = try lock.withLock { try JSONEncoder().encode(fingerprints) }
        try data.write(to: root.appendingPathComponent("fingerprints.json"), options: .atomic)
    }

    private func path(_ hash: String) -> URL {
        root.appendingPathComponent("analysis").appendingPathComponent("\(hash).json")
    }

    /// Cached analysis made by the current algorithm versions under `policy`.
    public func analysis(forHash hash: String, policy: AnalysisPolicy) -> TrackAnalysis? {
        load(hash, policy)?.analysis
    }

    /// Cue points and energy detected alongside the analysis.
    public func detectedCues(forHash hash: String, policy: AnalysisPolicy) -> CueAnalyzer.Result? {
        guard let stored = load(hash, policy), let cues = stored.cues else { return nil }
        return CueAnalyzer.Result(cues: cues.map { .init(timeMs: $0[0], energy: $0[1]) }, energy: stored.trackEnergy)
    }

    public func store(_ analysis: TrackAnalysis, cues: CueAnalyzer.Result?, forHash hash: String, policy: AnalysisPolicy) throws {
        var stored = Stored(analysis)
        stored.policy = policy.fingerprint
        stored.cueVersion = CueAnalyzer.version
        stored.cues = cues?.cues.map { [$0.timeMs, $0.energy] }
        stored.trackEnergy = cues?.energy
        try JSONEncoder().encode(stored).write(to: path(hash), options: .atomic)
    }

    private func load(_ hash: String, _ policy: AnalysisPolicy) -> Stored? {
        guard let data = try? Data(contentsOf: path(hash)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == TrackAnalysis.currentVersion,
              stored.cueVersion == CueAnalyzer.version,
              stored.policy == policy.fingerprint else { return nil }
        return stored
    }

    /// Compact on-disk form: waveforms stored as sqrt-companded bytes.
    private struct Stored: Codable {
        var version: Int
        var policy: String?
        var bpmSource: ValueSource?
        var keySource: ValueSource?
        var cueVersion: Int?
        /// [timeMs, energy] pairs.
        var cues: [[Int]]?
        var trackEnergy: Int?
        var durationSeconds: Double
        var sampleRate: Int
        var bpm: Double
        var beats: [TrackAnalysis.Beat]
        var key: MusicalKey?
        var peak, rms, low, mid, high: Data

        init(_ a: TrackAnalysis) {
            version = a.version
            durationSeconds = a.durationSeconds
            sampleRate = a.sampleRate
            bpm = a.bpm
            beats = a.beats
            key = a.key
            bpmSource = a.bpmSource
            keySource = a.keySource
            peak = Self.pack(a.waveforms.peak)
            rms = Self.pack(a.waveforms.rms)
            low = Self.pack(a.waveforms.low)
            mid = Self.pack(a.waveforms.mid)
            high = Self.pack(a.waveforms.high)
        }

        var analysis: TrackAnalysis {
            var a = TrackAnalysis(version: version, durationSeconds: durationSeconds, sampleRate: sampleRate, bpm: bpm,
                          beats: beats, key: key,
                          waveforms: .init(peak: Self.unpack(peak), rms: Self.unpack(rms), low: Self.unpack(low),
                                           mid: Self.unpack(mid), high: Self.unpack(high)))
            a.bpmSource = bpmSource ?? .analysis
            a.keySource = keySource ?? .analysis
            return a
        }

        static func pack(_ x: [Float]) -> Data {
            Data(x.map { UInt8(max(0, min(255, ($0.squareRoot() * 255).rounded()))) })
        }

        static func unpack(_ d: Data) -> [Float] {
            d.map { let v = Float($0) / 255; return v * v }
        }
    }
}
