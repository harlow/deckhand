import DeckhandCore
import Foundation
import OneLibrary

/// The complete set of changes a sync will make, computed before anything is written.
public struct SyncPlan: Sendable {
    public enum Action: String, Sendable {
        case add, replace, unchanged
        /// Audio already on the drive outside Deckhand's folder; moved into place instead of copied.
        case adopt
    }
    public enum PlaylistAction: String, Sendable { case create, change, unchanged }

    public struct TrackEntry: Sendable {
        public var source: SourceTrack
        public var sourceFile: URL
        public var contentHash: String
        public var usbPath: String
        public var contentId: Int
        public var fileSize: Int64
        public var action: Action
        public var needsAnalysis: Bool
        /// For `.adopt`: the existing file's USB-relative path.
        public var adoptFrom: String? = nil
    }

    public struct PlaylistEntry: Sendable {
        public var source: SourcePlaylist
        public var playlistId: Int
        public var parentPlaylistId: Int?
        public var sequenceNo: Int
        public var contentIds: [Int]
        public var action: PlaylistAction
    }

    public struct Skipped: Sendable {
        public var playlist: String
        public var track: String
        public var reason: String
    }

    public var volume: Volume
    public var tracks: [TrackEntry]
    /// Previously synced tracks no longer referenced by any selected playlist.
    public var removedTracks: [Manifest.Track]
    public var playlists: [PlaylistEntry]
    public var removedPlaylists: [Manifest.Playlist]
    public var skipped: [Skipped]
    public var manifest: Manifest

    public var bytesToCopy: Int64 {
        tracks.filter { $0.action == .add || $0.action == .replace }.reduce(0) { $0 + $1.fileSize }
    }
    public var analysisCount: Int { tracks.filter(\.needsAnalysis).count }
    public var hasChanges: Bool {
        tracks.contains { $0.action != .unchanged } || !removedTracks.isEmpty
            || playlists.contains { $0.action != .unchanged } || !removedPlaylists.isEmpty
    }
}

public struct SyncPlanner {
    let library: SourceLibrary
    let cache: AnalysisCache
    let policy: AnalysisPolicy

    public init(library: SourceLibrary, cache: AnalysisCache, policy: AnalysisPolicy = AnalysisPolicy()) {
        self.library = library
        self.cache = cache
        self.policy = policy
    }

    /// `entireLibrary`: sync every playlist plus songs that aren't in any playlist (requires a library
    /// loaded with all songs).
    /// `adoptable`: audio hash → USB path of existing, unowned files on the drive (see AdoptScanner).
    public func plan(volume: Volume, selectedPlaylistIds: [String], entireLibrary: Bool = false, previous: Manifest,
                     adoptable: [String: String] = [:], verifyFiles: Bool = true) throws -> SyncPlan {
        var adoptable = adoptable
        var manifest = previous
        let selectedPlaylistIds = entireLibrary ? library.playlists.map(\.id) : selectedPlaylistIds
        manifest.selectedPlaylistIds = selectedPlaylistIds
        manifest.entireLibrary = entireLibrary

        let playlists = library.selection(Set(selectedPlaylistIds))
        var skipped: [SyncPlan.Skipped] = []
        var entries: [String: SyncPlan.TrackEntry] = [:]
        var order: [String] = []
        var superseded: [Manifest.Track] = []

        // Tracks, in first-seen playlist order; then (entire library) songs in no playlist.
        var groups = playlists.filter { !$0.isFolder }
        if entireLibrary, let all = library.allTrackIds {
            groups.append(SourcePlaylist(id: "", name: "Library", trackIds: all))
        }
        for p in groups {
            for id in p.trackIds where entries[id] == nil {
                guard let t = library.tracks[id] else { continue }
                if let reason = Self.eligibilityProblem(t) {
                    if !skipped.contains(where: { $0.playlist == p.name && $0.track == display(t) }) {
                        skipped.append(.init(playlist: p.name, track: display(t), reason: reason))
                    }
                    continue
                }
                let file = t.location!
                let hash = try cache.contentHash(of: file)
                let prev = previous.tracks[id]
                var action: SyncPlan.Action
                let usbPath: String
                let contentId: Int
                if let prev, prev.contentHash == hash {
                    usbPath = prev.usbPath
                    contentId = prev.contentId
                    let present = !verifyFiles || FileManager.default.fileExists(atPath: volume.url(forUsbPath: usbPath).path)
                    action = present ? .unchanged : .replace
                } else {
                    usbPath = Self.usbPath(for: t, file: file, hash: hash)
                    if let prev { superseded.append(prev) }
                    contentId = prev?.contentId ?? manifest.nextContentId
                    if prev == nil { manifest.nextContentId += 1 }
                    action = prev == nil ? .add : .replace
                }
                let analyzed = cache.analysis(forHash: hash, policy: policy) != nil
                let anlzPresent = !verifyFiles || FileManager.default.fileExists(
                    atPath: volume.url(forUsbPath: AnlzPath.directory(forAudioPath: usbPath) + "/ANLZ0000.DAT").path)
                if action == .unchanged && (!anlzPresent || prev?.analysisVersion != TrackAnalysis.currentVersion) {
                    action = .replace
                }
                var adoptFrom: String?
                if action != .unchanged, let existing = adoptable.removeValue(forKey: hash) {
                    action = .adopt
                    adoptFrom = existing
                }
                entries[id] = .init(source: t, sourceFile: file, contentHash: hash, usbPath: usbPath, contentId: contentId,
                                    fileSize: FileOps.size(file), action: action, needsAnalysis: !analyzed, adoptFrom: adoptFrom)
                order.append(id)
            }
        }

        let tracks = order.compactMap { entries[$0] }
        let keptIds = Set(order)
        let removed = (previous.tracks.filter { !keptIds.contains($0.key) }.map(\.value) + superseded)
            .filter { r in !tracks.contains { $0.usbPath == r.usbPath } }
        manifest.tracks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.source.id, Manifest.Track(contentId: $0.contentId, usbPath: $0.usbPath, contentHash: $0.contentHash,
                                          analysisVersion: TrackAnalysis.currentVersion,
                                          anlzFingerprint: $0.action == .unchanged ? previous.tracks[$0.source.id]?.anlzFingerprint : nil))
        })

        // Playlists: stable IDs, sibling order follows source order.
        var playlistEntries: [SyncPlan.PlaylistEntry] = []
        var idFor: [String: Int] = [:]
        var siblingCount: [String: Int] = [:]
        for p in playlists {
            let id = previous.playlists[p.id]?.playlistId ?? {
                defer { manifest.nextPlaylistId += 1 }
                return manifest.nextPlaylistId
            }()
            idFor[p.id] = id
        }
        for p in playlists {
            let parent = p.parentId.flatMap { idFor[$0] }
            let parentKey = p.parentId.flatMap { idFor[$0] == nil ? nil : $0 } ?? ""
            let sequenceNo = siblingCount[parentKey, default: 0]
            siblingCount[parentKey] = sequenceNo + 1
            let contentIds = p.trackIds.compactMap { entries[$0]?.contentId }
            let record = Manifest.Playlist(playlistId: idFor[p.id]!, name: p.name, parentPlaylistId: parent,
                                           sequenceNo: sequenceNo, contentIds: contentIds)
            let action: SyncPlan.PlaylistAction = previous.playlists[p.id] == nil ? .create
                : previous.playlists[p.id] == record ? .unchanged : .change
            playlistEntries.append(.init(source: p, playlistId: record.playlistId, parentPlaylistId: parent,
                                         sequenceNo: record.sequenceNo, contentIds: contentIds, action: action))
        }
        let keptPlaylists = Set(playlists.map(\.id))
        let removedPlaylists = previous.playlists.filter { !keptPlaylists.contains($0.key) }.map(\.value)
        manifest.playlists = Dictionary(uniqueKeysWithValues: playlistEntries.map {
            ($0.source.id, Manifest.Playlist(playlistId: $0.playlistId, name: $0.source.name, parentPlaylistId: $0.parentPlaylistId,
                                             sequenceNo: $0.sequenceNo, contentIds: $0.contentIds))
        })

        return SyncPlan(volume: volume, tracks: tracks, removedTracks: removed, playlists: playlistEntries,
                        removedPlaylists: removedPlaylists, skipped: skipped, manifest: manifest)
    }

    private func display(_ t: SourceTrack) -> String {
        [t.artist, t.title].compactMap { $0 }.joined(separator: " — ")
    }

    /// Why a track can't be exported, or nil if it can.
    public static func eligibilityProblem(_ t: SourceTrack) -> String? {
        if let r = t.unavailableReason { return r }
        guard let url = t.location else { return "Track has no local file" }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: url.path) ? "Local file is not readable: \(url.path)" : "Local file is missing: \(url.path)"
        }
        guard AudioFileType(fileExtension: url.pathExtension) != nil else {
            return "Unsupported file type (.\(url.pathExtension))"
        }
        return nil
    }

    /// "/Contents/Deckhand/<hh>/<Artist - Title> [<hash8>].<ext>"
    static func usbPath(for t: SourceTrack, file: URL, hash: String) -> String {
        let base = [t.artist, t.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        let name = sanitize(base.isEmpty ? file.deletingPathExtension().lastPathComponent : base)
        let digest = hash.split(separator: ":").last.map(String.init) ?? hash
        return "/Contents/Deckhand/\(digest.prefix(2))/\(name) [\(digest.prefix(8))].\(file.pathExtension.lowercased())"
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
