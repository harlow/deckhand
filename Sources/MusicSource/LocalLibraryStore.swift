import DeckhandCore
import Foundation

/// Durable edits for file/XML libraries. Imported playlists refresh until edited locally; local edits win thereafter.
/// Music keeps its existing write-through ownership rather than introducing two conflicting playlist copies.
public actor LocalLibraryStore {
    public struct MigrationRead: Sendable {
        public var imported: SourceLibrary
        public var edited: SourceLibrary
        public var files: [String: IndexedAudioFile]
        public var editedPlaylistIDs: Set<String>
        public var ratingIDs: Set<String>
    }
    /// Read-only migration into the shared Deckhand library. Never reconnects a source or rewrites old files.
    public func migrationRead() -> MigrationRead? {
        guard let imported else { return nil }
        return MigrationRead(imported: imported, edited: merged(), files: state.files,
                             editedPlaylistIDs: Set(state.playlists.keys), ratingIDs: Set(state.ratings.keys))
    }
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Deckhand/Libraries")
    }
    private struct State: Codable {
        var files: [String: IndexedAudioFile] = [:]
        var playlists: [String: SourcePlaylist] = [:]
        var playlistOrder: [String] = []
        var ratings: [String: Int] = [:]
    }
    private var state: State
    private var imported: SourceLibrary?
    public let connection: SourceConnection
    private let root: URL

    public init(connection: SourceConnection, directory: URL = LocalLibraryStore.directory) throws {
        self.connection = connection
        root = directory.appendingPathComponent(connection.id, isDirectory: true)
        let url = root.appendingPathComponent("edits.json")
        state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        let snapshot = root.appendingPathComponent("snapshot.json")
        if FileManager.default.fileExists(atPath: snapshot.path) {
            imported = try JSONDecoder().decode(SourceLibrary.self, from: Data(contentsOf: snapshot))
        }
    }

    public func load() async throws -> SourceLibrary {
        let adapter: any LibrarySourceAdapter
        switch connection.kind {
        case .folder: adapter = FolderSource(connection: connection)
        case .rekordbox: adapter = RekordboxSource(connection: connection)
        case .music: return try AppleMusicLibrary.load(allSongs: true)
        }
        let read = try await adapter.load(files: state.files)
        let oldState = state, oldImported = imported
        state.files = read.files
        imported = read.library
        // Local playlists can still refer to tracks a refreshed XML no longer lists.
        let references = Set(state.playlists.values.flatMap(\.trackIds))
        for id in references where imported?.tracks[id] == nil {
            if var t = oldImported?.tracks[id] {
                t.unavailableReason = "Track no longer appears in the source collection"
                imported?.tracks[id] = t
                imported?.allTrackIds?.append(id)
            }
        }
        let lib = merged()
        do {
            try persist()
            try JSONEncoder().encode(imported).write(to: root.appendingPathComponent("snapshot.json"), options: .atomic)
        } catch { state = oldState; imported = oldImported; throw error }
        return lib
    }

    public func createPlaylist(named name: String) throws -> SourceLibrary {
        guard !merged().playlists.contains(where: { $0.parentId == nil && $0.name == name }) else {
            throw LibrarySourceError.unavailable("A playlist with that name already exists. Choose another name.")
        }
        let id = "\(connection.id):local:\(UUID().uuidString)"
        var next = state
        next.playlists[id] = SourcePlaylist(id: id, name: name)
        next.playlistOrder.append(id)
        try commit(next)
        return merged()
    }

    public func updatePlaylist(_ playlist: SourcePlaylist) throws -> SourceLibrary {
        var next = state
        if next.playlists[playlist.id] == nil { next.playlistOrder.append(playlist.id) }
        next.playlists[playlist.id] = playlist
        try commit(next)
        return merged()
    }

    public func setRating(_ stars: Int, ids: [String]) throws -> SourceLibrary {
        var next = state
        for id in ids { next.ratings[id] = max(0, min(5, stars)) }
        try commit(next)
        return merged()
    }

    // Compute membership inside the actor so concurrent drops cannot overwrite each other's edits.
    public func add(trackIDs: [String], to playlistID: String) throws -> SourceLibrary {
        let lib = merged()
        guard var playlist = lib.playlists.first(where: { $0.id == playlistID && !$0.isFolder }) else {
            throw LibrarySourceError.unavailable("Playlist no longer exists.")
        }
        var seen = Set(playlist.trackIds)
        playlist.trackIds += trackIDs.filter { lib.tracks[$0] != nil && seen.insert($0).inserted }
        return try updatePlaylist(playlist)
    }

    public func remove(trackIDs: [String], from playlistID: String) throws -> SourceLibrary {
        guard var playlist = merged().playlists.first(where: { $0.id == playlistID && !$0.isFolder }) else {
            throw LibrarySourceError.unavailable("Playlist no longer exists.")
        }
        let drop = Set(trackIDs)
        playlist.trackIds.removeAll { drop.contains($0) }
        return try updatePlaylist(playlist)
    }

    private func merged() -> SourceLibrary {
        var lib = imported ?? SourceLibrary(playlists: [], tracks: [:])
        lib.sourceID = connection.id
        for i in lib.playlists.indices {
            if let local = state.playlists[lib.playlists[i].id] { lib.playlists[i] = local }
        }
        let existing = Set(lib.playlists.map(\.id))
        for id in state.playlistOrder where !existing.contains(id) {
            if var p = state.playlists[id] {
                // If its original parent disappeared from XML, retain the edited playlist at the root.
                if let parent = p.parentId, !existing.contains(parent), state.playlists[parent] == nil { p.parentId = nil }
                lib.playlists.append(p)
            }
        }
        for (id, rating) in state.ratings where lib.tracks[id] != nil { lib.tracks[id]?.rating = rating == 0 ? nil : rating }
        lib.allTrackIds = lib.allTrackIds ?? []
        lib.artwork = FileArtwork(tracks: lib.tracks)
        return lib
    }

    private func commit(_ next: State) throws {
        let previous = state
        state = next
        do { try persist() } catch { state = previous; throw error }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: root.appendingPathComponent("edits.json"), options: .atomic)
    }
}
