import DeckhandCore
import Foundation
import OneLibrary

/// Gathers the facts `SyncStatus.evaluate` decides from (audio hashes and analysis from the cache, the drive's
/// files) and evaluates them.
public struct SyncPlanner {
    let library: SourceLibrary
    let cache: AnalysisCache

    public init(library: SourceLibrary, cache: AnalysisCache) {
        self.library = library
        self.cache = cache
    }

    /// What syncing to `volume`, whose manifest is `manifest`, would change. `selection` defaults to the drive's
    /// saved one. `adoptable`: audio hash → USB path of existing, unowned files on the drive (see AdoptScanner).
    public func plan(volume: Volume, manifest: Manifest, profile: OutputProfile, selection: Selection? = nil,
                     adoptable: [String: String] = [:], retryFailedAnalysis: Bool = false) -> ChangeSet {
        let scope = SyncStatus.scope(library: library, selection: selection ?? Selection(manifest))
        let facts = facts(for: scope.trackIds, manifest: manifest, retryFailedAnalysis: retryFailedAnalysis)
        let probe = DriveProbe.scan(volume, manifest: manifest)
        return Self.evaluate(library: library, volume: volume, manifest: manifest, facts: facts, probe: probe, profile: profile,
                             selection: selection, adoptable: adoptable)
    }

    /// `SyncStatus.evaluate` with facts and a probe already gathered (the app gathers its own, without hashing). If the
    /// drive looks like a sync was cut short after it replaced the database, reads that database's content IDs and
    /// evaluates again, so those IDs are kept for the tracks that got them and not reused for others.
    public static func evaluate(library: SourceLibrary, volume: Volume, manifest: Manifest, facts: [String: TrackFacts],
                                probe: DriveProbe, profile: OutputProfile, selection: Selection? = nil,
                                adoptable: [String: String] = [:]) -> ChangeSet {
        var probe = probe
        let changes = SyncStatus.evaluate(library: library, manifest: manifest, facts: facts, drive: probe, profile: profile,
                                          selection: selection, adoptable: adoptable)
        // Audio already at a new track's path, or a database other than the one recorded: likely a sync cut short
        // after it replaced the database. Its content IDs are kept for those tracks and not reused for others.
        let takeovers = changes.tracks.contains {
            $0.changes.contains(.adopt) && $0.adoptFrom == nil && manifest.tracks[$0.id] == nil
        }
        guard takeovers || changes.drive.contains(.databaseChanged), probe.databaseId != nil,
              let ids = try? DeviceLibrary.contentIds(database: volume.url(forUsbPath: DriveProbe.databasePath)) else { return changes }
        let own = DriveProbe.key(DriveProbe.audioRoot + "/")
        probe.databaseContentIds = Dictionary(ids.map { (DriveProbe.key($0.key), $0.value) }.filter { $0.0.hasPrefix(own) },
                                              uniquingKeysWith: { a, _ in a })
        return SyncStatus.evaluate(library: library, manifest: manifest, facts: facts, drive: probe, profile: profile,
                                   selection: selection, adoptable: adoptable)
    }

    /// The self-check after a sync: the drive's manifest and files and the tracks' facts read afresh and evaluated
    /// with the drive's saved selection. Clean unless something changed during the sync or a step failed.
    public func verify(volume: Volume, profile: OutputProfile) throws -> ChangeSet {
        guard let manifest = try Manifest.load(from: volume) else { throw SyncError.notInitialized(volume.name) }
        var profile = profile
        profile.rewriteAnalysisFiles = false
        return plan(volume: volume, manifest: manifest, profile: profile)
    }

    /// Facts for the given tracks: hashes (cached by path, size and modification time), analysis summaries and
    /// recorded failures. A track whose file can't be read is looked up by the audio the drive holds.
    public func facts(for ids: [String], manifest: Manifest, retryFailedAnalysis: Bool = false) -> [String: TrackFacts] {
        var out: [String: TrackFacts] = [:]
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let t = library.tracks[id] else { continue }
            out[id] = Self.facts(for: t, previousHash: manifest.tracks[id]?.contentHash, cache: cache,
                                 retryFailedAnalysis: retryFailedAnalysis)
        }
        try? cache.save()
        return out
    }

    /// One track's facts. Without `hashing`, audio the cache hasn't hashed at its current size and modification
    /// time is `.unknown` instead of being read (the app hashes in the background and evaluates again).
    public static func facts(for t: SourceTrack, previousHash: String?, cache: AnalysisCache,
                             retryFailedAnalysis: Bool = false, hashing: Bool = true) -> TrackFacts {
        var f = TrackFacts(audio: .unknown)
        var hash: String?
        if let reason = unavailableReason(t) {
            f.audio = .unavailable(reason)
        } else if let url = t.location, let a = FileOps.attributes(url) {
            do {
                let h = hashing ? try cache.contentHash(of: url, size: a.size, modified: a.modified)
                    : cache.cachedContentHash(of: url, size: a.size, modified: a.modified)
                guard let h else { return f }
                f.audio = .ok(hash: h, size: a.size, modified: a.modified)
                hash = h
            } catch {
                f.audio = .unavailable("Couldn't read \(url.path): \(error)")
            }
        } else {
            f.audio = .unavailable("Local file is missing: \(t.location?.path ?? "")")
        }
        if let h = hash ?? previousHash {
            f.analysis = cache.summary(forHash: h).map(AnalysisFacts.init)
            if f.analysis == nil, !retryFailedAnalysis { f.analysisFailure = cache.analysisFailure(forHash: h) }
        }
        return f
    }

    /// Why a track can't be exported right now, or nil if it can.
    public static func unavailableReason(_ t: SourceTrack) -> String? {
        if let r = t.unavailableReason { return r }
        guard let url = t.location else { return "Track has no local file" }
        guard AudioFileType(fileExtension: url.pathExtension) != nil else {
            return "Unsupported file type (.\(url.pathExtension))"
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: url.path) ? "Local file is not readable: \(url.path)" : "Local file is missing: \(url.path)"
        }
        return nil
    }

    static func usbPath(for t: SourceTrack, file: URL, hash: String, variant: Int = 1) -> String {
        SyncStatus.usbPath(for: t, file: file, hash: hash, variant: variant)
    }

    public static func sanitize(_ s: String) -> String { SyncStatus.sanitize(s) }
}
