import AVFoundation
import DeckhandCore
import Foundation
import MusicSource

public struct LibraryConnection: Codable, Sendable, Identifiable, Equatable {
    public var connection: SourceConnection
    public var lastImported: Date?
    public var error: String?
    /// Optional for databases written before import management existed. Cached provenance is retained.
    public var removed: Bool? = nil
    public var isConnected: Bool { removed != true }
    public var id: String { connection.id }
}

public struct DeckhandLibrarySnapshot: Sendable {
    public var revision: UInt64 = 0
    public var library: SourceLibrary
    public var connections: [LibraryConnection]
    public var selectedSourceID: String?
    public var initialized: Bool
    public var conflicts: [String]
}

/// One durable library owns every playlist and rating. Sources contribute data; switching and disconnecting
/// them never removes records. Transactions save only changed rows. A read failure never becomes an empty import.
public actor DeckhandLibraryStore {
    public static var defaultDirectory: URL {
        if let value = ProcessInfo.processInfo.environment["DECKHAND_LIBRARY_DIR"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Deckhand/Library")
    }
    public static func databaseURL(in directory: URL = defaultDirectory) -> URL { directory.appendingPathComponent("library.sqlite") }
    private struct Metadata: Codable, Equatable {
        var id = "deckhand:\(UUID().uuidString)"
        var initialized = false
        var selectedSourceID: String?
        var tracks: [String] = []
        var playlists: [String] = []
        var sources: [String] = []
        var musicReceipt = MusicExportReceipt()
    }
    private struct Track: Codable, Equatable {
        var value: SourceTrack
        var sourceID: String
        var ratingEdited = false
        /// A manually chosen local file survives re-import. Optional for older saved libraries.
        var locationEdited: Bool? = nil
    }
    private struct Playlist: Codable, Equatable {
        var value: SourcePlaylist
        var sourceID: String?
        var externalID: String?
        var baseline: SourcePlaylist?
        var edited = false
        // Optional for libraries saved before local folder organization existed.
        var placementEdited: Bool? = nil
        var conflict = false
    }
    private struct Source: Codable {
        var revision = 0
        var status: LibraryConnection
        var trackIDs: [String: String] = [:]
        var playlistIDs: [String: String] = [:]
        /// Local deletions survive re-import. Optional for existing databases.
        var deletedPlaylistIDs: Set<String>? = nil
        var files: [String: IndexedAudioFile] = [:]
        var xml: Data?
    }
    private struct State {
        var metadata = Metadata()
        var tracks: [String: Track] = [:]
        var playlists: [String: Playlist] = [:]
        var sources: [String: Source] = [:]
    }
    private let database: LibraryDatabase
    private var state: State
    private var refreshVersions: [String: Int] = [:]
    private var revision: UInt64 = 0

    public init(directory: URL = DeckhandLibraryStore.defaultDirectory) throws {
        database = try LibraryDatabase(url: Self.databaseURL(in: directory))
        var state = try Self.read(database)
        if try database.scalar("SELECT COUNT(*) FROM metadata") == "0" {
            try database.put(state.metadata, id: "library", table: "metadata")
        }
        try Self.validate(state)
        Self.checkFiles(&state)
        self.state = state
    }

    public func close() { database.close() }

    /// CLI reads use an ordinary read transaction so tracks and membership always come from one commit.
    public static func savedLibrary(in directory: URL = defaultDirectory) throws -> SourceLibrary? {
        guard FileManager.default.fileExists(atPath: databaseURL(in: directory).path) else { return nil }
        let db = try LibraryDatabase(url: databaseURL(in: directory), readOnly: true)
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        var state = try read(db)
        try validate(state)
        guard state.metadata.initialized else { return nil }
        checkFiles(&state)
        return snapshot(state).library
    }

    public func snapshot(checkAvailability: Bool = false) -> DeckhandLibrarySnapshot {
        if checkAvailability { Self.checkFiles(&state) }
        var snapshot = Self.snapshot(state)
        snapshot.revision = revision
        return snapshot
    }

    public func startEmpty() throws -> DeckhandLibrarySnapshot {
        var next = state
        next.metadata.initialized = true
        try commit(next)
        return snapshot()
    }

    public func selectSource(_ id: String?) throws -> DeckhandLibrarySnapshot {
        guard id == nil || state.sources[id!]?.status.isConnected == true else { throw DeckhandLibraryError.invalid("Import connection no longer exists.") }
        var next = state
        next.metadata.selectedSourceID = id
        try commit(next)
        return snapshot(checkAvailability: true)
    }

    /// A disconnected source remains recorded for reconnect and for playlist provenance.
    public func disconnectSource() throws -> DeckhandLibrarySnapshot { try selectSource(nil) }

    /// Stop offering this connection for updates; keep its mappings, cached XML and every saved record.
    public func removeConnection(_ id: String) throws -> DeckhandLibrarySnapshot {
        guard var source = state.sources[id] else { throw DeckhandLibraryError.invalid("Import connection no longer exists.") }
        var next = state
        source.status.removed = true
        source.revision += 1
        next.sources[id] = source
        if next.metadata.selectedSourceID == id { next.metadata.selectedSourceID = nil }
        try commit(next)
        refreshVersions[id, default: 0] += 1
        return snapshot(checkAvailability: true)
    }

    public func refresh(_ connection: SourceConnection, makePrimary: Bool = true) async throws -> DeckhandLibrarySnapshot {
        guard connection.kind != .music else { throw DeckhandLibraryError.invalid("Read Music through its serial bridge, then import the snapshot.") }
        let version = (refreshVersions[connection.id] ?? 0) + 1
        refreshVersions[connection.id] = version
        do {
            let adapter: any LibrarySourceAdapter = connection.kind == .folder ? FolderSource(connection: connection) : RekordboxSource(connection: connection)
            let read = try await adapter.load(files: state.sources[connection.id]?.files ?? [:])
            guard refreshVersions[connection.id] == version else { return snapshot() }
            return try importLibrary(read.library, from: connection, files: read.files, xml: read.originalXML, makePrimary: makePrimary)
        } catch {
            if refreshVersions[connection.id] == version { try recordFailure(connection, error: error.localizedDescription) }
            throw error
        }
    }

    public func recordFailure(_ connection: SourceConnection, error: String) throws {
        var next = state
        var source = next.sources[connection.id] ?? Source(status: LibraryConnection(connection: connection))
        source.status.error = error
        source.status.removed = nil
        source.revision += 1
        next.sources[connection.id] = source
        if !next.metadata.sources.contains(connection.id) { next.metadata.sources.append(connection.id) }
        try commit(next)
    }

    public func importLibrary(_ imported: SourceLibrary, from connection: SourceConnection,
                              files: [String: IndexedAudioFile] = [:], xml: Data? = nil,
                              makePrimary: Bool = true) throws -> DeckhandLibrarySnapshot {
        let next = try importState(imported, from: connection, files: files, xml: xml, makePrimary: makePrimary)
        try commit(next)
        return snapshot()
    }

    private func importState(_ imported: SourceLibrary, from connection: SourceConnection,
                             files: [String: IndexedAudioFile], xml: Data?, makePrimary: Bool = true) throws -> State {
        try Self.validateImport(imported)
        var next = state
        var source = next.sources[connection.id] ?? Source(status: LibraryConnection(connection: connection))
        var paths = Dictionary(next.tracks.values.compactMap { t in t.value.location.map { (Self.path($0), t.value.id) } },
                               uniquingKeysWith: { first, _ in first })
        let ordered = imported.allTrackIds ?? []
        let orderedSet = Set(ordered)
        for externalID in ordered + imported.tracks.keys.sorted().filter({ !orderedSet.contains($0) }) {
            guard var track = imported.tracks[externalID] else { continue }
            let locationID = track.location.flatMap { paths[Self.path($0)] }
            let id = source.trackIDs[externalID] ?? locationID ?? (next.tracks[externalID] == nil ? externalID : "deckhand:track:\(UUID().uuidString)")
            source.trackIDs[externalID] = id
            track.id = id
            if let old = next.tracks[id] {
                if old.sourceID == connection.id {
                    if old.ratingEdited { track.rating = old.value.rating }
                    if old.locationEdited == true {
                        track.location = old.value.location
                        track.unavailableReason = old.value.unavailableReason
                        track.fileSize = old.value.fileSize
                        track.modifiedDate = old.value.modifiedDate
                        track.durationSeconds = old.value.durationSeconds
                    }
                    next.tracks[id] = Track(value: track, sourceID: connection.id, ratingEdited: old.ratingEdited,
                                            locationEdited: old.locationEdited)
                } else if old.value.location == nil, track.location != nil {
                    var updated = old
                    updated.value.location = track.location
                    updated.value.unavailableReason = track.unavailableReason
                    next.tracks[id] = updated
                }
            } else {
                next.tracks[id] = Track(value: track, sourceID: connection.id)
                next.metadata.tracks.append(id)
            }
            if let url = track.location { paths[Self.path(url)] = id }
        }
        // Preserve original IDs during migration; otherwise each connection already namespaces its playlist IDs.
        for playlist in imported.playlists {
            let id = source.playlistIDs[playlist.id] ?? (next.playlists[playlist.id] == nil ? playlist.id : "deckhand:playlist:\(UUID().uuidString)")
            source.playlistIDs[playlist.id] = id
        }
        for var playlist in imported.playlists {
            if source.deletedPlaylistIDs?.contains(playlist.id) == true { continue }
            // Managed writeback copies are destinations, not additional imports of our own playlists.
            if connection.kind == .music,
               playlist.id == next.metadata.musicReceipt.folderID || next.metadata.musicReceipt.playlists.values.contains(where: { $0.remoteID == playlist.id }) { continue }
            let externalID = playlist.id
            playlist.id = source.playlistIDs[externalID]!
            playlist.parentId = playlist.parentId.flatMap { source.playlistIDs[$0] }
            playlist.trackIds = playlist.trackIds.compactMap { source.trackIDs[$0] }
            if var old = next.playlists[playlist.id] {
                let baseline = playlist
                if old.placementEdited == true { playlist.parentId = old.value.parentId }
                // The imported baseline is retained independently of the local copy for conflict detection.
                if old.edited {
                    if old.baseline != baseline { old.conflict = old.value != playlist }
                    old.baseline = baseline
                    next.playlists[playlist.id] = old
                } else {
                    old.value = playlist
                    old.baseline = baseline
                    old.conflict = false
                    next.playlists[playlist.id] = old
                }
            } else {
                next.playlists[playlist.id] = Playlist(value: playlist, sourceID: connection.id, externalID: externalID, baseline: playlist)
                next.metadata.playlists.append(playlist.id)
            }
        }
        source.status = LibraryConnection(connection: connection, lastImported: Date(), error: nil)
        source.revision += 1
        source.files = files
        if let xml { source.xml = xml }
        next.sources[connection.id] = source
        if !next.metadata.sources.contains(connection.id) { next.metadata.sources.append(connection.id) }
        next.metadata.initialized = true
        if makePrimary { next.metadata.selectedSourceID = connection.id }
        Self.checkFiles(&next)
        return next
    }

    public func createPlaylist(named name: String, isFolder: Bool = false, trackIDs: [String] = []) throws -> DeckhandLibrarySnapshot {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeckhandLibraryError.invalid("Give the playlist a name.") }
        guard !state.playlists.values.contains(where: { $0.value.parentId == nil && $0.value.name == name }) else {
            throw DeckhandLibraryError.invalid("A playlist with that name already exists. Choose another name.")
        }
        var next = state
        let id = "deckhand:playlist:\(UUID().uuidString)"
        var seen = Set<String>()
        let members = isFolder ? [] : trackIDs.filter { state.tracks[$0] != nil && seen.insert($0).inserted }
        next.playlists[id] = Playlist(value: SourcePlaylist(id: id, name: name, isFolder: isFolder, trackIds: members), edited: true)
        next.metadata.playlists.append(id)
        next.metadata.initialized = true
        try commit(next)
        return snapshot()
    }

    /// Move the existing record, preserving track membership and identity. Validation and saving are atomic.
    public func movePlaylist(_ id: String, toFolder parentID: String?) throws -> DeckhandLibrarySnapshot {
        guard let record = state.playlists[id] else { throw DeckhandLibraryError.invalid("Choose an existing playlist or folder.") }
        if let parentID {
            guard state.playlists[parentID]?.value.isFolder == true else {
                throw DeckhandLibraryError.invalid("Move playlists into an existing folder.")
            }
            var ancestor: String? = parentID
            while let current = ancestor {
                guard current != id else { throw DeckhandLibraryError.invalid("A folder cannot be moved into itself or its subfolders.") }
                ancestor = state.playlists[current]?.value.parentId
            }
        }
        guard record.value.parentId != parentID else { return snapshot() }
        return try positionPlaylist(id, toFolder: parentID, before: nil)
    }

    public func add(trackIDs: [String], to playlistID: String) throws -> DeckhandLibrarySnapshot {
        try editPlaylist(playlistID) { playlist in
            var seen = Set(playlist.trackIds)
            playlist.trackIds += trackIDs.filter { state.tracks[$0] != nil && seen.insert($0).inserted }
        }
    }

    /// Place a playlist among a folder's children (or the library's top level). A nil anchor appends.
    /// Parent, order and provenance are committed together; playlist IDs and contents never change.
    public func positionPlaylist(_ id: String, toFolder parentID: String?, before anchorID: String?) throws -> DeckhandLibrarySnapshot {
        guard var record = state.playlists[id] else { throw DeckhandLibraryError.invalid("Choose an existing playlist or folder.") }
        if let parentID {
            guard state.playlists[parentID]?.value.isFolder == true else { throw DeckhandLibraryError.invalid("Choose an existing folder.") }
            var ancestor: String? = parentID
            while let current = ancestor {
                guard current != id else { throw DeckhandLibraryError.invalid("A folder cannot be moved into itself or its subfolders.") }
                ancestor = state.playlists[current]?.value.parentId
            }
        }
        if let anchorID {
            guard anchorID != id, let anchor = state.playlists[anchorID], anchor.value.parentId == parentID else {
                throw DeckhandLibraryError.invalid("The destination playlist moved. Try the drop again.")
            }
        }
        var next = state
        record.value.parentId = parentID
        record.placementEdited = true
        next.playlists[id] = record
        next.metadata.playlists.removeAll { $0 == id }
        let index = anchorID.flatMap { next.metadata.playlists.firstIndex(of: $0) } ?? next.metadata.playlists.endIndex
        next.metadata.playlists.insert(id, at: index)
        let before = state.metadata.playlists.filter { state.playlists[$0]?.value.parentId == parentID }
        let after = next.metadata.playlists.filter { next.playlists[$0]?.value.parentId == parentID }
        guard record.value.parentId != state.playlists[id]?.value.parentId || before != after else { return snapshot() }
        try commit(next)
        return snapshot()
    }

    /// Deletes only the playlist; its tracks, ratings and source library are retained.
    public func deletePlaylist(_ id: String) throws -> DeckhandLibrarySnapshot {
        guard let record = state.playlists[id], !record.value.isFolder else {
            throw DeckhandLibraryError.invalid("Choose an existing playlist.")
        }
        var next = state
        next.playlists.removeValue(forKey: id)
        next.metadata.playlists.removeAll { $0 == id }
        if let sourceID = record.sourceID, let externalID = record.externalID, var source = next.sources[sourceID] {
            source.deletedPlaylistIDs = (source.deletedPlaylistIDs ?? []).union([externalID])
            source.revision += 1
            next.sources[sourceID] = source
        }
        try commit(next)
        return snapshot()
    }

    public func remove(trackIDs: [String], from playlistID: String) throws -> DeckhandLibrarySnapshot {
        let drop = Set(trackIDs)
        return try editPlaylist(playlistID) { $0.trackIds.removeAll { drop.contains($0) } }
    }

    public func replacePlaylist(_ playlist: SourcePlaylist) throws -> DeckhandLibrarySnapshot {
        guard playlist.trackIds.allSatisfy({ state.tracks[$0] != nil }) else { throw DeckhandLibraryError.invalid("The playlist refers to unknown tracks.") }
        return try editPlaylist(playlist.id) { $0.trackIds = playlist.trackIds }
    }

    private func editPlaylist(_ id: String, _ change: (inout SourcePlaylist) -> Void) throws -> DeckhandLibrarySnapshot {
        guard var record = state.playlists[id], !record.value.isFolder else { throw DeckhandLibraryError.invalid("Choose an existing playlist.") }
        var next = state
        change(&record.value)
        record.edited = true
        record.conflict = false
        next.playlists[id] = record
        try commit(next)
        return snapshot()
    }

    public func setRating(_ stars: Int, ids: [String]) throws -> DeckhandLibrarySnapshot {
        var next = state
        for id in ids where next.tracks[id] != nil {
            next.tracks[id]?.value.rating = stars == 0 ? nil : max(1, min(5, stars))
            next.tracks[id]?.ratingEdited = true
        }
        try commit(next)
        return snapshot()
    }

    /// Repair a track's audio without creating a duplicate or changing its playlist membership.
    public func locateAudioFile(for trackID: String, at url: URL) throws -> DeckhandLibrarySnapshot {
        guard var track = state.tracks[trackID] else { throw DeckhandLibraryError.invalid("This track is no longer in the library.") }
        let url = url.standardizedFileURL
        guard url.isFileURL, ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac"].contains(url.pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw DeckhandLibraryError.invalid("Choose a readable MP3, M4A, WAV, AIFF, AAC or FLAC audio file.")
        }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: url) }
        catch { throw DeckhandLibraryError.invalid("This file couldn't be opened as unprotected audio. Choose another audio file.") }
        guard audio.length > 0, audio.processingFormat.sampleRate > 0 else {
            throw DeckhandLibraryError.invalid("This audio file is empty.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        track.value.location = url
        track.value.unavailableReason = nil
        track.value.fileSize = (attributes[.size] as? NSNumber)?.int64Value
        track.value.modifiedDate = attributes[.modificationDate] as? Date
        track.value.durationSeconds = Double(audio.length) / audio.processingFormat.sampleRate
        track.locationEdited = true
        var next = state
        next.tracks[trackID] = track
        try commit(next)
        return snapshot()
    }

    public func rekordboxExport(for sourceID: String) throws -> RekordboxExport {
        guard let source = state.sources[sourceID], source.status.connection.kind == .rekordbox,
              let url = source.status.connection.location, let xml = source.xml else {
            throw DeckhandLibraryError.invalid("Import a Rekordbox XML source before exporting back to it.")
        }
        let originalIDs = Dictionary(source.trackIDs.map { external, local in
            (local, external.components(separatedBy: ":track:").last ?? external)
        }, uniquingKeysWith: { first, _ in first })
        return RekordboxExport(library: snapshot().library, original: url, originalData: xml, originalIDs: originalIDs)
    }

    public func musicExport(playlistIDs: [String]) throws -> MusicExportPlan {
        let library = snapshot().library
        let wanted = Set(playlistIDs)
        let selected = library.playlists.filter { wanted.contains($0.id) && !$0.isFolder }
        guard !selected.isEmpty else { throw DeckhandLibraryError.invalid("Select at least one playlist to sync to Music.") }
        let ids = Set(selected.flatMap(\.trackIds))
        let aliases = Dictionary((state.sources["apple-music"]?.trackIDs ?? [:]).map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        return MusicExportPlan(playlists: selected, tracks: library.tracks.filter { ids.contains($0.key) },
                               knownTrackIDs: aliases, ratingIDs: Set(ids.filter { state.tracks[$0]?.ratingEdited == true }),
                               receipt: state.metadata.musicReceipt)
    }

    public func saveMusicReceipt(_ receipt: MusicExportReceipt) throws {
        var next = state
        next.metadata.musicReceipt = receipt
        try commit(next)
    }

    /// Moves the first source-specific implementation's cached playlists and edits into the shared library once.
    /// Old files remain intact, and a source's local changes take precedence over its cached import.
    public func migrateLegacy(_ connections: [SourceConnection], directory: URL) async throws {
        for connection in connections where connection.kind != .music && state.sources[connection.id] == nil {
            let old = try LocalLibraryStore(connection: connection, directory: directory)
            guard let migration = await old.migrationRead() else { continue }
            let xml = connection.kind == .rekordbox ? try? connection.location.map { try Data(contentsOf: $0) } : nil
            var next = try importState(migration.imported, from: connection, files: migration.files, xml: xml ?? nil)
            for playlist in migration.edited.playlists {
                guard let localID = next.sources[connection.id]?.playlistIDs[playlist.id] else {
                    if next.playlists[playlist.id] == nil {
                        var value = playlist
                        value.trackIds = playlist.trackIds.map { next.sources[connection.id]?.trackIDs[$0] ?? $0 }
                        next.playlists[playlist.id] = Playlist(value: value, edited: true)
                        next.metadata.playlists.append(playlist.id)
                    }
                    continue
                }
                if migration.editedPlaylistIDs.contains(playlist.id) {
                    var value = playlist
                    value.id = localID
                    value.parentId = playlist.parentId.flatMap { next.sources[connection.id]?.playlistIDs[$0] } ?? playlist.parentId
                    value.trackIds = playlist.trackIds.map { next.sources[connection.id]?.trackIDs[$0] ?? $0 }
                    next.playlists[localID]?.value = value
                    next.playlists[localID]?.edited = true
                }
            }
            for (id, track) in migration.edited.tracks where migration.ratingIDs.contains(id) {
                if let local = next.sources[connection.id]?.trackIDs[id] {
                    next.tracks[local]?.value.rating = track.rating
                    next.tracks[local]?.ratingEdited = true
                }
            }
            try commit(next)
        }
    }

    private static func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private static func checkFiles(_ state: inout State) {
        for id in state.metadata.tracks {
            guard var record = state.tracks[id], let url = record.value.location else { continue }
            let reason = record.value.unavailableReason
            if reason?.contains("Protected (DRM)") == true { continue }
            record.value.unavailableReason = FileManager.default.isReadableFile(atPath: url.path) ? nil : "Audio file is missing or unreadable"
            state.tracks[id] = record
        }
    }
    private static func snapshot(_ state: State) -> DeckhandLibrarySnapshot {
        var library = SourceLibrary(playlists: state.metadata.playlists.compactMap { state.playlists[$0]?.value },
                                    tracks: state.tracks.mapValues(\.value))
        library.sourceID = state.metadata.id
        library.sourceAliases = state.metadata.sources
        library.allTrackIds = state.metadata.tracks
        library.artwork = FileArtwork(tracks: library.tracks)
        return DeckhandLibrarySnapshot(library: library, connections: state.metadata.sources.compactMap { state.sources[$0]?.status },
                                      selectedSourceID: state.metadata.selectedSourceID, initialized: state.metadata.initialized,
                                      conflicts: state.metadata.playlists.filter { state.playlists[$0]?.conflict == true })
    }
    private static func read(_ database: LibraryDatabase) throws -> State {
        var state = State()
        let metadata = try database.records(Metadata.self, table: "metadata")
        if let value = metadata["library"] { state.metadata = value }
        state.tracks = try database.records(Track.self, table: "tracks")
        state.playlists = try database.records(Playlist.self, table: "playlists")
        state.sources = try database.records(Source.self, table: "sources")
        return state
    }
    private static func validateImport(_ lib: SourceLibrary) throws {
        guard Set(lib.playlists.map(\.id)).count == lib.playlists.count, lib.tracks.allSatisfy({ $0.key == $0.value.id }),
              (lib.allTrackIds ?? []).allSatisfy({ lib.tracks[$0] != nil }),
              Set(lib.allTrackIds ?? []).count == (lib.allTrackIds ?? []).count,
              lib.playlists.allSatisfy({ $0.trackIds.allSatisfy { lib.tracks[$0] != nil } }) else {
            throw DeckhandLibraryError.invalid("The source contains duplicate IDs or unknown playlist tracks.")
        }
        let folders = Dictionary(uniqueKeysWithValues: lib.playlists.map { ($0.id, $0) })
        for p in lib.playlists {
            var seen = Set([p.id]), parent = p.parentId
            while let id = parent {
                guard seen.insert(id).inserted, let folder = folders[id], folder.isFolder else {
                    throw DeckhandLibraryError.invalid("The source contains an invalid playlist hierarchy.")
                }
                parent = folder.parentId
            }
        }
    }
    private static func validate(_ state: State) throws {
        let metadata = state.metadata
        guard Set(metadata.tracks).count == metadata.tracks.count, Set(metadata.playlists).count == metadata.playlists.count,
              Set(metadata.tracks) == Set(state.tracks.keys), Set(metadata.playlists) == Set(state.playlists.keys),
              Set(metadata.sources) == Set(state.sources.keys),
              metadata.tracks.allSatisfy({ state.tracks[$0]?.value.id == $0 }),
              metadata.playlists.allSatisfy({ state.playlists[$0]?.value.id == $0 }),
              metadata.sources.allSatisfy({ state.sources[$0]?.status.id == $0 }) else {
            throw DeckhandLibraryError.invalid("The saved Deckhand library contains inconsistent records. Keep the database for recovery.")
        }
        try validateImport(snapshot(state).library)
    }
    private func commit(_ next: State) throws {
        try Self.validate(next)
        try database.execute("BEGIN IMMEDIATE")
        do {
            if next.metadata != state.metadata { try database.put(next.metadata, id: "library", table: "metadata") }
            for (id, record) in next.tracks where record != state.tracks[id] { try database.put(record, id: id, table: "tracks") }
            for (id, record) in next.playlists where record != state.playlists[id] { try database.put(record, id: id, table: "playlists") }
            for id in state.playlists.keys where next.playlists[id] == nil { try database.delete(id: id, table: "playlists") }
            // Source refreshes are relatively infrequent; file indexes and aliases are one atomic source record.
            for (id, record) in next.sources where record.revision != state.sources[id]?.revision {
                try database.put(record, id: id, table: "sources")
            }
            try database.execute("COMMIT")
            state = next
            revision &+= 1
        } catch { try? database.execute("ROLLBACK"); throw error }
    }
}

public struct RekordboxExport: Sendable {
    public var library: SourceLibrary
    public var original: URL
    public var originalData: Data
    public var originalIDs: [String: String]
    public func write(to url: URL) throws {
        try RekordboxSource.export(library, original: original, to: url, originalData: originalData, originalTrackIDs: originalIDs)
    }
}
