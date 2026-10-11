import Analysis
import DeckhandCore
import Foundation
import MusicSource
import OneLibrary
import Testing
@testable import DeckhandLibrary
@testable import Sync

@Suite struct LibrarySyncTests {
    @Test func deletingPlaylistChangesUSBOnlyOnSyncAndRetainsSharedAudio() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        let created = try await store.createPlaylist(named: "Keep")
        let keep = try #require(created.library.playlists.last)
        let both = try await store.add(trackIDs: ["MUSIC1"], to: keep.id)
        let drive = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let volume = Volume(testRoot: drive)
        try Manifest().save(to: volume)
        let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        var profile = OutputProfile(settings: OutputSettings()); profile.analyzeMissing = false; profile.artwork = false
        let initialManifest = try #require(try Manifest.load(from: volume))
        let first = SyncPlanner(library: both.library, cache: cache).plan(volume: volume, manifest: initialManifest, profile: profile,
            selection: Selection(playlistIds: both.library.playlists.map(\.id)))
        _ = try SyncExecutor(cache: cache).execute(first, on: volume)
        let manifest = try #require(try Manifest.load(from: volume))
        let removed = try #require(imported.library.playlists.first)
        let deleted = try await store.deletePlaylist(removed.id)
        #expect(try Manifest.load(from: volume)?.playlists[removed.id] != nil)
        let planner = SyncPlanner(library: deleted.library, cache: cache)
        let changes = planner.plan(volume: volume, manifest: manifest, profile: profile)
        #expect(changes.isComplete && changes.removedTracks.isEmpty)
        #expect(changes.removedPlaylists.count == 1 && changes.removedPlaylists.first?.name == removed.name)
        _ = try SyncExecutor(cache: cache).execute(changes, on: volume)
        let final = try #require(try Manifest.load(from: volume))
        #expect(final.selectedPlaylistIds == [keep.id] && final.playlists[removed.id] == nil)
        #expect(final.tracks["MUSIC1"]?.usbPath == manifest.tracks["MUSIC1"]?.usbPath)
        #expect(try planner.verify(volume: volume, profile: profile).isClean)
        #expect(try OneLibraryValidator.validate(database: volume.url(forUsbPath: DriveProbe.databasePath), volumeRoot: drive).isEmpty)
        await store.close()
    }

    @Test func mixedLibrarySyncSurvivesSourceChangeDisconnectAndRestart() async throws {
        let f = try LibraryFixture()
        _ = try f.audio("One.wav"); _ = try f.audio("Two.wav", in: f.b)
        try f.writeM3U(); try f.writeM3U("Second", paths: ["Two.wav"], folder: f.b)
        let drive = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let volume = Volume(testRoot: drive)
        try Manifest().save(to: volume)
        let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        var profile = OutputProfile(settings: OutputSettings()); profile.analyzeMissing = false; profile.artwork = false
        let store = try DeckhandLibraryStore(directory: f.directory)
        let a = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let firstID = try #require(a.library.allTrackIds?.first)
        func sync(_ library: SourceLibrary, selection: Selection? = nil) throws -> Manifest {
            let planner = SyncPlanner(library: library, cache: cache)
            let changes = planner.plan(volume: volume, manifest: try Manifest.load(from: volume) ?? Manifest(), profile: profile, selection: selection)
            #expect(changes.isComplete)
            #expect(changes.removedTracks.isEmpty && changes.removedPlaylists.isEmpty)
            _ = try SyncExecutor(cache: cache).execute(changes, on: volume)
            #expect(try planner.verify(volume: volume, profile: profile).isClean)
            #expect(try OneLibraryValidator.validate(database: volume.url(forUsbPath: DriveProbe.databasePath), volumeRoot: drive).isEmpty)
            return try #require(try Manifest.load(from: volume))
        }
        let initial = try sync(a.library, selection: Selection(playlistIds: a.library.playlists.map(\.id), entireLibrary: true))
        let firstRecord = try #require(initial.tracks[firstID])
        let b = try await store.refresh(SourceConnection(kind: .folder, location: f.b))
        let second = try sync(b.library, selection: Selection(playlistIds: b.library.playlists.map(\.id), entireLibrary: true))
        #expect(second.sourceID == initial.sourceID && second.tracks.count == 2 && second.playlists.count == 2)
        #expect(second.tracks[firstID]?.contentId == firstRecord.contentId)
        #expect(second.tracks[firstID]?.usbPath == firstRecord.usbPath)
        _ = try await store.disconnectSource(); await store.close()
        try FileManager.default.moveItem(at: f.a, to: f.root.appendingPathComponent("Offline"))
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        let saved = await reopened.snapshot(checkAvailability: true)
        let offline = try sync(saved.library)
        #expect(offline.tracks.count == 2 && offline.selectedPlaylistIds == second.selectedPlaylistIds)
        #expect(FileManager.default.fileExists(atPath: volume.url(forUsbPath: firstRecord.usbPath).path))
        await reopened.close()
    }

    @Test func legacyAdoptionRequiresKnownSourceAndEveryExistingID() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        var legacy = Manifest(); legacy.lastSyncedAt = Date(); legacy.selectedPlaylistIds = ["MUSIC_PLAYLIST"]
        #expect(!legacy.acceptsSource(imported.library.sourceID))
        #expect(legacy.canAdoptLibrary(imported.library))
        legacy.selectedPlaylistIds.append("unimported-playlist")
        #expect(!legacy.canAdoptLibrary(imported.library))
        legacy.selectedPlaylistIds = ["MUSIC_PLAYLIST"]; legacy.sourceID = "someone-else"
        #expect(!legacy.canAdoptLibrary(imported.library))
        legacy.sourceID = "deckhand:old-library"
        #expect(!legacy.canAdoptLibrary(imported.library)) // Empty records aren't continuity proof.
        legacy.playlists["MUSIC_PLAYLIST"] = Manifest.Playlist(playlistId: 1, name: "Favorites", parentPlaylistId: nil, sequenceNo: 0, contentIds: [])
        #expect(legacy.canAdoptLibrary(imported.library))
        legacy.selectedPlaylistIds.append("missing-playlist")
        #expect(!legacy.canAdoptLibrary(imported.library))
        await store.close()
    }

    @Test func deselectingLastPlaylistCanSyncRemovalsAndKeepsLocalLibrary() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        let drive = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let volume = Volume(testRoot: drive); try Manifest().save(to: volume)
        let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        var profile = OutputProfile(settings: OutputSettings()); profile.analyzeMissing = false; profile.artwork = false
        let planner = SyncPlanner(library: imported.library, cache: cache)
        let initial = planner.plan(volume: volume, manifest: try #require(try Manifest.load(from: volume)), profile: profile,
            selection: Selection(playlistIds: ["MUSIC_PLAYLIST"]))
        _ = try SyncExecutor(cache: cache).execute(initial, on: volume)
        let unchecked = try Manifest.edit(on: volume) { $0.selectedPlaylistIds = [] }
        let changes = planner.plan(volume: volume, manifest: unchecked, profile: profile)
        #expect(changes.isComplete && changes.removedTracks.count == 1 && changes.removedPlaylists.count == 1)
        _ = try SyncExecutor(cache: cache).execute(changes, on: volume)
        #expect(try planner.verify(volume: volume, profile: profile).isClean)
        #expect(try Manifest.load(from: volume)?.tracks.isEmpty == true)
        #expect(await store.snapshot().library.tracks == imported.library.tracks)
        #expect(await store.snapshot().library.playlists == imported.library.playlists)
        #expect(try OneLibraryValidator.validate(database: volume.url(forUsbPath: DriveProbe.databasePath), volumeRoot: drive).isEmpty)
        await store.close()
    }
}
