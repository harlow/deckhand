import Analysis
import Darwin
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
    /// Entry summaries, so "is it analyzed?" and list fields don't decode waveforms and beats. Each is
    /// checked against its entry's size and mtime and rebuilt from the entry when they differ, so a
    /// missing, stale or partly lost index only costs a decode.
    private var index: [String: IndexEntry]
    private var dirtyIndexKeys = Set<String>()
    private let saveLock = NSLock()
    private static let indexFile = "analysis-index.plist"
    /// Tracks the analyzer couldn't handle, so syncs don't retry (and count) them every time. Valid only for the
    /// algorithm versions that failed: a new analyzer tries again.
    private var failures: [String: Failure]
    private var failuresDirty = false
    private static let failuresFile = "analysis-failures.json"

    struct Failure: Codable, Equatable {
        var reason: String
        var versions: String
    }

    /// The algorithm versions an entry or failure belongs to.
    static var analyzerVersions: String {
        "\(TrackAnalysis.currentVersion).\(CueAnalyzer.version).\(StructureAnalyzer.version)"
    }

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
        index = (try? PropertyListDecoder().decode([String: IndexEntry].self,
                                                   from: Data(contentsOf: root.appendingPathComponent(Self.indexFile)))) ?? [:]
        failures = (try? JSONDecoder().decode([String: Failure].self,
                                              from: Data(contentsOf: root.appendingPathComponent(Self.failuresFile)))) ?? [:]
    }

    /// Hash of a file's audio payload (ignores tags), reusing a cached hash when path, size and mtime are unchanged.
    public func contentHash(of url: URL) throws -> String {
        let attributes = FileOps.attributes(url)
        return try contentHash(of: url, size: attributes?.size ?? 0, modified: attributes?.modified ?? 0)
    }

    /// `contentHash(of:)` for a file whose size and modification time (`FileOps.attributes`) are already known.
    public func contentHash(of url: URL, size: Int64, modified: Double) throws -> String {
        let key = "\(AudioHash.scheme)\(url.path)|\(size)|\(modified)"
        if let h = lock.withLock({ fingerprints[key] }) { return h }
        let h = try AudioHash.hash(url)
        lock.withLock { fingerprints[key] = h }
        return h
    }

    /// The hash `contentHash(of:size:modified:)` would return if it's already known; never reads the file.
    public func cachedContentHash(of url: URL) -> String? {
        guard let attributes = FileOps.attributes(url) else { return nil }
        return cachedContentHash(of: url, size: attributes.size, modified: attributes.modified)
    }

    /// Uses metadata the caller already read; never opens the audio file.
    public func cachedContentHash(of url: URL, size: Int64, modified: Double) -> String? {
        lock.withLock { fingerprints["\(AudioHash.scheme)\(url.path)|\(size)|\(modified)"] }
    }

    /// Picks up what another process (the CLI run by the app) saved since this cache was opened: hashes it computed
    /// and analysis failures it recorded. Analysis entries themselves are always read from disk.
    public func reloadFromDisk() {
        let fp = (try? JSONDecoder().decode([String: String].self,
                                            from: Data(contentsOf: root.appendingPathComponent("fingerprints.json")))) ?? [:]
        let failures = (try? JSONDecoder().decode([String: Failure].self,
                                                  from: Data(contentsOf: root.appendingPathComponent(Self.failuresFile))))
        lock.withLock {
            fingerprints.merge(fp) { mine, _ in mine }
            if let failures, !failuresDirty { self.failures = failures }
        }
    }

    /// Writes the content-hash fingerprints and, if they changed, the summary index and failure list.
    public func save() throws {
        // Serialize same-process saves and app/CLI read-merge-write operations. Descriptor upgrades
        // must survive a CLI process that opened an older index before the upgrade finished.
        try saveLock.withLock {
            let fd = Darwin.open(root.appendingPathComponent("analysis-cache.lock").path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { flock(fd, LOCK_UN) }
            try saveLocked()
        }
    }

    private func saveLocked() throws {
        let onDisk = (try? JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("fingerprints.json")))) ?? [:]
        let data = try lock.withLock {
            fingerprints.merge(onDisk) { mine, _ in mine }
            return try JSONEncoder().encode(fingerprints)
        }
        try data.write(to: root.appendingPathComponent("fingerprints.json"), options: .atomic)
        let pendingFailures = lock.withLock { failuresDirty ? failures : nil }
        if let pendingFailures {
            try JSONEncoder().encode(pendingFailures).write(to: root.appendingPathComponent(Self.failuresFile), options: .atomic)
            lock.withLock { if failures == pendingFailures { failuresDirty = false } }
        }
        let changed = lock.withLock {
            Dictionary(uniqueKeysWithValues: dirtyIndexKeys.compactMap { hash in index[hash].map { (hash, $0) } })
        }
        guard !changed.isEmpty else { return }
        var merged = (try? PropertyListDecoder().decode([String: IndexEntry].self,
            from: Data(contentsOf: root.appendingPathComponent(Self.indexFile)))) ?? lock.withLock { index }
        for (hash, entry) in changed {
            if let disk = merged[hash], disk.stamp == entry.stamp,
               disk.profileVersion == AudioMatchProfile.currentVersion,
               entry.profileVersion != AudioMatchProfile.currentVersion { continue }
            merged[hash] = entry
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(merged).write(to: root.appendingPathComponent(Self.indexFile), options: .atomic)
        lock.withLock {
            for (hash, entry) in changed where index[hash] == entry { dirtyIndexKeys.remove(hash) }
            for (hash, entry) in merged where !dirtyIndexKeys.contains(hash) { index[hash] = entry }
        }
    }

    private func path(_ hash: String) -> URL {
        root.appendingPathComponent("analysis").appendingPathComponent("\(hash).json")
    }

    /// Cached analysis made by the current algorithm versions.
    public func analysis(forHash hash: String) -> TrackAnalysis? {
        load(hash)?.analysis
    }

    /// What a track list or the database needs, without decoding the full entry.
    public struct Summary: Sendable, Equatable {
        public static let overviewBins = 160
        public var durationSeconds: Double
        public var sampleRate: Int
        public var bpm: Double
        public var key: MusicalKey?
        public var energy: Int?
        public var cuesMs: [Int]
        /// Band waveforms reduced to at most `overviewBins` frames (max per bin); peak and rms are empty.
        public var overview: TrackAnalysis.Waveforms
        /// Changes whenever the entry is rewritten.
        public var revision: String
    }

    /// Nil exactly when `analysis(forHash:)` is.
    public func summary(forHash hash: String) -> Summary? {
        guard let stamp = Self.stamp(path(hash)) else { return nil }
        if let e = lock.withLock({ index[hash] }), e.stamp == stamp { return e.summary }
        guard let data = try? Data(contentsOf: path(hash)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let e = IndexEntry(stored, stamp: stamp)
        lock.withLock {
            index[hash] = e
            dirtyIndexKeys.insert(hash)
        }
        return e.summary
    }

    public func isAnalyzed(_ hash: String) -> Bool {
        summary(forHash: hash) != nil
    }

    /// Descriptor lookup for app rows; ordinary summary/sync queries do not decode descriptors.
    public func cachedMatchProfile(forHash hash: String) -> AudioMatchProfile? {
        guard let stamp = Self.stamp(path(hash)), let entry = lock.withLock({ index[hash] }),
              entry.stamp == stamp, entry.profileVersion == AudioMatchProfile.currentVersion,
              Self.isCurrent(version: entry.version, policy: entry.policy, cueVersion: entry.cueVersion, structureVersion: entry.structureVersion)
        else { return nil }
        return entry.matchProfile
    }

    /// Backfill descriptors from cached analysis only. Older indexes remain valid for normal
    /// analysis/sync queries; this optional upgrade never reads or re-analyzes the music file.
    public func matchProfile(forHash hash: String) -> AudioMatchProfile? {
        guard let stamp = Self.stamp(path(hash)) else { return nil }
        if let entry = lock.withLock({ index[hash] }), entry.stamp == stamp,
           entry.profileVersion == AudioMatchProfile.currentVersion,
           entry.profileData == nil || entry.matchProfile != nil { return cachedMatchProfile(forHash: hash) }
        guard let data = try? Data(contentsOf: path(hash)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let entry = IndexEntry(stored, stamp: stamp)
        lock.withLock { index[hash] = entry; dirtyIndexKeys.insert(hash) }
        return entry.summary == nil ? nil : entry.matchProfile
    }

    /// Why the current analyzer failed on this audio, if it did.
    public func analysisFailure(forHash hash: String) -> String? {
        lock.withLock { failures[hash].flatMap { $0.versions == Self.analyzerVersions ? $0.reason : nil } }
    }

    func recordFailure(_ reason: String, forHash hash: String) {
        lock.withLock {
            failures[hash] = Failure(reason: reason, versions: Self.analyzerVersions)
            failuresDirty = true
        }
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
        let stamp = Self.stamp(path(hash))
        let indexed = stamp.map { IndexEntry(stored, stamp: $0) }
        lock.withLock {
            recent[hash] = nil
            index[hash] = indexed
            dirtyIndexKeys.insert(hash)
            if failures.removeValue(forKey: hash) != nil { failuresDirty = true }
        }
    }

    private func load(_ hash: String) -> Stored? {
        guard let stored = decoded(hash), stored.isCurrent else { return nil }
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

    /// Size and modification time of a file, or nil if it's missing.
    private static func stamp(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    /// Older entries recorded a fingerprint of which external inputs (since removed) were allowed;
    /// only this one, pure Deckhand analysis, is still valid. New entries omit it.
    private static let ownAnalysisPolicy = "key-tags=0;bpm-hint=0;mik=0"

    /// Whether an entry was made by the current algorithm versions.
    private static func isCurrent(version: Int, policy: String?, cueVersion: Int?, structureVersion: Int?) -> Bool {
        version == TrackAnalysis.currentVersion && cueVersion == CueAnalyzer.version
            && structureVersion == StructureAnalyzer.version && policy.map({ $0 == ownAnalysisPolicy }) ?? true
    }

    /// An entry's versions and summary fields, as of the entry file's `stamp`.
    private struct IndexEntry: Codable, Equatable {
        var stamp: String
        var version: Int
        var policy: String?
        var cueVersion: Int?
        var structureVersion: Int?
        var durationSeconds: Double
        var sampleRate: Int
        var bpm: Double
        var key: MusicalKey?
        var energy: Int?
        var cues: [Int]
        var low, mid, high: Data
        var profileVersion: Int?
        var profileData: Data?
        var matchProfile: AudioMatchProfile? {
            guard let profileData, let profile = try? PropertyListDecoder().decode(AudioMatchProfile.self, from: profileData),
                  profile.version == AudioMatchProfile.currentVersion else { return nil }
            return profile
        }

        init(_ s: Stored, stamp: String) {
            self.stamp = stamp
            version = s.version
            policy = s.policy
            cueVersion = s.cueVersion
            structureVersion = s.structureVersion
            durationSeconds = s.durationSeconds
            sampleRate = s.sampleRate
            bpm = s.bpm
            key = s.key
            energy = s.cues == nil ? nil : s.trackEnergy
            cues = s.cues?.map { $0[0] } ?? []
            low = Self.reduce(s.low)
            mid = Self.reduce(s.mid)
            high = Self.reduce(s.high)
            profileVersion = AudioMatchProfile.currentVersion
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            profileData = s.isCurrent ? AudioMatchProfile(analysis: s.analysis).flatMap { try? encoder.encode($0) } : nil
        }

        var summary: Summary? {
            guard isCurrent(version: version, policy: policy, cueVersion: cueVersion, structureVersion: structureVersion) else { return nil }
            return Summary(durationSeconds: durationSeconds, sampleRate: sampleRate, bpm: bpm, key: key, energy: energy, cuesMs: cues,
                           overview: .init(peak: [], rms: [], low: Stored.unpack(low), mid: Stored.unpack(mid), high: Stored.unpack(high)),
                           revision: stamp)
        }

        /// Max per bin of the packed bytes (packing is monotonic, so it's the packed max of the floats).
        static func reduce(_ d: Data) -> Data {
            let a = [UInt8](d)
            guard !a.isEmpty else { return Data() }
            let n = min(Summary.overviewBins, a.count)
            return Data((0..<n).map { i in
                let lo = i * a.count / n, hi = max(lo + 1, (i + 1) * a.count / n)
                return a[lo..<hi].max() ?? 0
            })
        }
    }

    /// Compact on-disk form: waveforms stored as sqrt-companded bytes.
    private struct Stored: Codable {
        var version: Int
        var policy: String?
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
            peak = Self.pack(a.waveforms.peak)
            rms = Self.pack(a.waveforms.rms)
            low = Self.pack(a.waveforms.low)
            mid = Self.pack(a.waveforms.mid)
            high = Self.pack(a.waveforms.high)
        }

        var isCurrent: Bool {
            AnalysisCache.isCurrent(version: version, policy: policy, cueVersion: cueVersion, structureVersion: structureVersion)
        }

        var analysis: TrackAnalysis {
            TrackAnalysis(version: version, durationSeconds: durationSeconds, sampleRate: sampleRate, bpm: bpm,
                          beats: beats, key: key,
                          waveforms: .init(peak: Self.unpack(peak), rms: Self.unpack(rms), low: Self.unpack(low),
                                           mid: Self.unpack(mid), high: Self.unpack(high)))
        }

        static func pack(_ x: [Float]) -> Data {
            Data(x.map { UInt8(max(0, min(255, ($0.squareRoot() * 255).rounded()))) })
        }

        static func unpack(_ d: Data) -> [Float] {
            d.map { let v = Float($0) / 255; return v * v }
        }
    }
}
