import DeckhandCore
import Foundation
import MusicSource

public struct MusicExportReceipt: Codable, Sendable, Equatable {
    public struct Playlist: Codable, Sendable, Equatable {
        public var remoteID: String
        public var baseline: [String]
        public init(remoteID: String, baseline: [String]) { self.remoteID = remoteID; self.baseline = baseline }
    }
    public var folderID: String?
    public var playlists: [String: Playlist] = [:]
    public var trackIDs: [String: String] = [:]
    public init() {}
}

public struct MusicExportPlan: Sendable {
    public var playlists: [SourcePlaylist]
    public var tracks: [String: SourceTrack]
    public var knownTrackIDs: [String: String]
    public var ratingIDs: Set<String> = []
    public var receipt: MusicExportReceipt
}

/// Kept separate from imports and local saves. Tests substitute a real stateful destination without Music access.
public protocol MusicDestination: Sendable {
    func tracks() async throws -> [SourceTrack]
    func playlistExists(_ id: String) async throws -> Bool
    func playlistTracks(_ id: String) async throws -> [String]
    func createPlaylist(name: String, folder: Bool, parent: String?) async throws -> String
    func addFile(_ track: SourceTrack) async throws -> String
    func replacePlaylist(_ id: String, tracks: [String]) async throws
    func setRating(_ stars: Int, trackID: String) async throws
}

public enum MusicExport {
    /// Only writes copies under a Deckhand folder. Receipts track those copies so retries update them rather
    /// than creating duplicates. External edits to a destination copy stop export before its membership changes.
    public static func execute(_ plan: MusicExportPlan, destination: any MusicDestination,
                               checkpoint: @Sendable (MusicExportReceipt) async throws -> Void) async throws -> MusicExportReceipt {
        var receipt = plan.receipt
        // Preflight every existing destination before adding files or creating anything.
        for playlist in plan.playlists {
            if let saved = receipt.playlists[playlist.id], try await destination.playlistExists(saved.remoteID) {
                guard try await destination.playlistTracks(saved.remoteID) == saved.baseline else {
                    throw DeckhandLibraryError.conflict("“\(playlist.name)” was changed in Music after the last export. Its Music copy was left unchanged.")
                }
            }
        }
        let existing = try await destination.tracks()
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(existing.compactMap { track in track.location.map { (path($0), track.id) } }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: String] = [:]
        for track in plan.tracks.values.sorted(by: { $0.id < $1.id }) {
            let known = receipt.trackIDs[track.id] ?? plan.knownTrackIDs[track.id]
            if let known, byID[known] != nil { resolved[track.id] = known; continue }
            if let url = track.location, let id = byPath[path(url)] { resolved[track.id] = id; continue }
            guard let url = track.location, track.unavailableReason == nil, FileManager.default.isReadableFile(atPath: url.path) else {
                throw DeckhandLibraryError.invalid("“\(track.title)” has no available audio to add to Music. Restore its file and try again.")
            }
        }
        if let id = receipt.folderID, !(try await destination.playlistExists(id)) { receipt.folderID = nil }
        if receipt.folderID == nil {
            receipt.folderID = try await destination.createPlaylist(name: "Deckhand", folder: true, parent: nil)
            try await checkpoint(receipt)
        }
        for track in plan.tracks.values.sorted(by: { $0.id < $1.id }) where resolved[track.id] == nil {
            resolved[track.id] = try await destination.addFile(track)
            receipt.trackIDs[track.id] = resolved[track.id]
            try await checkpoint(receipt)
        }
        receipt.trackIDs.merge(resolved) { _, new in new }
        try await checkpoint(receipt)
        for playlist in plan.playlists {
            let remoteID: String
            if let old = receipt.playlists[playlist.id], try await destination.playlistExists(old.remoteID) {
                // Check again after file imports, which can take time; don't silently overwrite intervening edits.
                guard try await destination.playlistTracks(old.remoteID) == old.baseline else {
                    throw DeckhandLibraryError.conflict("“\(playlist.name)” changed in Music during export. Its Music copy was left unchanged.")
                }
                remoteID = old.remoteID
            } else {
                remoteID = try await destination.createPlaylist(name: playlist.name, folder: false, parent: receipt.folderID)
                receipt.playlists[playlist.id] = .init(remoteID: remoteID, baseline: [])
                try await checkpoint(receipt)
            }
            let ids = playlist.trackIds.compactMap { resolved[$0] }
            guard ids.count == playlist.trackIds.count else { throw DeckhandLibraryError.invalid("A playlist track couldn't be matched in Music.") }
            if ids != receipt.playlists[playlist.id]?.baseline {
                try await destination.replacePlaylist(remoteID, tracks: ids)
                guard try await destination.playlistTracks(remoteID) == ids else {
                    throw DeckhandLibraryError.conflict("Music didn't confirm every track in “\(playlist.name)”. Deckhand's playlist is still saved locally.")
                }
            }
            receipt.playlists[playlist.id] = .init(remoteID: remoteID, baseline: ids)
            try await checkpoint(receipt)
        }
        for id in plan.ratingIDs.sorted() {
            if let remote = resolved[id], let track = plan.tracks[id] { try await destination.setRating(track.rating ?? 0, trackID: remote) }
        }
        return receipt
    }
    private static func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}

/// Music scripting is serial and off the main actor. This is called only by the explicit export action.
public actor AppleMusicDestination: MusicDestination {
    private let queue = DispatchQueue(label: "rocks.deckhand.music-export", qos: .userInitiated)
    public init() {}
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    public func tracks() async throws -> [SourceTrack] { try await perform { try AppleMusicLibrary.allSongs() } }
    public func playlistExists(_ id: String) async throws -> Bool { try await perform { try AppleMusicWriter.playlistExists(id) } }
    public func playlistTracks(_ id: String) async throws -> [String] { try await perform { try AppleMusicWriter.playlistTracks(id) } }
    public func createPlaylist(name: String, folder: Bool, parent: String?) async throws -> String {
        try await perform { try AppleMusicWriter.createPlaylist(named: name, isFolder: folder, inFolder: parent) }
    }
    public func addFile(_ track: SourceTrack) async throws -> String {
        guard let url = track.location else { throw DeckhandLibraryError.invalid("Missing audio for \(track.title).") }
        return try await perform { try AppleMusicWriter.addFile(url, title: track.title, artist: track.artist, album: track.album, genre: track.genre).id }
    }
    public func replacePlaylist(_ id: String, tracks: [String]) async throws {
        try await perform { try AppleMusicWriter.replacePlaylist(id, trackIDs: tracks) }
    }
    public func setRating(_ stars: Int, trackID: String) async throws {
        try await perform {
            try MusicEvents.setRating(stars, trackId: trackID)
            guard try MusicEvents.rating(trackId: trackID) == stars else {
                throw DeckhandLibraryError.conflict("Music didn't confirm the new star rating.")
            }
        }
    }
}
