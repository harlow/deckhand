import DeckhandCore
import Foundation
import Sync

/// What a sync would change on a drive, as the app shows it. Built from one `SyncStatus` evaluation, so the track
/// dots, playlist badges, "N to sync", bytes and "won't fit" can't disagree with each other or with the CLI. Views
/// look tracks and playlists up by ID.
public struct DriveStatus: Sendable, Equatable {
    public enum Track: Sendable, Equatable {
        /// On the drive and up to date.
        case synced
        /// The next sync copies, updates or removes it.
        case pending
        /// On the drive, and kept there although its source can't be read right now.
        case retained(String)
        /// On the drive without analysis: the analyzer failed on it.
        case failed(String)
        /// Can't go on the drive: no local file, DRM, unsupported format.
        case ineligible(String)
        /// Not known yet (its audio hasn't been hashed): shown as neither synced nor pending.
        case unknown
    }

    public enum Playlist: Sendable, Equatable {
        case synced
        /// Changes waiting: its tracks with work to do, and at least 1 if the playlist itself changes.
        case pending(Int)
        /// Holds a track that isn't known yet.
        case unknown
    }

    public var driveId: String
    /// The manifest generation evaluated.
    public var generation: Int
    /// Tracks the selection puts on the drive, plus tracks leaving it.
    public var tracks: [String: Track]
    /// The selected playlists and the folders above them.
    public var playlists: [String: Playlist]
    /// Of `tracks`, those the drive holds right now.
    public var onDrive: Set<String>
    /// Tracks the next sync removes.
    public var leaving: Set<String>
    public var summary: ChangeSet.Summary
    /// Free space the next sync needs (`ChangeSet.spaceNeeded`, as the executor checks it).
    public var spaceNeeded: Int64
    /// Free space on the drive when it was last read.
    public var available: Int64
    /// Every fact was known.
    public var complete: Bool
    /// Shown clean on a sync's word, before reading the drive and library again confirmed it.
    public var optimistic = false
    /// What's pending, one line each: tracks (with what changes), removals, playlists, drive changes.
    public var details: [String]

    public var pendingCount: Int { summary.total }
    public var isClean: Bool { summary.total == 0 }
    public var bytesToCopy: Int64 { summary.bytesToCopy }
    /// The next sync would stop for lack of space (the executor's check).
    public var wontFit: Bool { !isClean && spaceNeeded > available }

    public init(_ c: ChangeSet, driveId: String, available: Int64) {
        self.driveId = driveId
        generation = c.base.generationNumber
        self.available = available
        summary = c.summary
        spaceNeeded = c.spaceNeeded
        complete = c.isComplete
        var tracks: [String: Track] = [:]
        var onDrive = Set<String>()
        var details: [String] = []
        tracks.reserveCapacity(c.tracks.count)
        for t in c.tracks {
            let status: Track
            switch t.status {
            case .clean: status = .synced
            case .pending(let changes):
                status = .pending
                details.append("\(Self.display(t.source)): \(changes.sorted().map(Self.describe).joined(separator: ", "))")
            case .retained(let r): status = .retained(r)
            case .failed(let r): status = .failed(r)
            case .ineligible(let r): status = .ineligible(r)
            case .unknown: status = .unknown
            }
            tracks[t.id] = status
            if c.base.tracks[t.id] != nil, !t.changes.contains(.missingOnDrive) {
                if case .ineligible = status {} else { onDrive.insert(t.id) }
            }
        }
        var leaving = Set<String>()
        for r in c.removedTracks where r.reason != .superseded {
            leaving.insert(r.id)
            if tracks[r.id] == nil {
                tracks[r.id] = .pending
                onDrive.insert(r.id)
            }
            details.append("\((r.record.usbPath as NSString).lastPathComponent): "
                           + (r.reason == .lost ? "source and drive copy gone, forgotten" : "leaving the drive"))
        }

        var playlists: [String: Playlist] = [:]
        let children = Dictionary(grouping: c.playlists, by: { $0.source.parentId ?? "" })
        // Pending track IDs and whether anything is unknown, for a playlist and everything inside it.
        func walk(_ p: ChangeSet.Playlist) -> (pending: Set<String>, changed: Bool, unknown: Bool) {
            var pending = Set<String>(), changed = false, unknown = false
            switch p.status {
            case .clean: break
            case .pending(let changes):
                changed = true
                let what = changes.map(\.rawValue).sorted().joined(separator: ", ")
                details.append("\(p.source.isFolder ? "Folder" : "Playlist") “\(p.source.name)”: \(what)")
            case .unknown: unknown = true
            }
            if p.source.isFolder {
                for child in children[p.source.id] ?? [] {
                    let r = walk(child)
                    pending.formUnion(r.pending)
                    changed = changed || r.changed
                    unknown = unknown || r.unknown
                }
            } else {
                for id in p.source.trackIds where tracks[id] == .pending { pending.insert(id) }
            }
            let state: Playlist = changed || !pending.isEmpty ? .pending(max(pending.count, 1))
                : unknown ? .unknown : .synced
            playlists[p.source.id] = state
            return (pending, changed, unknown)
        }
        let ids = Set(c.playlists.map(\.source.id))
        for p in c.playlists where p.source.parentId.map({ !ids.contains($0) }) ?? true { _ = walk(p) }
        for p in c.removedPlaylists { details.append("Playlist “\(p.name)”: leaving the drive") }
        for change in c.drive.sorted(by: { $0.rawValue < $1.rawValue }) {
            // Old manifests never recorded a database identity; a missing identity doesn't prove replacement.
            details.append(change == .databaseChanged && c.base.databaseId == nil
                ? "Update the USB's library database for this version of Deckhand" : Self.describe(change))
        }

        self.tracks = tracks
        self.playlists = playlists
        self.onDrive = onDrive
        self.leaving = leaving
        self.details = details
    }

    /// The status a clean sync leaves: what was pending is synced and what was leaving is gone. Shown until reading
    /// the drive and library again confirms it.
    public func markedClean() -> DriveStatus {
        var s = self
        for (id, t) in tracks where t == .pending {
            if leaving.contains(id) {
                s.tracks[id] = nil
                s.onDrive.remove(id)
            } else {
                s.tracks[id] = .synced
                s.onDrive.insert(id)
            }
        }
        s.leaving = []
        for (id, p) in playlists { if case .pending = p { s.playlists[id] = .synced } }
        var sum = summary
        sum.clean += sum.pending
        sum.tracks = sum.clean + sum.ineligible + sum.retained + sum.failed + sum.unknown
        sum.pending = 0
        sum.toCopy = 0; sum.toAdopt = 0; sum.toAnalyze = 0; sum.analysisFiles = 0; sum.records = 0; sum.artwork = 0
        sum.toRemove = 0
        sum.playlistsToCreate = 0; sum.playlistsToUpdate = 0; sum.playlistsToRemove = 0
        sum.drive = []
        sum.bytesToCopy = 0
        sum.total = 0
        s.summary = sum
        s.spaceNeeded = SyncStatus.spaceMargin
        s.details = []
        s.optimistic = true
        return s
    }

    static func display(_ t: SourceTrack) -> String {
        [t.artist, t.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func describe(_ change: ChangeSet.TrackChange) -> String {
        switch change {
        case .new: "new"
        case .audioChanged: "audio changed"
        case .missingOnDrive: "missing from the drive"
        case .adopt: "already on the drive"
        case .analyze: "to analyze"
        case .analysisFiles: "analysis files"
        case .record: "database row (title, rating, comment, BPM, …)"
        case .artworkCheck: "cover art"
        }
    }

    static func describe(_ change: ChangeSet.DriveChange) -> String {
        switch change {
        case .settings: "Output settings changed"
        case .selection: "Selection changed"
        case .databaseMissing: "The drive has no library database"
        case .databaseChanged: "The drive's library database was replaced since Deckhand wrote it"
        case .legacyManifest: "Manifest from an older Deckhand to update"
        }
    }
}
