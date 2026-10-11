import DeckhandCore
import Foundation
import MusicSource
import Testing
@testable import DeckhandLibrary

/// Stateful Music stand-in: maintains order, duplicates, ratings and file imports, and can fail mid-export.
actor FakeMusicDestination: MusicDestination {
    var songs: [SourceTrack] = []
    var playlists: [String: [String]] = [:]
    var names: [String: String] = [:]
    var parents: [String: String] = [:]
    var nextID = 0
    var mutations = 0
    var failReplacement = false
    var returnWrongMembership = false
    func seed(track: SourceTrack) { songs.append(track) }
    func setFailure(_ value: Bool) { failReplacement = value }
    func change(_ playlist: String, members: [String]) { playlists[playlist] = members }
    func tracks() -> [SourceTrack] { songs }
    func playlistExists(_ id: String) -> Bool { playlists[id] != nil }
    func playlistTracks(_ id: String) throws -> [String] {
        guard let tracks = playlists[id] else { throw DeckhandLibraryError.invalid("Missing fixture playlist") }
        return tracks
    }
    func createPlaylist(name: String, folder: Bool, parent: String?) -> String {
        nextID += 1; let id = "P\(nextID)"; playlists[id] = []; names[id] = name; parents[id] = parent; mutations += 1; return id
    }
    func addFile(_ track: SourceTrack) -> String {
        var added = track; nextID += 1; added.id = "T\(nextID)"; songs.append(added); mutations += 1; return added.id
    }
    func replacePlaylist(_ id: String, tracks: [String]) throws {
        if failReplacement { throw DeckhandLibraryError.database("Fixture destination stopped") }
        playlists[id] = returnWrongMembership ? Array(tracks.dropLast()) : tracks; mutations += 1
    }
    func setRating(_ stars: Int, trackID: String) {
        if let i = songs.firstIndex(where: { $0.id == trackID }) { songs[i].rating = stars == 0 ? nil : stars }
        mutations += 1
    }
}

@Suite struct MusicExportTests {
    @Test func explicitExportCopiesPlaylistsPreservesDuplicatesAndAvoidsRepeatedImports() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.importLibrary(f.music(url, members: ["MUSIC1", "MUSIC1"]), from: SourceConnection(kind: .music))
        _ = try await store.setRating(5, ids: ["MUSIC1"])
        let destination = FakeMusicDestination()
        await destination.seed(track: SourceTrack(id: "MUSIC1", title: "Existing", rating: 1, location: url))
        #expect(await destination.mutations == 0) // Imports and local rating edits have not touched Music.
        let plan = try await store.musicExport(playlistIDs: ["MUSIC_PLAYLIST"])
        let receipt = try await MusicExport.execute(plan, destination: destination) { try await store.saveMusicReceipt($0) }
        let copiedID = try #require(receipt.playlists["MUSIC_PLAYLIST"]?.remoteID)
        #expect(copiedID != "MUSIC_PLAYLIST")
        #expect(try await destination.playlistTracks(copiedID) == ["MUSIC1", "MUSIC1"])
        #expect(await destination.parents[copiedID] == receipt.folderID)
        #expect(await destination.songs.count == 1)
        #expect(await destination.songs[0].rating == 5)
        let again = try await store.musicExport(playlistIDs: ["MUSIC_PLAYLIST"])
        _ = try await MusicExport.execute(again, destination: destination) { try await store.saveMusicReceipt($0) }
        #expect(await destination.playlists.count == 2)
        #expect(await destination.songs.count == 1)
        // A later Music refresh must not re-import our destination copies as duplicate Deckhand playlists.
        var refreshed = f.music(url)
        refreshed.playlists += [SourcePlaylist(id: receipt.folderID!, name: "Deckhand", isFolder: true),
                               SourcePlaylist(id: copiedID, name: "Music Favorites", parentId: receipt.folderID, trackIds: ["MUSIC1", "MUSIC1"])]
        let updated = try await store.importLibrary(refreshed, from: SourceConnection(kind: .music))
        #expect(updated.library.playlists.count == 1)
        await store.close()
    }

    @Test func folderTracksAreAddedOnlyWhenExplicitlyExportingAndRetryUsesDurableReceipts() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav"); try f.writeM3U()
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let id = imported.library.playlists[0].id
        let destination = FakeMusicDestination()
        await destination.setFailure(true)
        let plan = try await store.musicExport(playlistIDs: [id])
        await #expect(throws: (any Error).self) {
            try await MusicExport.execute(plan, destination: destination) { try await store.saveMusicReceipt($0) }
        }
        #expect(await destination.songs.count == 1)
        #expect(await destination.playlists.count == 2)
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        await destination.setFailure(false)
        let retry = try await reopened.musicExport(playlistIDs: [id])
        let receipt = try await MusicExport.execute(retry, destination: destination) { try await reopened.saveMusicReceipt($0) }
        #expect(await destination.songs.count == 1)
        #expect(await destination.playlists.count == 2)
        #expect(receipt.playlists[id]?.baseline.count == 1)
        await reopened.close()
    }

    @Test func externallyEditedDestinationIsNotOverwritten() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        let destination = FakeMusicDestination()
        await destination.seed(track: SourceTrack(id: "MUSIC1", title: "Existing", location: url))
        let plan = try await store.musicExport(playlistIDs: ["MUSIC_PLAYLIST"])
        let receipt = try await MusicExport.execute(plan, destination: destination) { try await store.saveMusicReceipt($0) }
        let id = try #require(receipt.playlists["MUSIC_PLAYLIST"]?.remoteID)
        await destination.change(id, members: ["EXTERNAL"])
        let count = await destination.mutations
        _ = try await store.remove(trackIDs: ["MUSIC1"], from: "MUSIC_PLAYLIST")
        let updated = try await store.musicExport(playlistIDs: ["MUSIC_PLAYLIST"])
        await #expect(throws: (any Error).self) {
            try await MusicExport.execute(updated, destination: destination) { try await store.saveMusicReceipt($0) }
        }
        #expect(try await destination.playlistTracks(id) == ["EXTERNAL"])
        #expect(await destination.mutations == count)
        #expect(await store.snapshot().library.playlists[0].trackIds.isEmpty)
        await store.close()
    }

    @Test func missingAudioFailsBeforeMutatingDestination() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        try FileManager.default.removeItem(at: url)
        _ = await store.snapshot(checkAvailability: true)
        let destination = FakeMusicDestination()
        let plan = try await store.musicExport(playlistIDs: ["MUSIC_PLAYLIST"])
        await #expect(throws: (any Error).self) {
            try await MusicExport.execute(plan, destination: destination) { try await store.saveMusicReceipt($0) }
        }
        #expect(await destination.mutations == 0)
        await store.close()
    }

    @Test func exportAfterSwitchingSourcesIncludesTheSelectedOldAndNewPlaylists() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav"); try f.writeM3U()
        _ = try f.audio("Two.wav", in: f.b); try f.writeM3U("Second", paths: ["Two.wav"], folder: f.b)
        let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let both = try await store.refresh(SourceConnection(kind: .folder, location: f.b))
        _ = try await store.disconnectSource()
        let destination = FakeMusicDestination()
        let plan = try await store.musicExport(playlistIDs: both.library.playlists.map(\.id))
        _ = try await MusicExport.execute(plan, destination: destination) { try await store.saveMusicReceipt($0) }
        #expect(await destination.playlists.count == 3)
        #expect(await destination.songs.count == 2)
        await store.close()
    }
}
