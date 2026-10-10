import DeckhandCore
import Foundation
import OneLibrary

/// What evaluate knows about one source track (gathered by `SyncPlanner.facts`).
public struct TrackFacts: Sendable, Equatable {
    public enum Audio: Sendable, Equatable {
        /// Readable, hashed audio; `size` and `modified` as `FileOps.attributes` reports them.
        case ok(hash: String, size: Int64, modified: Double)
        /// Not checked yet (e.g. the app hasn't hashed the file).
        case unknown
        /// Can't be read right now: missing or unreadable file, offline disk, cloud-only, DRM, unsupported format.
        case unavailable(String)
    }

    public var audio: Audio
    /// The current analyzer's results for the audio (for unavailable audio, the copy on the drive); nil if not analyzed.
    public var analysis: AnalysisFacts?
    /// Why the current analyzer failed on the audio, if it did. Not retried until the analyzer changes.
    public var analysisFailure: String?

    public init(audio: Audio, analysis: AnalysisFacts? = nil, analysisFailure: String? = nil) {
        self.audio = audio
        self.analysis = analysis
        self.analysisFailure = analysisFailure
    }
}

/// The analysis values a sync writes into the database, plus the cache entry's revision.
public struct AnalysisFacts: Sendable, Equatable {
    public var revision: String
    public var bpm: Double
    public var key: MusicalKey?
    public var energy: Int?
    public var durationSeconds: Double
    public var sampleRate: Int

    public init(revision: String, bpm: Double, key: MusicalKey?, energy: Int?, durationSeconds: Double, sampleRate: Int) {
        self.revision = revision
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
    }

    public init(_ s: AnalysisCache.Summary) {
        self.init(revision: s.revision, bpm: s.bpm, key: s.key, energy: s.energy, durationSeconds: s.durationSeconds,
                  sampleRate: s.sampleRate)
    }

    /// The row values in a compact form for the manifest (`Manifest.Track.rowAnalysis`); doubles round-trip exactly.
    var stored: String {
        let k = key.map { "\($0.tonic)\($0.mode == .minor ? "m" : "M")" } ?? ""
        return "\(bpm)|\(k)|\(energy.map(String.init) ?? "")|\(durationSeconds)|\(sampleRate)"
    }

    init?(stored: String) {
        let f = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, let bpm = Double(f[0]), let duration = Double(f[3]), let rate = Int(f[4]) else { return nil }
        var key: MusicalKey?
        if let mode = f[1].last, let tonic = Int(f[1].dropLast()) { key = MusicalKey(tonic: tonic, mode: mode == "m" ? .minor : .major) }
        self.init(revision: "", bpm: bpm, key: key, energy: Int(f[2]), durationSeconds: duration, sampleRate: rate)
    }
}

/// Which playlists go on a drive, and whether every song does.
public struct Selection: Sendable, Equatable {
    public var playlistIds: [String]
    public var entireLibrary: Bool

    public init(playlistIds: [String], entireLibrary: Bool = false) {
        self.playlistIds = playlistIds
        self.entireLibrary = entireLibrary
    }

    /// The drive's saved selection.
    public init(_ m: Manifest) {
        self.init(playlistIds: m.selectedPlaylistIds, entireLibrary: m.entireLibrary == true)
    }
}

/// The tracks and playlists a selection puts on a drive.
public struct Scope: Sendable {
    /// Selected playlist IDs still in the library (deleted ones dropped), in selection order.
    public let playlistIds: [String]
    /// The selected playlists and their ancestor folders, in library order.
    public let playlists: [SourcePlaylist]
    /// In first-seen order: playlists in library order, then (entire library) the rest of the library.
    public let trackIds: [String]
    let firstPlaylist: [String: String]
    /// Entire library chosen but the library was loaded without all songs: tracks outside playlists are unknown.
    let incomplete: Bool
    /// The library came back empty, more likely a failed read than everything deleted: nothing is judged.
    public let unreadable: Bool
}

/// Everything a sync would change on a drive, decided by `SyncStatus.evaluate` from facts alone. The executor
/// carries it out, and status and dry runs report it, so they can't disagree.
public struct ChangeSet: Sendable {
    public enum TrackChange: String, Sendable, Codable, CaseIterable, Comparable {
        /// Copied to the drive for the first time.
        case new
        /// The source's audio changed: copied to a new path; the old copy is removed after the sync.
        case audioChanged
        /// Deleted from the drive behind Deckhand's back: copied again to the same path.
        case missingOnDrive
        /// Audio already on the drive is taken over: moved from elsewhere on it, or already at its path.
        case adopt
        /// Analyzed during the sync.
        case analyze
        /// Analysis files to check, and rewrite if their content differs (inputs changed, files missing, new path).
        case analysisFiles
        /// The track's database row changes.
        case record
        /// Cover art to read again (the track or file changed, or images are missing).
        case artworkCheck

        public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    public enum TrackStatus: Sendable, Equatable {
        case clean
        case pending(Set<TrackChange>)
        /// Can't go on the drive, and isn't on it: no readable local file, DRM, unsupported format.
        case ineligible(String)
        /// On the drive and kept there (in its playlists too) although its source can't be read right now.
        case retained(String)
        /// On the drive, but the analyzer failed on it; not retried until the analyzer changes.
        case failed(String)
        /// Not known yet (the audio hasn't been checked).
        case unknown
    }

    public enum PlaylistChange: String, Sendable, Codable, CaseIterable {
        case create, name, parent, sequence, contents
    }

    public enum PlaylistStatus: Sendable, Equatable {
        case clean
        case pending(Set<PlaylistChange>)
        /// Holds a track that isn't known yet.
        case unknown
    }

    public enum DriveChange: String, Sendable, Codable, CaseIterable {
        /// The drive's saved settings differ from this sync's.
        case settings
        /// The saved selection differs: chosen differently, or a selected playlist was deleted in Music.
        case selection
        case databaseMissing
        /// The drive's database isn't the one Deckhand last wrote: replaced, restored, or the last sync was cut short.
        case databaseChanged
        /// A manifest from before generations, saved once in the two-file form.
        case legacyManifest
    }

    public struct Track: Sendable {
        public let id: String
        public var source: SourceTrack
        public internal(set) var status: TrackStatus
        /// The first playlist the track appears in, for messages.
        public let playlist: String?
        /// Where it is (or will be) on the drive; nil when it isn't going there.
        public internal(set) var usbPath: String?
        public internal(set) var contentId: Int?
        /// Why the source can't be read, for ineligible and retained tracks.
        public internal(set) var unavailableReason: String?
        public internal(set) var facts: TrackFacts
        /// The audio the drive copy holds: the source's, or for a retained track the one last synced.
        var contentHash: String?
        /// For `.adopt` from elsewhere on the drive.
        var adoptFrom: String?
        var driveSize: Int64 = 0
        var artworkKey: String?
        var artworkPath: String?
        /// Analysis the row keeps while the current analysis isn't available (see `Manifest.Track.rowAnalysis`).
        var keptAnalysis: AnalysisFacts?
        /// Some of its analysis files are missing.
        var anlzMissing = false
        var recordFingerprint: String?
        /// Its database row differs from the one last written (or is new).
        var recordChanged = false

        public var changes: Set<TrackChange> {
            if case .pending(let c) = status { c } else { [] }
        }

        var isPlaced: Bool { usbPath != nil }

        /// The analysis values its database row is written with.
        var rowAnalysis: AnalysisFacts? { facts.analysis ?? keptAnalysis }

        /// Copies audio from the source.
        var copies: Bool { !changes.isDisjoint(with: [.new, .audioChanged, .missingOnDrive]) }

        mutating func place(_ r: Manifest.Track) {
            usbPath = r.usbPath
            contentId = r.contentId
            contentHash = r.contentHash
        }
    }

    public struct Playlist: Sendable {
        public let source: SourcePlaylist
        public let record: Manifest.Playlist
        public let status: PlaylistStatus
    }

    public struct Removal: Sendable {
        public enum Reason: String, Sendable, Codable {
            /// Out of the selection, or deleted in Music.
            case deselected
            /// The source's audio changed; the old copy goes.
            case superseded
            /// Its source can't be read and the drive copy is gone too: forgotten, nothing to delete.
            case lost
        }

        public let id: String
        public let record: Manifest.Track
        public let reason: Reason
        /// Whether its files are deleted: not when lost, nor while another track uses the same file.
        public let deletesFiles: Bool
    }

    public internal(set) var tracks: [Track]
    let index: [String: Int]
    public let removedTracks: [Removal]
    public let playlists: [Playlist]
    public let removedPlaylists: [Manifest.Playlist]
    public let drive: Set<DriveChange>
    /// Audio bytes to copy (sources of new, changed and missing tracks; each file once).
    public let bytesToCopy: Int64
    /// The manifest after the sync, as far as facts tell; the executor fills in what it learns along the way.
    public let nextManifest: Manifest
    /// The manifest this was evaluated from.
    public let base: Manifest
    public let scope: Scope
    public let profile: OutputProfile
    let probe: DriveProbe

    public func track(_ id: String) -> Track? { index[id].map { tracks[$0] } }

    /// Space a sync needs: the audio plus a margin for analysis files, artwork and the database.
    public var spaceNeeded: Int64 { bytesToCopy + SyncStatus.spaceMargin }

    /// Analysis and adopted files can change a row in ways only known once done, so they count.
    public var needsDatabaseWrite: Bool {
        tracks.contains { $0.recordChanged || !$0.changes.isDisjoint(with: [.analyze, .adopt]) } || !removedTracks.isEmpty
            || playlists.contains { if case .pending = $0.status { true } else { false } } || !removedPlaylists.isEmpty
            || drive.contains(.databaseMissing) || drive.contains(.databaseChanged)
    }

    public var needsManifestWrite: Bool {
        needsDatabaseWrite || tracks.contains { !$0.changes.isEmpty } || !drive.isEmpty
    }

    /// Nothing for a sync to do.
    public var isClean: Bool { summary.total == 0 }

    /// Every fact was known; only complete change sets can be carried out.
    public var isComplete: Bool {
        summary.unknown == 0 && summary.playlistsUnknown == 0 && !scope.incomplete && !scope.unreadable
    }

    public struct Summary: Sendable, Codable, Equatable {
        /// Tracks the selection puts on the drive.
        public var tracks = 0
        public var clean = 0
        /// Tracks with work to do.
        public var pending = 0
        public var toCopy = 0, toAdopt = 0, toAnalyze = 0, analysisFiles = 0, records = 0, artwork = 0
        /// Tracks coming off the drive (an old copy replaced by changed audio isn't counted).
        public var toRemove = 0
        public var ineligible = 0, retained = 0, failed = 0, unknown = 0
        public var playlistsToCreate = 0, playlistsToUpdate = 0, playlistsToRemove = 0, playlistsUnknown = 0
        public var drive: [DriveChange] = []
        public var bytesToCopy: Int64 = 0
        /// Everything a sync would do, as one count.
        public var total = 0
    }

    public var summary: Summary {
        var s = Summary()
        for t in tracks {
            s.tracks += 1
            switch t.status {
            case .clean: s.clean += 1
            case .pending(let c):
                s.pending += 1
                if t.copies { s.toCopy += 1 }
                if c.contains(.adopt) { s.toAdopt += 1 }
                if c.contains(.analyze) { s.toAnalyze += 1 }
                if c.contains(.analysisFiles) { s.analysisFiles += 1 }
                if c.contains(.record) { s.records += 1 }
                if c.contains(.artworkCheck) { s.artwork += 1 }
            case .ineligible: s.ineligible += 1
            case .retained: s.retained += 1
            case .failed: s.failed += 1
            case .unknown: s.unknown += 1
            }
        }
        s.toRemove = removedTracks.filter { $0.reason != .superseded }.count
        for p in playlists {
            switch p.status {
            case .clean: break
            case .pending(let c): if c.contains(.create) { s.playlistsToCreate += 1 } else { s.playlistsToUpdate += 1 }
            case .unknown: s.playlistsUnknown += 1
            }
        }
        s.playlistsToRemove = removedPlaylists.count
        s.drive = drive.sorted { $0.rawValue < $1.rawValue }
        s.bytesToCopy = bytesToCopy
        s.total = s.pending + s.toRemove + s.playlistsToCreate + s.playlistsToUpdate + s.playlistsToRemove + s.drive.count
        return s
    }
}

/// The single decision of what a sync changes. Pure: facts in, `ChangeSet` out, no I/O.
public enum SyncStatus {
    /// Free space kept on top of the audio to copy.
    public static let spaceMargin: Int64 = 20 << 20

    /// The tracks and playlists `selection` puts on the drive.
    public static func scope(library: SourceLibrary, selection: Selection) -> Scope {
        var seen = Set<String>()
        var ids = selection.playlistIds.filter { seen.insert($0).inserted }
        // An empty library is more likely a failed read than every playlist deleted.
        let unreadable = library.playlists.isEmpty && library.tracks.isEmpty
        if !library.playlists.isEmpty {
            let known = Set(library.playlists.map(\.id))
            ids = ids.filter(known.contains)
        }
        let playlists = library.selection(Set(ids))
        var groups = playlists.filter { !$0.isFolder }
        let incomplete = selection.entireLibrary && library.allTrackIds == nil
        if selection.entireLibrary, let all = library.allTrackIds {
            groups.append(SourcePlaylist(id: "", name: "Library", trackIds: all))
        }
        var order: [String] = []
        var first: [String: String] = [:]
        for p in groups {
            for id in p.trackIds where first[id] == nil && library.tracks[id] != nil {
                first[id] = p.name
                order.append(id)
            }
        }
        return Scope(playlistIds: ids, playlists: playlists, trackIds: order, firstPlaylist: first, incomplete: incomplete,
                     unreadable: unreadable)
    }

    /// Decides what syncing `library` (as `selection`, by default the drive's saved one) to a drive with `manifest`
    /// and the files in `drive` would change. `facts` covers the scope's tracks (missing ones count as unknown);
    /// `adoptable` maps audio hashes to unowned files already on the drive (see AdoptScanner).
    public static func evaluate(library: SourceLibrary, manifest: Manifest, facts: [String: TrackFacts], drive: DriveProbe,
                                profile: OutputProfile, selection: Selection? = nil,
                                adoptable: [String: String] = [:]) -> ChangeSet {
        let selection = selection ?? Selection(manifest)
        let scope = scope(library: library, selection: selection)
        var adoptable = adoptable
        var tracks: [ChangeSet.Track] = []
        tracks.reserveCapacity(scope.trackIds.count)
        var changes: [Set<ChangeSet.TrackChange>] = []
        var removals: [(id: String, record: Manifest.Track, reason: ChangeSet.Removal.Reason)] = []
        var needsId: [Int] = []

        // 1. Where each track's audio is or goes. Players find analysis files by a hash of the audio path (~200k
        // buckets), so new paths steer clear of directories in use, including those of tracks being removed. (Built
        // only when a path is needed: most evaluations allocate none.)
        var anlzOwner: [String: String]?
        for id in scope.trackIds {
            guard let source = library.tracks[id] else { continue }
            let f = facts[id] ?? TrackFacts(audio: .unknown)
            let prev = manifest.tracks[id]
            var t = ChangeSet.Track(id: id, source: source, status: .clean, playlist: scope.firstPlaylist[id], facts: f)
            var c = Set<ChangeSet.TrackChange>()
            switch f.audio {
            case .unknown:
                t.status = .unknown
                if let prev { t.place(prev) }
            case .unavailable(let reason):
                t.unavailableReason = reason
                if let prev, drive.hasAudio(prev.usbPath) {
                    t.place(prev)
                    t.status = .retained(reason)
                } else {
                    t.status = .ineligible(reason)
                    if let prev { removals.append((id, prev, .lost)) }
                }
            case .ok(let hash, _, _):
                if let prev, prev.contentHash == hash {
                    t.place(prev)
                    if !drive.hasAudio(prev.usbPath) {
                        if let from = adoptable.removeValue(forKey: hash) {
                            t.adoptFrom = from
                            c.insert(.adopt)
                        } else {
                            c.insert(.missingOnDrive)
                        }
                    }
                } else {
                    if anlzOwner == nil {
                        anlzOwner = Dictionary(manifest.tracks.values.map { (AnlzPath.directory(forAudioPath: $0.usbPath), $0.usbPath) },
                                               uniquingKeysWith: { a, _ in a })
                    }
                    let path = allocatePath(source, hash: hash, owners: anlzOwner!)
                    anlzOwner![AnlzPath.directory(forAudioPath: path)] = path
                    t.usbPath = path
                    t.contentHash = hash
                    t.contentId = prev?.contentId
                    if let prev { removals.append((id, prev, .superseded)) } else { needsId.append(tracks.count) }
                    // The name embeds the audio fingerprint, so a file already there is this audio, e.g. copied by a
                    // sync that was cut short. The executor verifies it before trusting it.
                    if drive.hasAudio(path) {
                        c.insert(.adopt)
                    } else if let from = adoptable.removeValue(forKey: hash) {
                        t.adoptFrom = from
                        c.insert(.adopt)
                    } else {
                        c.insert(prev == nil ? .new : .audioChanged)
                    }
                }
            }
            tracks.append(t)
            changes.append(c)
        }

        // 2. Content IDs for tracks new to the drive. Audio found at its path but unknown to the manifest keeps the ID
        // the drive's database gave it (a sync cut short after replacing the database): player history refers to it.
        // Other IDs that database gave out aren't reused either, so history can't move to a different track.
        var usedIds = Set(manifest.tracks.values.map(\.contentId))
        if let dbIds = drive.databaseContentIds {
            for i in needsId where changes[i].contains(.adopt) && tracks[i].adoptFrom == nil {
                if let cid = dbIds[DriveProbe.key(tracks[i].usbPath!)], cid >= manifest.nextContentId, !usedIds.contains(cid) {
                    tracks[i].contentId = cid
                    usedIds.insert(cid)
                }
            }
            usedIds.formUnion(dbIds.values)
        }
        var nextContentId = manifest.nextContentId
        for i in needsId where tracks[i].contentId == nil {
            while usedIds.contains(nextContentId) { nextContentId += 1 }
            tracks[i].contentId = nextContentId
            usedIds.insert(nextContentId)
            nextContentId += 1
        }
        nextContentId = max(nextContentId, (usedIds.max() ?? 0) + 1)

        // 3. Analysis, artwork and database row of each track on the drive.
        let anlzKey = profile.anlzKey
        var bytes: Int64 = 0
        // Tracks sharing a file (same audio and name) place it once, from the first one's source.
        var placedSize: [String: Int64] = [:]
        for i in tracks.indices where tracks[i].isPlaced && tracks[i].status != .unknown {
            var t = tracks[i]
            var c = changes[i]
            let prev = manifest.tracks[t.id]
            // What the manifest says about this exact copy (nothing, if the track moves to a new path).
            let record = prev.flatMap { $0.usbPath == t.usbPath && $0.contentHash == t.contentHash ? $0 : nil }
            var retained = false
            if case .retained = t.status { retained = true }
            let audioWork = !c.isDisjoint(with: [.new, .audioChanged, .missingOnDrive, .adopt])
            if case .ok(_, let size, _) = t.facts.audio, audioWork {
                let key = DriveProbe.key(t.usbPath!)
                if let first = placedSize[key] {
                    t.driveSize = first
                } else {
                    t.driveSize = size
                    placedSize[key] = size
                    if !c.contains(.adopt) { bytes += size }
                }
            } else {
                var sourceSize: Int64?
                if case .ok(_, let size, _) = t.facts.audio { sourceSize = size }
                t.driveSize = record?.fileSize ?? drive.size(t.usbPath!) ?? sourceSize ?? 0
            }

            if t.facts.analysis == nil, let kept = record?.rowAnalysis.flatMap(AnalysisFacts.init(stored:)),
               drive.hasAllAnlz(forAudio: t.usbPath!) {
                // Its analysis files are still on the drive, from analysis that isn't current now (source offline,
                // analyzer changed): the row keeps the values written with them rather than losing BPM, key and grid.
                t.keptAnalysis = kept
            }
            if let a = t.facts.analysis {
                t.anlzMissing = !drive.hasAllAnlz(forAudio: t.usbPath!)
                if t.anlzMissing || record?.anlzFingerprint == nil || profile.rewriteAnalysisFiles
                    || !Manifest.matches(record?.anlzInputs, anlzInputs(a, key: anlzKey)) {
                    c.insert(.analysisFiles)
                }
            } else if t.facts.analysisFailure == nil, profile.analyzeMissing, !retained {
                c.insert(.analyze)
            }

            if profile.artwork {
                let imageId = record?.artworkHash.flatMap { manifest.artwork?[$0] }
                t.artworkPath = imageId.map(ArtworkWriter.path)
                let imagesMissing = record?.artworkHash != nil
                    && (imageId == nil || !drive.hasImage(t.artworkPath!) || !drive.hasImage(ArtworkWriter.mediumPath(forSmall: t.artworkPath!)))
                if case .ok(let hash, let size, let modified) = t.facts.audio {
                    t.artworkKey = artworkKey(hash: hash, size: size, modified: modified, trackModified: t.source.modifiedDate)
                    if record?.artworkKey != t.artworkKey || imagesMissing { c.insert(.artworkCheck) }
                } else {
                    // Retained: the art stays as last read, unless its images went missing.
                    t.artworkKey = record?.artworkKey
                    if imagesMissing { c.insert(.artworkCheck) }
                }
            }

            let row = exportTrack(t, settings: profile.settings, fallbackDate: manifest.createdAt)
            t.recordFingerprint = Manifest.digest(row.fingerprint(keyFormat: profile.settings.keyFormat))
            t.recordChanged = t.recordFingerprint != prev?.recordFingerprint
            if t.recordChanged, record != nil { c.insert(.record) }

            if !c.isEmpty {
                t.status = .pending(c)
            } else if !retained {
                let failure = t.facts.analysis == nil ? t.facts.analysisFailure : nil
                t.status = failure.map { .failed($0) } ?? .clean
            }
            tracks[i] = t
        }

        // 4. Playlists: stable IDs; sibling order follows the library.
        var contentIdOf: [String: Int] = [:]
        var unknownTracks = Set<String>()
        for t in tracks {
            if t.isPlaced, let cid = t.contentId { contentIdOf[t.id] = cid } else if t.status == .unknown { unknownTracks.insert(t.id) }
        }
        var nextPlaylistId = manifest.nextPlaylistId
        var playlistIdFor: [String: Int] = [:]
        for p in scope.playlists {
            if let id = manifest.playlists[p.id]?.playlistId {
                playlistIdFor[p.id] = id
            } else {
                playlistIdFor[p.id] = nextPlaylistId
                nextPlaylistId += 1
            }
        }
        var siblings: [String: Int] = [:]
        var playlists: [ChangeSet.Playlist] = []
        for p in scope.playlists {
            let parent = p.parentId.flatMap { playlistIdFor[$0] }
            let parentKey = parent == nil ? "" : p.parentId!
            let sequenceNo = siblings[parentKey, default: 0]
            siblings[parentKey] = sequenceNo + 1
            let record = Manifest.Playlist(playlistId: playlistIdFor[p.id]!, name: p.name, parentPlaylistId: parent,
                                           sequenceNo: sequenceNo,
                                           contentIds: p.isFolder ? [] : p.trackIds.compactMap { contentIdOf[$0] })
            var status = ChangeSet.PlaylistStatus.clean
            if !p.isFolder, p.trackIds.contains(where: unknownTracks.contains) {
                status = .unknown
            } else if let old = manifest.playlists[p.id] {
                var c = Set<ChangeSet.PlaylistChange>()
                if old.name != record.name { c.insert(.name) }
                if old.parentPlaylistId != record.parentPlaylistId { c.insert(.parent) }
                if old.sequenceNo != record.sequenceNo { c.insert(.sequence) }
                if old.contentIds != record.contentIds { c.insert(.contents) }
                if !c.isEmpty { status = .pending(c) }
            } else {
                status = .pending([.create])
            }
            playlists.append(.init(source: p, record: record, status: status))
        }
        let selectedPlaylists = Set(scope.playlists.map(\.id))
        let removedPlaylists = scope.unreadable ? [] : manifest.playlists.filter { !selectedPlaylists.contains($0.key) }
            .sorted { $0.value.playlistId < $1.value.playlistId }.map(\.value)

        // 5. Tracks leaving the drive. With the library's songs unknown, nothing outside its playlists is judged.
        let inScope = Set(tracks.map(\.id))
        if !scope.incomplete && !scope.unreadable {
            for (id, r) in manifest.tracks where !inScope.contains(id) { removals.append((id, r, .deselected)) }
        }
        let keptPaths = Set(tracks.compactMap { $0.usbPath.map(DriveProbe.key) })
        let removedTracks = removals.sorted { $0.id < $1.id }.map {
            ChangeSet.Removal(id: $0.id, record: $0.record, reason: $0.reason,
                              deletesFiles: $0.reason != .lost && !keptPaths.contains(DriveProbe.key($0.record.usbPath)))
        }

        // 6. The manifest after the sync.
        var next = manifest
        next.selectedPlaylistIds = scope.playlistIds
        if selection.entireLibrary != (manifest.entireLibrary == true) { next.entireLibrary = selection.entireLibrary }
        next.settings = profile.settings.dictionary
        next.nextContentId = nextContentId
        next.nextPlaylistId = nextPlaylistId
        var nextTracks = scope.incomplete || scope.unreadable ? manifest.tracks.filter { !inScope.contains($0.key) } : [:]
        for t in tracks where t.isPlaced {
            let prev = manifest.tracks[t.id]
            if t.status == .unknown {
                if let prev { nextTracks[t.id] = prev }
                continue
            }
            var r: Manifest.Track
            if let prev, prev.usbPath == t.usbPath, prev.contentHash == t.contentHash {
                r = prev
            } else {
                r = Manifest.Track(contentId: t.contentId!, usbPath: t.usbPath!, contentHash: t.contentHash!,
                                   analysisVersion: TrackAnalysis.currentVersion, anlzFingerprint: nil, metadataFingerprint: nil)
            }
            r.contentId = t.contentId!
            r.recordFingerprint = t.recordFingerprint
            r.fileSize = t.driveSize
            r.rowAnalysis = t.rowAnalysis?.stored
            // Source fields are part of the row: an unchanged row has an unchanged metadata fingerprint.
            if t.recordChanged || r.metadataFingerprint == nil { r.metadataFingerprint = Manifest.digest(metadataFingerprint(t.source)) }
            nextTracks[t.id] = r
        }
        next.tracks = nextTracks
        next.playlists = scope.unreadable ? manifest.playlists : Dictionary(uniqueKeysWithValues: playlists.map {
            ($0.source.id, $0.status == .unknown ? manifest.playlists[$0.source.id] ?? $0.record : $0.record)
        })
        if profile.artwork, let art = manifest.artwork {
            let referenced = Set(nextTracks.values.compactMap(\.artworkHash))
            next.artwork = art.filter { referenced.contains($0.key) }
        }

        var driveChanges = Set<ChangeSet.DriveChange>()
        if Set(scope.playlistIds) != Set(manifest.selectedPlaylistIds) || selection.entireLibrary != (manifest.entireLibrary == true) {
            driveChanges.insert(.selection)
        }
        if profile.settings != OutputSettings(saved: manifest.settings) { driveChanges.insert(.settings) }
        if drive.databaseId == nil {
            // A drive with nothing selected doesn't need an empty database.
            if manifest.lastSyncedAt != nil || !nextTracks.isEmpty || !playlists.isEmpty { driveChanges.insert(.databaseMissing) }
        } else if manifest.lastSyncedAt != nil, manifest.databaseId != drive.databaseId {
            driveChanges.insert(.databaseChanged)
        }
        if manifest.generation == nil, manifest.lastSyncedAt != nil { driveChanges.insert(.legacyManifest) }

        return ChangeSet(tracks: tracks, index: Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) }),
                         removedTracks: removedTracks, playlists: playlists, removedPlaylists: removedPlaylists,
                         drive: driveChanges, bytesToCopy: bytes, nextManifest: next, base: manifest, scope: scope,
                         profile: profile, probe: drive)
    }

    /// The database row for a track on the drive. Evaluate fingerprints it; the executor writes it.
    static func exportTrack(_ t: ChangeSet.Track, settings: OutputSettings, fallbackDate: Date) -> ExportTrack {
        let s = t.source, a = t.rowAnalysis, path = t.usbPath!
        let duration = a?.durationSeconds ?? s.durationSeconds ?? 0
        let bitrate = duration > 0 ? Int((Double(t.driveSize) * 8 / duration / 1000).rounded()) : 0
        return ExportTrack(
            contentId: t.contentId!, title: s.title, artist: s.artist, album: s.album, albumArtist: s.albumArtist,
            genre: s.genre, trackNumber: s.trackNumber, discNumber: s.discNumber, year: s.year,
            durationSeconds: duration, bpm: a?.bpm, key: a?.key, color: settings.trackColor.color(energy: a?.energy),
            rating: s.rating ?? 0, comment: s.comment, usbPath: path, fileSize: Int(t.driveSize),
            fileType: AudioFileType(fileExtension: (path as NSString).pathExtension) ?? .mp3, bitrateKbps: bitrate,
            sampleRate: a?.sampleRate ?? 44100, dateAdded: s.dateAdded ?? fallbackDate,
            analysisPath: a == nil ? nil : AnlzPath.directory(forAudioPath: path) + "/ANLZ0000.DAT",
            artworkPath: t.artworkPath)
    }

    /// What a track's analysis files are made from: its cache entry, settings and the recipe.
    static func anlzInputs(_ a: AnalysisFacts, key: String) -> String { "\(a.revision);\(key)" }

    /// Cover art is reread when the audio file or the track (Music bumps its modification date) changes.
    static func artworkKey(hash: String, size: Int64, modified: Double, trackModified: Date?) -> String {
        "\(hash);\(size);\(modified);\(trackModified?.timeIntervalSince1970 ?? 0)"
    }

    /// The source fields that end up in the device database; the app compares it until it reads SyncStatus.
    public static func metadataFingerprint(_ s: SourceTrack) -> String {
        [s.title, s.artist ?? "", s.album ?? "", s.albumArtist ?? "", s.genre ?? "", s.trackNumber.map(String.init) ?? "",
         s.discNumber.map(String.init) ?? "", s.year.map(String.init) ?? "", String(s.rating ?? 0), s.comment ?? ""]
            .joined(separator: "\u{1F}")
    }

    static func allocatePath(_ t: SourceTrack, hash: String, owners: [String: String]) -> String {
        let file = t.location ?? URL(fileURLWithPath: "/Track.mp3")
        var variant = 1
        var candidate = usbPath(for: t, file: file, hash: hash)
        while let owner = owners[AnlzPath.directory(forAudioPath: candidate)], owner != candidate {
            variant += 1
            candidate = usbPath(for: t, file: file, hash: hash, variant: variant)
        }
        return candidate
    }

    /// "/Contents/Deckhand/<hh>/<Artist - Title> [<hash8>].<ext>"; variants 2+ add "-<n>" to avoid
    /// analysis-path collisions.
    static func usbPath(for t: SourceTrack, file: URL, hash: String, variant: Int = 1) -> String {
        let base = [t.artist, t.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        let name = sanitize(base.isEmpty ? file.deletingPathExtension().lastPathComponent : base)
        let digest = hash.split(separator: ":").last.map(String.init) ?? hash
        let tag = variant > 1 ? "\(digest.prefix(8))-\(variant)" : String(digest.prefix(8))
        return "\(DriveProbe.audioRoot)/\(digest.prefix(2))/\(name) [\(tag)].\(file.pathExtension.lowercased())"
    }

    public static func sanitize(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = String(String.UnicodeScalarView(s.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            illegal.contains($0) ? "_" : $0
        }))
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .")).replacingOccurrences(of: "  ", with: " ")
        if out.count > 80 { out = String(out.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
        return out.isEmpty ? "Track" : out
    }
}
