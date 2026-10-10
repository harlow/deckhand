import Analysis
import DeckhandCore
import Foundation

/// Persistent analysis results keyed by audio content hash, independent of any USB drive.
/// Lives in ~/Library/Application Support/Deckhand.
public final class AnalysisCache: @unchecked Sendable {
    let root: URL
    private var fingerprints: [String: String]
    private let lock = NSLock()
    /// Recently decoded entries: callers read a track's analysis, sections and cues one after another,
    /// and each file (waveforms included) is large, so decode it once.
    private var recent: [String: Stored] = [:]
    private var recentOrder: [String] = []
    private static let recentLimit = 32

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

    /// Cached analysis made by the current algorithm versions.
    public func analysis(forHash hash: String) -> TrackAnalysis? {
        load(hash)?.analysis
    }

    /// Song structure detected alongside the analysis.
    public func sections(forHash hash: String) -> [StructureAnalyzer.Section]? {
        load(hash)?.sections?.compactMap { s in
            StructureAnalyzer.Kind(rawValue: s.kind).map {
                StructureAnalyzer.Section(kind: $0, startBeat: s.startBeat, startMs: s.startMs, endMs: s.endMs, energy: s.energy)
            }
        }
    }

    /// Cue points and energy detected alongside the analysis.
    public func detectedCues(forHash hash: String) -> CueAnalyzer.Result? {
        guard let stored = load(hash), let cues = stored.cues else { return nil }
        return CueAnalyzer.Result(cues: cues.map { .init(timeMs: $0[0], energy: $0[1]) }, energy: stored.trackEnergy)
    }

    public func store(_ analysis: TrackAnalysis, cues: CueAnalyzer.Result?, sections: [StructureAnalyzer.Section]?,
                      forHash hash: String) throws {
        var stored = Stored(analysis)
        stored.structureVersion = StructureAnalyzer.version
        stored.sections = sections?.map {
            .init(kind: $0.kind.rawValue, startBeat: $0.startBeat, startMs: $0.startMs, endMs: $0.endMs, energy: $0.energy)
        }
        stored.cueVersion = CueAnalyzer.version
        stored.cues = cues?.cues.map { [$0.timeMs, $0.energy] }
        stored.trackEnergy = cues?.energy
        try JSONEncoder().encode(stored).write(to: path(hash), options: .atomic)
        lock.withLock { recent[hash] = nil }
    }

    private func load(_ hash: String) -> Stored? {
        guard let stored = decoded(hash),
              stored.version == TrackAnalysis.currentVersion,
              stored.cueVersion == CueAnalyzer.version,
              stored.structureVersion == StructureAnalyzer.version,
              stored.policy.map({ $0 == Self.ownAnalysisPolicy }) ?? true else { return nil }
        return stored
    }

    private func decoded(_ hash: String) -> Stored? {
        if let hit = lock.withLock({ recent[hash] }) { return hit }
        guard let data = try? Data(contentsOf: path(hash)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        lock.withLock {
            if recent.updateValue(stored, forKey: hash) == nil { recentOrder.append(hash) }
            while recentOrder.count > Self.recentLimit { recent[recentOrder.removeFirst()] = nil }
        }
        return stored
    }

    /// Entries written while key/tempo could come from file tags or Mixed In Key recorded how; only
    /// pure Deckhand analysis is valid now.
    private static let ownAnalysisPolicy = "key-tags=0;bpm-hint=0;mik=0"

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
        var structureVersion: Int?
        var sections: [StoredSection]?

        struct StoredSection: Codable {
            var kind: String
            var startBeat, startMs, endMs: Int
            var energy: Double
        }
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
