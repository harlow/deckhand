import DeckhandCore
import Foundation
import MusicSource
import Testing
@testable import DeckhandLibrary

@Suite struct DeckhandLibraryTests {
    @Test func deletedImportedPlaylistStaysDeletedAcrossRestartAndReimportWithoutRemovingTracks() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        try f.writeXML(track: url)
        let source = SourceConnection(kind: .rekordbox, location: f.xml)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.refresh(source)
        let playlist = try #require(imported.library.playlists.first { !$0.isFolder })
        let rated = try await store.setRating(5, ids: playlist.trackIds)
        let deleted = try await store.deletePlaylist(playlist.id)
        #expect(deleted.library.playlists.allSatisfy { $0.id != playlist.id })
        #expect(deleted.library.tracks == rated.library.tracks)
        #expect(deleted.library.allTrackIds == rated.library.allTrackIds)
        #expect(deleted.library.playlists.contains { $0.id == playlist.parentId })
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        #expect(await reopened.snapshot().library.playlists == deleted.library.playlists)
        let reimported = try await reopened.refresh(source)
        #expect(reimported.library.playlists == deleted.library.playlists)
        #expect(reimported.library.tracks == rated.library.tracks)
        let export = f.root.appendingPathComponent("export.xml")
        try await reopened.rekordboxExport(for: source.id).write(to: export)
        let exported = try await RekordboxSource(connection: SourceConnection(kind: .rekordbox, location: export)).load(files: [:])
        #expect(exported.library.playlists.allSatisfy { $0.isFolder })
        await reopened.close()
    }

    @Test func failedPlaylistDeletionRollsBackRecordsAndReimportSuppression() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let source = SourceConnection(kind: .music)
        let before = try await store.importLibrary(f.music(url), from: source)
        try f.rawSQL("CREATE TRIGGER fail_delete BEFORE DELETE ON playlists BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        await #expect(throws: (any Error).self) { try await store.deletePlaylist("MUSIC_PLAYLIST") }
        #expect(await store.snapshot().revision == before.revision)
        #expect(await store.snapshot().library.playlists == before.library.playlists)
        try f.rawSQL("DROP TRIGGER fail_delete")
        let refreshed = try await store.importLibrary(f.music(url), from: source)
        #expect(refreshed.library.playlists == before.library.playlists)
        await #expect(throws: (any Error).self) { try await store.deletePlaylist("missing") }
        let folder = try await store.createPlaylist(named: "Folder", isFolder: true)
        await #expect(throws: (any Error).self) { try await store.deletePlaylist(folder.library.playlists.last!.id) }
        await store.close()
    }

    @Test func movedImportedPlaylistKeepsPlacementButStillUpdatesMembershipAcrossRestartAndXMLExport() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        try f.writeXML(track: url)
        let source = SourceConnection(kind: .rekordbox, location: f.xml)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.refresh(source)
        let playlist = try #require(imported.library.playlists.first { !$0.isFolder })
        let created = try await store.createPlaylist(named: "My Sets", isFolder: true)
        let folder = try #require(created.library.playlists.last)
        _ = try await store.movePlaylist(playlist.id, toFolder: folder.id)
        _ = try await store.setRating(5, ids: playlist.trackIds)
        try f.writeXML(track: url, members: [1])
        let updated = try await store.refresh(source)
        let moved = try #require(updated.library.playlists.first { $0.id == playlist.id })
        #expect(moved.parentId == folder.id && moved.trackIds == [playlist.trackIds[0]])
        #expect(updated.conflicts.isEmpty && updated.library.tracks[playlist.trackIds[0]]?.rating == 5)
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        #expect(await reopened.snapshot().library.playlists == updated.library.playlists)
        let destination = f.root.appendingPathComponent("organized.xml")
        try await reopened.rekordboxExport(for: source.id).write(to: destination)
        let exported = try await RekordboxSource(connection: SourceConnection(kind: .rekordbox, location: destination)).load(files: [:]).library
        let exportedFolder = try #require(exported.playlists.first { $0.name == "My Sets" })
        #expect(exported.playlists.first { $0.name == moved.name }?.parentId == exportedFolder.id)
        let root = try await reopened.movePlaylist(playlist.id, toFolder: nil)
        #expect(root.library.playlists.first { $0.id == playlist.id }?.parentId == nil)
        let refreshed = try await reopened.refresh(source)
        #expect(refreshed.library.playlists.first { $0.id == playlist.id }?.parentId == nil)
        await reopened.close()
    }

    @Test func folderMovesPreserveSubtreesAndRejectCyclesAndInvalidTargetsAtomically() async throws {
        let f = try LibraryFixture(); let store = try DeckhandLibraryStore(directory: f.directory)
        var snapshot = try await store.createPlaylist(named: "Parent", isFolder: true)
        let parent = try #require(snapshot.library.playlists.last)
        snapshot = try await store.createPlaylist(named: "Child", isFolder: true)
        let child = try #require(snapshot.library.playlists.last)
        snapshot = try await store.createPlaylist(named: "Set")
        let playlist = try #require(snapshot.library.playlists.last)
        _ = try await store.movePlaylist(playlist.id, toFolder: child.id)
        let before = try await store.movePlaylist(child.id, toFolder: parent.id)
        for (id, target) in [(parent.id, child.id), (parent.id, parent.id), (child.id, playlist.id), (playlist.id, "missing"), ("missing", parent.id)] {
            await #expect(throws: (any Error).self) { try await store.movePlaylist(id, toFolder: target) }
            #expect(await store.snapshot().library.playlists == before.library.playlists)
            #expect(await store.snapshot().revision == before.revision)
        }
        let moved = try await store.movePlaylist(child.id, toFolder: nil)
        #expect(moved.library.playlists.first { $0.id == child.id }?.parentId == nil)
        #expect(moved.library.playlists.first { $0.id == playlist.id }?.parentId == child.id)
        let noOp = try await store.movePlaylist(child.id, toFolder: nil)
        #expect(noOp.revision == moved.revision)
        await store.close()
    }

    @Test func orderedPlacementRejectsStaleAnchorsAndCyclesWithoutSaving() async throws {
        let f = try LibraryFixture(); let store = try DeckhandLibraryStore(directory: f.directory)
        let a = try await store.createPlaylist(named: "A").library.playlists.last!
        let b = try await store.createPlaylist(named: "B").library.playlists.last!
        let folder = try await store.createPlaylist(named: "Folder", isFolder: true).library.playlists.last!
        let child = try await store.createPlaylist(named: "Child", isFolder: true).library.playlists.last!
        _ = try await store.movePlaylist(child.id, toFolder: folder.id)
        let before = await store.snapshot()
        for (id, parent, anchor) in [(a.id, nil, child.id), (a.id, folder.id, b.id), (a.id, nil, a.id),
                                    (a.id, nil, "gone"), (folder.id, child.id, nil), (a.id, b.id, nil)] {
            await #expect(throws: (any Error).self) { try await store.positionPlaylist(id, toFolder: parent, before: anchor) }
            #expect(await store.snapshot().revision == before.revision)
            #expect(await store.snapshot().library.playlists == before.library.playlists)
        }
        let placed = try await store.positionPlaylist(b.id, toFolder: nil, before: a.id)
        #expect(placed.library.playlists.filter { $0.parentId == nil }.map(\.id) == [b.id, a.id, folder.id])
        let noOp = try await store.positionPlaylist(b.id, toFolder: nil, before: a.id)
        #expect(noOp.revision == placed.revision)
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        #expect(await reopened.snapshot().library.playlists == placed.library.playlists)
        await reopened.close()
    }

    @Test func removedImportRetainsXMLMappingsEditsAndAliasesAndReaddingDoesNotDuplicatePlaylists() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        try f.writeXML(track: url)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let music = SourceConnection(kind: .music), xml = SourceConnection(kind: .rekordbox, location: f.xml)
        let first = try await store.importLibrary(f.music(url), from: music)
        let imported = try await store.refresh(xml, makePrimary: false)
        #expect(imported.selectedSourceID == music.id)
        let playlist = try #require(imported.library.playlists.last { !$0.isFolder })
        _ = try await store.remove(trackIDs: ["MUSIC1"], from: playlist.id)
        _ = try await store.setRating(5, ids: ["MUSIC1"])
        let before = await store.snapshot()
        let removed = try await store.removeConnection(xml.id)
        #expect(removed.selectedSourceID == music.id)
        #expect(removed.connections.first { $0.id == xml.id }?.isConnected == false)
        #expect(removed.library.playlists == before.library.playlists && removed.library.tracks == before.library.tracks)
        #expect(removed.library.sourceAliases?.contains(xml.id) == true)
        _ = try await store.rekordboxExport(for: xml.id) // Cached provenance survives removing the connection.
        await store.close()
        let restarted = try DeckhandLibraryStore(directory: f.directory)
        #expect(await restarted.snapshot().connections.first { $0.id == xml.id }?.isConnected == false)
        let restored = try await restarted.refresh(xml, makePrimary: false)
        #expect(restored.selectedSourceID == music.id && restored.library.sourceID == first.library.sourceID)
        #expect(restored.library.playlists == before.library.playlists && restored.library.tracks["MUSIC1"]?.rating == 5)
        #expect(restored.connections.first { $0.id == xml.id }?.isConnected == true)
        await restarted.close()
    }

    @Test func failedConnectionRemovalRollsBackDefaultAndRecords() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let music = SourceConnection(kind: .music)
        let before = try await store.importLibrary(f.music(url), from: music)
        try f.rawSQL("CREATE TRIGGER fail_remove BEFORE UPDATE ON sources BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        await #expect(throws: (any Error).self) { try await store.removeConnection(music.id) }
        let after = await store.snapshot()
        #expect(after.selectedSourceID == music.id && after.connections == before.connections)
        #expect(after.library.playlists == before.library.playlists)
        try f.rawSQL("DROP TRIGGER fail_remove")
        let removed = try await store.removeConnection(music.id)
        #expect(removed.selectedSourceID == nil && removed.connections[0].isConnected == false)
        await #expect(throws: (any Error).self) { try await store.selectSource(music.id) }
        await store.close()
    }

    @Test func folderRenameKeepsIdentityRatingAndLocallySavedMembership() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let source = SourceConnection(kind: .folder, location: f.a)
        let first = try await store.refresh(source)
        let id = try #require(first.library.allTrackIds?.first)
        let created = try await store.createPlaylist(named: "Saved Set")
        let playlist = try #require(created.library.playlists.first)
        _ = try await store.add(trackIDs: [id], to: playlist.id)
        _ = try await store.setRating(4, ids: [id])
        let renamed = f.a.appendingPathComponent("Renamed.wav")
        try FileManager.default.moveItem(at: url, to: renamed)
        let fresh = try await store.refresh(source)
        #expect(fresh.library.allTrackIds == [id])
        #expect(fresh.library.tracks[id]?.location?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        #expect(fresh.library.tracks[id]?.rating == 4)
        #expect(fresh.library.playlists.first?.trackIds == [id])
        await store.close()
    }

    @Test func failedInitialImportRollsBackInitializationConnectionsAndRecords() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        try f.rawSQL("CREATE TRIGGER fail_import BEFORE INSERT ON playlists BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        await #expect(throws: (any Error).self) { try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music)) }
        let snapshot = await store.snapshot()
        #expect(!snapshot.initialized && snapshot.connections.isEmpty && snapshot.library.tracks.isEmpty)
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory) == nil)
        try f.rawSQL("DROP TRIGGER fail_import")
        _ = try await store.importLibrary(f.music(url), from: SourceConnection(kind: .music))
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory)?.tracks.count == 1)
        await store.close()
    }

    @Test func incompleteAllTracksOrderStillImportsEveryReferencedTrack() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        var library = f.music(url); library.allTrackIds = []
        let imported = try await store.importLibrary(library, from: SourceConnection(kind: .music))
        #expect(imported.library.allTrackIds == ["MUSIC1"])
        #expect(imported.library.playlists.first?.trackIds == ["MUSIC1"])
        library.allTrackIds = ["MUSIC1", "MUSIC1"]
        await #expect(throws: (any Error).self) { try await store.importLibrary(library, from: SourceConnection(kind: .music)) }
        #expect(await store.snapshot().library.playlists == imported.library.playlists)
        await store.close()
    }

    @Test func sourceChangesPreserveAllPlaylistsRatingsAndIdentityAcrossRestart() async throws {
        let f = try LibraryFixture()
        _ = try f.audio("One.wav")
        _ = try f.audio("Two.wav", in: f.b)
        try f.writeM3U()
        try f.writeM3U("Second", paths: ["Two.wav"], folder: f.b)
        let a = SourceConnection(kind: .folder, location: f.a)
        let b = SourceConnection(kind: .folder, location: f.b)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let first = try await store.refresh(a)
        let id = try #require(first.library.allTrackIds?.first)
        let created = try await store.createPlaylist(named: "My Set")
        let local = try #require(created.library.playlists.last)
        _ = try await store.add(trackIDs: [id], to: local.id)
        _ = try await store.setRating(5, ids: [id])
        let both = try await store.refresh(b)
        #expect(both.library.sourceID == first.library.sourceID)
        #expect(both.library.tracks.count == 2 && both.library.playlists.count == 3)
        #expect(both.library.tracks[id]?.rating == 5)
        #expect(both.library.playlists.first { $0.id == local.id }?.trackIds == [id])
        _ = try await store.disconnectSource()
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        let saved = await reopened.snapshot()
        #expect(saved.selectedSourceID == nil)
        #expect(saved.library.sourceID == first.library.sourceID)
        #expect(saved.library.playlists == both.library.playlists)
        #expect(saved.library.tracks[id]?.rating == 5)
        let back = try await reopened.refresh(a)
        #expect(back.library.tracks.count == 2 && back.library.playlists.count == 3)
        await reopened.close()
    }

    @Test func unavailableAndInvalidSourcesDoNotClearTheLibrary() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav"); try f.writeM3U()
        let store = try DeckhandLibraryStore(directory: f.directory)
        let source = SourceConnection(kind: .folder, location: f.a)
        let before = try await store.refresh(source)
        try FileManager.default.moveItem(at: f.a, to: f.root.appendingPathComponent("Offline"))
        await #expect(throws: (any Error).self) { try await store.refresh(source) }
        let offline = await store.snapshot(checkAvailability: true)
        #expect(offline.library.playlists == before.library.playlists)
        #expect(offline.library.tracks.count == before.library.tracks.count)
        #expect(offline.library.tracks.values.allSatisfy { $0.unavailableReason != nil })
        #expect(offline.connections[0].error != nil)
        try "<bad/>".write(to: f.xml, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await store.refresh(SourceConnection(kind: .rekordbox, location: f.xml)) }
        #expect(await store.snapshot().library.playlists == before.library.playlists)
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("Offline"), to: f.a)
        let recovered = try await store.refresh(source)
        #expect(recovered.library.tracks.values.allSatisfy { $0.unavailableReason == nil })
        #expect(recovered.connections[0].error == nil)
        await store.close()
    }

    @Test func musicEditsAlwaysSaveLocallyAndRefreshKeepsThem() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let connection = SourceConnection(kind: .music)
        _ = try await store.importLibrary(f.music(url), from: connection)
        _ = try await store.remove(trackIDs: ["MUSIC1"], from: "MUSIC_PLAYLIST")
        _ = try await store.setRating(0, ids: ["MUSIC1"])
        let fresh = try await store.importLibrary(f.music(url, members: ["MUSIC1", "MUSIC1"]), from: connection)
        #expect(fresh.library.playlists[0].trackIds.isEmpty)
        #expect(fresh.library.tracks["MUSIC1"]?.rating == nil)
        #expect(fresh.conflicts == ["MUSIC_PLAYLIST"])
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        let saved = await reopened.snapshot()
        #expect(saved.library.playlists[0].trackIds.isEmpty)
        #expect(saved.library.tracks["MUSIC1"]?.rating == nil)
        await reopened.close()
    }

    @Test func untouchedImportsUpdateButExternalDeletionsKeepPlaylistsAndAvailableAudio() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let connection = SourceConnection(kind: .music)
        _ = try await store.importLibrary(f.music(url), from: connection)
        let updated = try await store.importLibrary(f.music(url, members: ["MUSIC1", "MUSIC1"]), from: connection)
        #expect(updated.library.playlists[0].trackIds == ["MUSIC1", "MUSIC1"])
        var empty = SourceLibrary(playlists: [], tracks: [:]); empty.allTrackIds = []
        let retained = try await store.importLibrary(empty, from: connection)
        #expect(retained.library.playlists == updated.library.playlists)
        #expect(retained.library.tracks["MUSIC1"]?.location == url)
        #expect(retained.library.tracks["MUSIC1"]?.unavailableReason == nil)
        await store.close()
    }

    @Test func folderAndRekordboxSameFileDeduplicateAndExportPreservesOriginalCueNodes() async throws {
        let f = try LibraryFixture(); let url = try f.audio("One.wav"); try f.writeXML(track: url)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let first = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let id = try #require(first.library.allTrackIds?.first)
        let rb = SourceConnection(kind: .rekordbox, location: f.xml)
        let imported = try await store.refresh(rb)
        #expect(imported.library.tracks.count == 1)
        #expect(imported.library.playlists[1].trackIds == [id, id])
        _ = try await store.setRating(5, ids: [id])
        let export = try await store.rekordboxExport(for: rb.id)
        // Export uses the stored XML, even after switching sources and disconnecting its file.
        try FileManager.default.moveItem(at: f.xml, to: f.root.appendingPathComponent("Hidden.xml"))
        let output = f.root.appendingPathComponent("Deckhand.xml")
        try export.write(to: output)
        let xml = try String(contentsOf: output, encoding: .utf8)
        #expect(xml.contains("POSITION_MARK") && xml.contains("TEMPO"))
        let roundTrip = try await RekordboxSource(connection: SourceConnection(kind: .rekordbox, location: output)).load(files: [:]).library
        #expect(roundTrip.playlists[1].trackIds.count == 2)
        #expect(roundTrip.tracks.values.first?.rating == 5)
        #expect(roundTrip.tracks.values.first?.title == "One")
        await store.close()
    }

    @Test func sameNumericIDsInDifferentConnectionsDoNotCollide() async throws {
        let f = try LibraryFixture(); let one = try f.audio("One.wav"); let two = try f.audio("Two.wav", in: f.b)
        let store = try DeckhandLibraryStore(directory: f.directory)
        let a = SourceConnection(kind: .rekordbox, location: f.xml)
        let b = SourceConnection(kind: .rekordbox, location: f.root.appendingPathComponent("Second.xml"))
        func lib(_ connection: SourceConnection, _ url: URL) -> SourceLibrary {
            let id = connection.trackID("1")
            var lib = SourceLibrary(playlists: [SourcePlaylist(id: connection.playlistID("same"), name: "Same", trackIds: [id])], tracks: [id: SourceTrack(id: id, title: "Same", location: url)])
            lib.allTrackIds = [id]; return lib
        }
        _ = try await store.importLibrary(lib(a, one), from: a)
        let both = try await store.importLibrary(lib(b, two), from: b)
        #expect(both.library.tracks.count == 2 && both.library.playlists.count == 2)
        #expect(both.library.playlists[0].trackIds != both.library.playlists[1].trackIds)
        await store.close()
    }

    @Test func concurrentEditsKeepBothMembershipChangesAndLatestRating() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav"); _ = try f.audio("Two.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let ids = try #require(imported.library.allTrackIds)
        let created = try await store.createPlaylist(named: "Concurrent")
        let p = try #require(created.library.playlists.first)
        async let a = store.add(trackIDs: [ids[0]], to: p.id)
        async let b = store.add(trackIDs: [ids[1]], to: p.id)
        _ = try await (a, b)
        _ = try await store.setRating(1, ids: ids)
        _ = try await store.setRating(4, ids: ids)
        let saved = await store.snapshot()
        #expect(Set(saved.library.playlists[0].trackIds) == Set(ids))
        #expect(saved.library.tracks.values.allSatisfy { $0.rating == 4 })
        await store.close()
    }

    @Test func invalidImportedReferencesAreRejectedWithoutSavingAnything() async throws {
        let f = try LibraryFixture(); let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.startEmpty()
        let bad = SourceLibrary(playlists: [SourcePlaylist(id: "bad", name: "Bad", trackIds: ["missing"])], tracks: [:])
        await #expect(throws: (any Error).self) { try await store.importLibrary(bad, from: SourceConnection(kind: .music)) }
        #expect(await store.snapshot().library.playlists.isEmpty)
        #expect(await store.snapshot().connections.isEmpty)
        await store.close()
    }

    @Test func failedSaveRollsBackDiskAndMemoryTogether() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let before = try await store.refresh(SourceConnection(kind: .folder, location: f.a))
        let id = try #require(before.library.allTrackIds?.first)
        try f.rawSQL("CREATE TRIGGER fail_save BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT, 'fixture save failure'); END;")
        await #expect(throws: (any Error).self) { try await store.setRating(5, ids: [id]) }
        #expect(await store.snapshot().library.tracks[id]?.rating == before.library.tracks[id]?.rating)
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory)?.tracks[id]?.rating == before.library.tracks[id]?.rating)
        try f.rawSQL("DROP TRIGGER fail_save")
        _ = try await store.setRating(5, ids: [id])
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        #expect(await reopened.snapshot().library.tracks[id]?.rating == 5)
        await reopened.close()
    }

    @Test func secondWriterIsRejectedAndReadersSeeCommittedEdits() async throws {
        let f = try LibraryFixture(); let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.startEmpty()
        #expect(throws: DeckhandLibraryError.self) { try DeckhandLibraryStore(directory: f.directory) }
        _ = try await store.createPlaylist(named: "Committed")
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory)?.playlists[0].name == "Committed")
        await store.close()
        let second = try DeckhandLibraryStore(directory: f.directory)
        #expect(await second.snapshot().library.playlists[0].name == "Committed")
        await second.close()
    }

    @Test func corruptAndFutureDatabasesFailWithoutBeingReplaced() async throws {
        let f = try LibraryFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let path = DeckhandLibraryStore.databaseURL(in: f.directory)
        let bytes = Data("not a database".utf8); try bytes.write(to: path)
        #expect(throws: (any Error).self) { try DeckhandLibraryStore(directory: f.directory) }
        #expect(try Data(contentsOf: path) == bytes)
        try FileManager.default.removeItem(at: path)
        let store = try DeckhandLibraryStore(directory: f.directory)
        _ = try await store.startEmpty(); await store.close()
        try f.rawSQL("PRAGMA user_version=999")
        #expect(throws: (any Error).self) { try DeckhandLibraryStore(directory: f.directory) }
        #expect(throws: (any Error).self) { try DeckhandLibraryStore.savedLibrary(in: f.directory) }
    }

    @Test func legacyLocalPlaylistsAndClearedRatingsMigrateOnceWithoutReconnecting() async throws {
        let f = try LibraryFixture(); _ = try f.audio("One.wav"); try f.writeM3U()
        let source = SourceConnection(kind: .folder, location: f.a)
        let old = try LocalLibraryStore(connection: source, directory: f.legacy)
        let original = try await old.load()
        let id = try #require(original.allTrackIds?.first)
        _ = try await old.remove(trackIDs: [id], from: original.playlists[0].id)
        _ = try await old.setRating(0, ids: [id])
        let created = try await old.createPlaylist(named: "Legacy set")
        _ = try await old.add(trackIDs: [id], to: created.playlists.last!.id)
        try FileManager.default.moveItem(at: f.a, to: f.root.appendingPathComponent("Offline"))
        let store = try DeckhandLibraryStore(directory: f.directory)
        try await store.migrateLegacy([source], directory: f.legacy)
        let migrated = await store.snapshot()
        #expect(migrated.library.playlists.map(\.name) == ["Friday", "Legacy set"])
        #expect(migrated.library.playlists[0].trackIds == [])
        #expect(migrated.library.playlists[1].trackIds == [id])
        let before = migrated.library.playlists
        try await store.migrateLegacy([source], directory: f.legacy)
        #expect(await store.snapshot().library.playlists == before)
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("Offline"), to: f.a)
        let refreshed = try await store.refresh(source)
        #expect(refreshed.library.playlists[0].trackIds == [])
        #expect(refreshed.library.tracks[id]?.rating == nil)
        await store.close()
    }

    @Test func ratingEditsDoNotRewriteLargeSourceIndexes() async throws {
        let f = try LibraryFixture(); let store = try DeckhandLibraryStore(directory: f.directory)
        let connection = SourceConnection(kind: .music)
        let tracks = (0..<10_000).map { SourceTrack(id: "T\($0)", title: "Track \($0)", location: f.a.appendingPathComponent("\($0).wav")) }
        var library = SourceLibrary(playlists: [], tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }))
        library.allTrackIds = tracks.map(\.id)
        _ = try await store.importLibrary(library, from: connection)
        try f.rawSQL("CREATE TABLE audit(n INTEGER); INSERT INTO audit VALUES(0); CREATE TRIGGER audit_source AFTER UPDATE ON sources BEGIN UPDATE audit SET n=n+1; END;")
        for stars in 0...5 { _ = try await store.setRating(stars, ids: ["T9999"]) }
        await store.close()
        let db = try LibraryDatabase(url: DeckhandLibraryStore.databaseURL(in: f.directory), readOnly: true)
        #expect(try db.scalar("SELECT n FROM audit") == "0")
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory)?.tracks["T9999"]?.rating == 5)
    }
}
