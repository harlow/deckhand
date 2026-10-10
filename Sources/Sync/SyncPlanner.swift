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
        var probe = DriveProbe.scan(volume, manifest: manifest)
        var changes = SyncStatus.evaluate(library: library, manifest: manifest, facts: facts, drive: probe, profile: profile,
                                          selection: selection, adoptable: adoptable)
        // Audio already at a new track's path: likely a sync cut short after it replaced the database. That database
        // knows the content IDs it gave those tracks.
        let takeovers = changes.tracks.contains {
            $0.changes.contains(.adopt) && $0.adoptFrom == nil && manifest.tracks[$0.id] == nil
        }
        if takeovers, probe.databaseId != nil,
           let ids = try? DeviceLibrary.contentIds(database: volume.url(forUsbPath: DriveProbe.databasePath)) {
            let own = DriveProbe.key(DriveProbe.audioRoot + "/")
            probe.databaseContentIds = Dictionary(ids.map { (DriveProbe.key($0.key), $0.value) }.filter { $0.0.hasPrefix(own) },
                                                  uniquingKeysWith: { a, _ in a })
            changes = SyncStatus.evaluate(library: library, manifest: manifest, facts: facts, drive: probe, profile: profile,
                                          selection: selection, adoptable: adoptable)
        }
        return changes
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

    public static func facts(for t: SourceTrack, previousHash: String?, cache: AnalysisCache,
                             retryFailedAnalysis: Bool = false) -> TrackFacts {
        var f = TrackFacts(audio: .unknown)
        var hash: String?
        if let reason = unavailableReason(t) {
            f.audio = .unavailable(reason)
        } else if let url = t.location, let a = FileOps.attributes(url) {
            do {
                let h = try cache.contentHash(of: url, size: a.size, modified: a.modified)
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
