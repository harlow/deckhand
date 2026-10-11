import AVFoundation
import DeckhandCore
import DeckhandLibrary
import MusicSource
import Testing
@testable import DeckhandApp
@testable import Sync

@Suite @MainActor struct DedicatedLibraryModelTests {
    @Test func repairingProtectedAudioUpdatesTheWorkspaceAndSurvivesRestartAndReimport() async throws {
        let f = try Fixture()
        var music = SourceLibrary(playlists: [SourcePlaylist(id: "SET", name: "Imported Set", trackIds: ["DRM", "DRM"])],
                                  tracks: ["DRM": SourceTrack(id: "DRM", title: "Protected Song", rating: 4,
                                      unavailableReason: "Protected (DRM) track; no exportable local file")])
        music.allTrackIds = ["DRM"]
        let model = f.model(music: music)
        await model.load(); await model.connect(SourceConnection(kind: .music))
        let issue = try #require(model.unavailableAudioIssues.first)
        let playlists = model.playlists
        #expect(model.allIds.isEmpty && issue.kind == .protected)
        let file = f.a.appendingPathComponent("Song.wav")
        try await model.locateAudioFile(for: issue.id, at: file)
        #expect(model.unavailableAudioIssues.isEmpty && model.allIds == [issue.id])
        #expect(model.rows[issue.id]?.location == file && model.rows[issue.id]?.rating == 4)
        #expect(model.rows[issue.id]?.duration == 0.1 && model.playlists == playlists)
        #expect(!model.job.running && !model.showingUSBChanges && !model.showingUSBConnection)
        await model.closeLibrary()
        let reopened = f.model(music: music); await reopened.load()
        #expect(reopened.unavailableAudioIssues.isEmpty && reopened.allIds == [issue.id])
        let connection = try #require(reopened.importConnections.first).connection
        await reopened.reimport(connection)
        #expect(reopened.unavailableAudioIssues.isEmpty && reopened.rows[issue.id]?.location == file)
        #expect(reopened.playlists == playlists && reopened.rows[issue.id]?.rating == 4)
        await reopened.closeLibrary()
    }

    @Test func earlierLibraryFolderCheckboxStagesAllDescendantsWithoutOpeningSyncOrWritingUSB() async throws {
        let f = try Fixture(); let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        await model.createPlaylist(named: "Weekend", isFolder: true)
        let folder = try #require(model.playlists.last)
        await model.createPlaylist(named: "Saturday")
        let first = try #require(model.playlists.last)
        await model.movePlaylist(first.id, toFolder: folder.id)
        await model.createPlaylist(named: "Late", isFolder: true)
        let nested = try #require(model.playlists.last)
        await model.movePlaylist(nested.id, toFolder: folder.id)
        await model.createPlaylist(named: "Afterhours")
        let second = try #require(model.playlists.last)
        await model.movePlaylist(second.id, toFolder: nested.id)
        await model.createPlaylist(named: "Outside")
        let outside = try #require(model.playlists.last)
        let library = try #require(try DeckhandLibraryStore.savedLibrary(in: f.database))
        let manifest = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = library.sourceID; $0.selectedPlaylistIds = [outside.id]
        }
        let changes = SyncPlanner(library: library, cache: cache).plan(volume: volume, manifest: manifest,
            profile: OutputProfile(settings: OutputSettings(saved: manifest.settings)))
        try SyncExecutor(cache: cache).execute(changes, on: volume)
        await model.closeLibrary()
        let original = try Manifest.edit(on: volume) { $0.sourceID = "deckhand:earlier-library" }
        let before = try usbFiles(usb)

        let reopened = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await reopened.load(); reopened.refreshDrives()
        for _ in 0..<300 where reopened.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        reopened.setOnDrive(true, folder)
        #expect(reopened.isOnDrive(first) && reopened.isOnDrive(second) && reopened.isOnDrive(folder))
        #expect(reopened.isOnDrive(nested) && reopened.isOnDrive(outside))
        #expect(!reopened.showingUSBChanges && !reopened.showingUSBConnection && !reopened.job.running)
        #expect(reopened.activeDrive?.manifest?.sourceID == original.sourceID)
        #expect(try usbFiles(usb) == before)
        for _ in 0..<300 where reopened.pendingChanges == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.pendingChanges > 0 && reopened.usbToolbarNeedsAction)
        #expect(reopened.usbToolbarStatusText == "\(reopened.pendingChanges) changes to sync")
        #expect(reopened.usbPrimaryActionTitle == "Sync")
        reopened.setOnDrive(false, first)
        #expect(!reopened.isOnDrive(folder) && reopened.hasAnyPlaylistOnDrive(folder))
        #expect(!reopened.isOnDrive(first) && reopened.isOnDrive(second))
        reopened.setOnDrive(false, folder)
        #expect(!reopened.isOnDrive(first) && !reopened.isOnDrive(second) && reopened.isOnDrive(outside))
        reopened.setOnDrive(true, folder)
        reopened.setEntireLibraryOnDrive(true)
        #expect(reopened.entireLibraryOnDrive && !reopened.showingUSBChanges && !reopened.job.running)
        reopened.setEntireLibraryOnDrive(false)
        await reopened.refreshDrive(usb.path)
        #expect(reopened.isOnDrive(folder) && reopened.isOnDrive(first) && reopened.isOnDrive(second))
        #expect(try usbFiles(usb) == before)
        await reopened.closeLibrary()

        let otherUSB = f.root.appendingPathComponent("Other USB")
        try FileManager.default.createDirectory(at: otherUSB, withIntermediateDirectories: true)
        let otherVolume = Volume(testRoot: otherUSB)
        _ = try Manifest.update(on: otherVolume, basedOn: nil) {
            $0.sourceID = original.sourceID; $0.selectedPlaylistIds = original.selectedPlaylistIds
            $0.playlists = original.playlists
        }
        let again = f.model(cache: cache, driveReader: { [Drive.read(volume), Drive.read(otherVolume)] })
        await again.load(); again.refreshDrives()
        for _ in 0..<300 where again.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(again.isOnDrive(folder) && again.isOnDrive(outside) && !again.entireLibraryOnDrive)
        #expect(!again.showingUSBChanges && !again.showingUSBConnection && !again.job.running)
        #expect(try usbFiles(usb) == before)
        again.activeDriveId = otherVolume.url.path
        #expect(!again.isOnDrive(folder) && again.isOnDrive(outside)) // Drafts belong to one physical USB.
        again.activeDriveId = volume.url.path
        #expect(again.isOnDrive(folder))
        // Only the explicit toolbar action opens the link/sync confirmation.
        again.requestSync()
        #expect(again.showingUSBChanges && !again.job.running)
        await again.adoptDrive(try #require(again.activeDrive))
        let linked = try #require(try Manifest.load(from: volume))
        #expect(linked.sourceID == again.libraryID)
        #expect(Set(linked.selectedPlaylistIds) == [outside.id, first.id, second.id])
        #expect(linked.tracks == original.tracks && linked.playlists == original.playlists)
        await again.closeLibrary()
        let linkedModel = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await linkedModel.load(); linkedModel.refreshDrives()
        for _ in 0..<300 where linkedModel.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(linkedModel.driveMatchesSource(try #require(linkedModel.activeDrive)) && linkedModel.isOnDrive(folder))
        await linkedModel.closeLibrary()
    }

    @Test func cleanUSBStaysCleanAcrossLaunchAndConfirmationIsDistinctFromPendingChanges() async throws {
        let f = try Fixture(); let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        await model.createPlaylist(named: "USB Set")
        let playlist = try #require(model.playlists.last)
        let library = try #require(try DeckhandLibraryStore.savedLibrary(in: f.database))
        let manifest = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = library.sourceID; $0.selectedPlaylistIds = [playlist.id]
        }
        let changes = SyncPlanner(library: library, cache: cache).plan(volume: volume, manifest: manifest,
            profile: OutputProfile(settings: OutputSettings(saved: manifest.settings)))
        try SyncExecutor(cache: cache).execute(changes, on: volume)
        let cleanFiles = try usbFiles(usb)
        model.refreshDrives()
        for _ in 0..<300 where model.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.usbIsUpToDate && !model.usbSyncEnabled && model.usbToolbarStatusText == nil)
        #expect(model.usbPrimaryActionTitle == "Sync")
        await model.closeLibrary()

        let reopened = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await reopened.load(); reopened.refreshDrives()
        for _ in 0..<300 where reopened.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.usbIsUpToDate && !reopened.usbSyncEnabled && reopened.pendingChanges == 0)
        #expect(reopened.usbToolbarStatusText == nil && !reopened.usbToolbarNeedsAction)
        #expect(try usbFiles(usb) == cleanFiles) // Startup checks never create sync work or write the USB.

        _ = try Manifest.edit(on: volume) { $0.sourceID = "deckhand:earlier-library" }
        let earlierFiles = try usbFiles(usb)
        await reopened.refreshDrive(usb.path)
        for _ in 0..<300 where reopened.driveStatus?.generation != reopened.activeDrive?.manifest?.generationNumber {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reopened.pendingChanges == 0 && !reopened.usbIsUpToDate)
        #expect(reopened.usbSyncEnabled && reopened.usbToolbarStatusText == "Link library" && reopened.usbToolbarNeedsAction)
        #expect(reopened.usbPrimaryActionTitle == "Setup")
        reopened.requestSync()
        #expect(reopened.showingUSBChanges && !reopened.job.running)
        #expect(try usbFiles(usb) == earlierFiles)
        await reopened.adoptDrive(try #require(reopened.activeDrive))
        for _ in 0..<300 where !reopened.usbIsUpToDate { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.usbIsUpToDate && !reopened.usbSyncEnabled && reopened.usbToolbarStatusText == nil)
        #expect(reopened.usbPrimaryActionTitle == "Sync")

        await reopened.createPlaylist(named: "Second USB Set")
        reopened.setOnDrive(true, try #require(reopened.playlists.last))
        for _ in 0..<300 where reopened.pendingChanges != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.usbToolbarStatusText == "1 change to sync")
        await reopened.createPlaylist(named: "Third USB Set")
        reopened.setOnDrive(true, try #require(reopened.playlists.last))
        for _ in 0..<300 where reopened.pendingChanges != 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.usbSyncEnabled && reopened.usbToolbarNeedsAction)
        #expect(reopened.usbToolbarStatusText == "2 changes to sync")
        #expect(reopened.driveStatus?.details.contains { $0.contains("Second USB Set") && $0.contains("create") } == true)
        let pendingFiles = try usbFiles(usb)
        await reopened.closeLibrary()
        let again = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await again.load(); again.refreshDrives()
        for _ in 0..<300 where again.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(again.pendingChanges == 2 && again.usbToolbarStatusText == "2 changes to sync")
        #expect(try usbFiles(usb) == pendingFiles)
        await again.closeLibrary()
    }

    @Test func previousDeckhandUSBPreviewsWithoutWritingAndExplicitAssociationKeepsSelection() async throws {
        let f = try Fixture(); let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        let p = try #require(model.playlists.first), trackID = try #require(model.allIds.first)
        let row = try #require(model.rows[trackID]); let hash = try cache.contentHash(of: row.location)
        let original = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = "deckhand:previous-library"; $0.selectedPlaylistIds = [p.id]; $0.entireLibrary = false
            $0.tracks[trackID] = Manifest.Track(contentId: 1, usbPath: "PIONEER/Deckhand/Song.wav", contentHash: hash,
                analysisVersion: 0, anlzFingerprint: nil, metadataFingerprint: nil)
            $0.playlists[p.id] = Manifest.Playlist(playlistId: 1, name: p.name, parentPlaylistId: nil, sequenceNo: 0, contentIds: [1])
        }
        let before = try usbFiles(usb)
        model.refreshDrives()
        for _ in 0..<300 where model.driveStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        let drive = try #require(model.activeDrive)
        #expect(!model.driveMatchesSource(drive) && model.canPreviewDrive(drive) && model.canAdoptDrive(drive))
        #expect(model.isOnDrive(p) && model.selectedUSBPlaylists == [p])
        #expect(model.driveStatus != nil && model.pendingChanges > 0)
        #expect(model.usbPrimaryActionTitle == "Sync")
        model.requestSync()
        #expect(model.showingUSBChanges && !model.showingUSBConnection && !model.job.running)
        #expect(try usbFiles(usb) == before) // Opening a preview never even edits the manifest.
        await model.adoptDrive(drive)
        let linked = try #require(try Manifest.load(from: volume))
        #expect(linked.sourceID == model.libraryID && linked.generationNumber == original.generationNumber + 1)
        #expect(linked.tracks == original.tracks && linked.playlists == original.playlists)
        #expect(linked.selectedPlaylistIds == original.selectedPlaylistIds && linked.entireLibrary == original.entireLibrary)
        #expect(!FileManager.default.fileExists(atPath: usb.appendingPathComponent("PIONEER").path))
        #expect(model.driveMatchesSource(try #require(model.activeDrive)))
        model.setOnDrive(false, p)
        for _ in 0..<300 where try Manifest.load(from: volume)?.selectedPlaylistIds.isEmpty != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.activeDrive?.canSync == true) // Unchecking the last playlist must still allow a removal sync.
        model.showingUSBChanges = false
        model.requestSync()
        #expect(model.wouldClearUSB && model.showingUSBChanges && !model.job.running)
        await model.closeLibrary()
    }

    @Test func associationRejectsChangedAudioConcurrentManifestAndBusyDrive() async throws {
        let f = try Fixture(); let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(cache: cache, driveReader: { [Drive.read(volume)] })
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        let p = try #require(model.playlists.first), id = try #require(model.allIds.first)
        let hash = try cache.contentHash(of: try #require(model.rows[id]).location)
        _ = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = "deckhand:previous"; $0.selectedPlaylistIds = [p.id]
            $0.tracks[id] = Manifest.Track(contentId: 1, usbPath: "PIONEER/Deckhand/Song.wav", contentHash: "different-audio",
                analysisVersion: 0, anlzFingerprint: nil, metadataFingerprint: nil)
        }
        model.refreshDrives()
        for _ in 0..<300 where model.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        var before = try usbFiles(usb)
        model.showingUSBChanges = true
        await model.syncWithCurrentLibrary(try #require(model.activeDrive))
        #expect(model.usbAssociationError?.contains("doesn't match") == true)
        #expect(model.showingUSBChanges && !model.job.running)
        #expect(try usbFiles(usb) == before)
        _ = try Manifest.edit(on: volume) { $0.tracks[id]?.contentHash = hash }
        await model.refreshDrive(usb.path)
        let stale = try #require(model.activeDrive)
        _ = try Manifest.edit(on: volume) { $0.entireLibrary = true }
        before = try usbFiles(usb)
        await model.adoptDrive(stale)
        #expect(model.usbAssociationError?.contains("changed") == true)
        #expect(try usbFiles(usb) == before)
        let lock = try SyncLock.acquire(on: volume)
        before = try usbFiles(usb)
        await model.adoptDrive(try #require(model.activeDrive))
        #expect(try usbFiles(usb) == before)
        #expect(model.usbAssociationError?.contains("being synced") == true)
        #expect(try Manifest.load(from: volume)?.sourceID == "deckhand:previous")
        lock.release()
        await model.deletePlaylist(p.id)
        #expect(!model.canPreviewDrive(try #require(model.activeDrive)))
        #expect(model.driveStatus == nil && model.selectedUSBPlaylists.isEmpty)
        await model.closeLibrary()
    }

    private func usbFiles(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[file.path] = try Data(contentsOf: file)
            }
        }
        return files
    }

    @Test func deletePlaylistClearsSelectedAndRecentPlaylistButKeepsTracksAcrossRestart() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let source = SourceConnection(kind: .folder, location: f.a)
        await model.connect(source)
        let imported = try #require(model.playlists.first)
        let ids = model.allIds
        await model.createPlaylist(named: "Disposable")
        let local = try #require(model.playlists.last)
        await model.add(ids, to: local)
        #expect(model.lastPlaylistId == local.id && model.selection == .playlist(local.id))
        await model.deletePlaylist(imported.id)
        #expect(model.selection == .playlist(local.id))
        await model.deletePlaylist(local.id)
        #expect(model.selection == .all && model.lastPlaylistId == nil)
        #expect(model.allIds == ids && model.playlists.isEmpty)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.selection == .all && reopened.playlists.isEmpty && reopened.allIds == ids)
        await reopened.reimport(source)
        #expect(reopened.playlists.isEmpty && reopened.allIds == ids)
        await reopened.closeLibrary()
    }

    @Test func newAndMismatchedUSBsOfferSetupWithoutWritingOrChangingTheLibrary() async throws {
        let f = try Fixture()
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(driveReader: { [Drive.read(volume)] })
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        model.refreshDrives()
        for _ in 0..<200 where model.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.activeDrive?.manifest == nil)
        #expect(model.usbPrimaryActionTitle == "Setup")
        let libraryID = model.libraryID, playlists = model.playlists, tracks = model.allIds
        model.requestSync()
        #expect(model.showingUSBConnection && !model.job.running)
        #expect(try Manifest.load(from: volume) == nil)
        model.showingUSBConnection = false
        let original = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = "unrelated-library"; $0.selectedPlaylistIds = ["missing-playlist"]
        }
        model.refreshDrives()
        for _ in 0..<200 where model.activeDrive?.manifest == nil { try await Task.sleep(for: .milliseconds(5)) }
        let drive = try #require(model.activeDrive)
        #expect(!model.canAdoptDrive(drive) && !model.driveMatchesSource(drive))
        #expect(model.usbToolbarStatusText == "Different library")
        #expect(model.usbPrimaryActionTitle == "Setup")
        #expect(model.usbLibraryMissingItems(for: drive) == "1 playlist from this USB isn't in this Deckhand library.")
        model.requestSync()
        await model.adoptDrive(drive) // Safety gate also applies to direct callers.
        #expect(model.showingUSBConnection && !model.job.running)
        #expect(try Manifest.load(from: volume)?.sourceID == original.sourceID)
        #expect(model.libraryID == libraryID && model.playlists == playlists && model.allIds == tracks)
        await model.closeLibrary()
    }

    @Test func unreadableExistingUSBDoesNotBecomeAnEmptySetupTarget() async throws {
        let f = try Fixture()
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        // Corrupt, already-existing manifest must be preserved for recovery.
        _ = try Manifest.update(on: volume, basedOn: nil) { $0.sourceID = "old-library" }
        let manifestURL = usb.appendingPathComponent(".deckhand/manifest.json")
        try "corrupt".write(to: manifestURL, atomically: true, encoding: .utf8)
        let drive = Drive.read(volume)
        #expect(drive.manifest == nil && drive.readError != nil)
        let model = f.model(driveReader: { [drive] }); await model.load(); await model.startEmptyLibrary()
        model.refreshDrives()
        for _ in 0..<200 where model.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        model.requestSync(); model.initializeDrive(drive)
        #expect(model.showingUSBConnection && !model.job.running)
        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == "corrupt")
        await model.closeLibrary()
    }

    @Test func startupChecksCacheWithoutHashingUnseenAudio() async throws {
        let f = try Fixture()
        let cache = try AnalysisCache(root: f.root.appendingPathComponent("Cache"))
        let model = f.model(cache: cache)
        await model.load(); await model.connect(SourceConnection(kind: .folder, location: f.a))
        let id = try #require(model.allIds.first)
        for _ in 0..<200 where model.rows[id]?.checked != true { try await Task.sleep(for: .milliseconds(5)) }
        let row = try #require(model.rows[id])
        #expect(row.checked && !row.analyzed && row.hash == nil)
        #expect(cache.cachedContentHash(of: row.location) == nil)
        #expect(model.unanalyzedCount == 1)
        await model.closeLibrary()
    }

    @Test func musicExportKeepsRatingsUnlessExplicitlySelected() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        let playlist = try #require(model.playlists.first)
        let id = try #require(model.allIds.first)
        model.setRating(5, for: [id])
        while model.pendingSourceEdits > 0 { try await Task.sleep(for: .milliseconds(5)) }
        let destination = AppMusicDestination()
        await model.exportMusic(playlistIDs: [playlist.id], destination: destination)
        #expect(await destination.ratingWrites == 0)
        #expect(model.musicExportResult?.hasPrefix("Saved") == true)
        await model.exportMusic(playlistIDs: [playlist.id], includeRatings: true, destination: destination)
        #expect(await destination.ratingWrites == 1)
        #expect(model.rows[id]?.rating == 5)
        await model.closeLibrary()
    }

    @Test func savedLibraryReadsNeverImportAndExplicitReimportKeepsLocalWork() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let a = SourceConnection(kind: .folder, location: f.a)
        let b = SourceConnection(kind: .folder, location: f.b)
        await model.connect(a); await model.connect(b)
        let imported = try #require(model.playlists.first { $0.name == "A Set" })
        let originalIDs = model.allIds
        await model.createPlaylist(named: "My Set")
        let local = try #require(model.playlists.last)
        await model.add(originalIDs, to: local)
        await model.createPlaylist(named: "Weekend", isFolder: true)
        let folder = try #require(model.playlists.last)
        await model.movePlaylist(imported.id, toFolder: folder.id)
        model.setRating(5, for: [originalIDs[0]])
        while model.pendingSourceEdits > 0 { try await Task.sleep(for: .milliseconds(5)) }
        let libraryID = model.libraryID
        try FileManager.default.copyItem(at: f.a.appendingPathComponent("Song.wav"), to: f.a.appendingPathComponent("Bonus.wav"))
        try "Song.wav\nBonus.wav\n".write(to: f.a.appendingPathComponent("A Set.m3u8"), atomically: true, encoding: .utf8)
        await model.readLibrary() // Even an existing legacy update default must not trigger an import.
        #expect(model.allIds == originalIDs)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.allIds == originalIDs)
        await reopened.reimport(b) // History explicitly chooses B; changes in A must wait.
        #expect(reopened.allIds == originalIDs)
        await reopened.reimport(a)
        #expect(reopened.allIds.count == originalIDs.count + 1)
        let updated = try #require(reopened.playlists.first { $0.id == imported.id })
        #expect(updated.parentId == folder.id && updated.trackIds.count == 2)
        #expect(reopened.playlists.first { $0.id == local.id }?.trackIds == originalIDs)
        #expect(reopened.rows[originalIDs[0]]?.rating == 5 && reopened.libraryID == libraryID)
        let importedAt = try #require(reopened.connections.first { $0.id == a.id }?.lastImported)
        await reopened.closeLibrary()
        let final = f.model(); await final.load()
        #expect(final.allIds.count == originalIDs.count + 1)
        #expect(final.connections.first { $0.id == a.id }?.lastImported == importedAt)
        #expect(final.playlists.first { $0.id == local.id }?.trackIds == originalIDs)
        #expect(final.rows[originalIDs[0]]?.rating == 5 && final.libraryID == libraryID)
        await final.closeLibrary()
    }

    @Test func collapsedFoldersPersistSkipKeyboardRowsAndKeepTracks() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        let playlist = try #require(model.playlists.first)
        await model.createPlaylist(named: "Weekend", isFolder: true)
        let folder = try #require(model.playlists.last)
        await model.movePlaylist(playlist.id, toFolder: folder.id)
        #expect(model.playlistEntries.map(\.id) == [folder.id, playlist.id])
        model.selection = .playlist(playlist.id)
        model.togglePlaylistFolder(folder.id)
        #expect(model.selection == .playlist(folder.id))
        #expect(model.playlistEntries.map(\.id) == [folder.id])
        #expect(!model.sidebarOrder.contains(.playlist(playlist.id)))
        #expect(model.trackIds(of: folder) == playlist.trackIds && model.trackCount(of: folder) == 1)
        model.selectAdjacentSidebarItem(-1)
        #expect(model.selection == .needsAnalysis)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(!reopened.isFolderExpanded(folder.id) && reopened.playlistEntries.map(\.id) == [folder.id])
        reopened.togglePlaylistFolder(folder.id)
        #expect(reopened.playlistEntries.map(\.id) == [folder.id, playlist.id])
        await reopened.closeLibrary()
    }

    @Test func movingIntoCollapsedNestedFolderRevealsDestinationAndKeepsUSBPlaylistIdentity() async throws {
        let f = try Fixture()
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(driveReader: { [Drive.read(volume)] }); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        let playlist = try #require(model.playlists.first)
        await model.createPlaylist(named: "Parent", isFolder: true)
        let parent = try #require(model.playlists.last)
        await model.createPlaylist(named: "Child", isFolder: true)
        let child = try #require(model.playlists.last)
        await model.movePlaylist(child.id, toFolder: parent.id)
        _ = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = model.libraryID; $0.selectedPlaylistIds = [playlist.id]
        }
        model.refreshDrives()
        for _ in 0..<200 where model.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isOnDrive(playlist))
        model.togglePlaylistFolder(child.id); model.togglePlaylistFolder(parent.id)
        #expect(!model.canMovePlaylist(parent.id, toFolder: child.id))
        #expect(!model.canMovePlaylist(playlist.id, toFolder: playlist.id))
        await model.movePlaylist(playlist.id, toFolder: child.id)
        #expect(model.isFolderExpanded(parent.id) && model.isFolderExpanded(child.id))
        #expect(model.playlistEntries.map(\.id) == [parent.id, child.id, playlist.id])
        #expect(model.playlists.first { $0.id == playlist.id }?.trackIds == playlist.trackIds)
        #expect(model.isOnDrive(playlist) && model.activeDrive?.manifest?.selectedPlaylistIds == [playlist.id])
        model.togglePlaylistFolder(parent.id)
        #expect(model.isOnDrive(playlist) && model.trackCount(of: parent) == 1)
        await model.movePlaylist(playlist.id, toFolder: nil)
        #expect(model.playlists.first { $0.id == playlist.id }?.parentId == nil && model.isOnDrive(playlist))
        await model.closeLibrary()
    }

    @Test func playlistAndTrackDragPayloadsDoNotOverlap() {
        let id = "deckhand:playlist:example"
        #expect(PlaylistDrag.decode([PlaylistDrag.encode(id)]) == id)
        #expect(TrackDrag.decode([PlaylistDrag.encode(id)]).isEmpty)
        #expect(PlaylistDrag.decode([TrackDrag.encode(["track"])]) == nil)
        #expect(PlaylistDrag.decode(["deckhand-playlist:"]) == nil)
        #expect(PlaylistDrag.decode([PlaylistDrag.encode(id), PlaylistDrag.encode("other")]) == nil)
    }

    @Test func playlistDropCopiesOnlyNewTracksAndPersistsWithoutMovingOrEditingSource() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        await model.connect(SourceConnection(kind: .folder, location: f.b))
        let ids = model.allIds
        #expect(ids.count == 2)
        await model.createPlaylist(named: "Source")
        let source = try #require(model.selectedPlaylist)
        await model.add(ids, to: source)
        await model.createPlaylist(named: "Destination")
        let destination = try #require(model.selectedPlaylist)
        await model.add([ids[1]], to: destination)
        let before = model.playlists
        let plan = try #require(model.playlistDrop([PlaylistDrag.encode(source.id)], into: destination.id))
        #expect(plan.copy?.trackIDs == [ids[0]] && plan.copy?.skipped == 1)
        #expect(plan.operation == .copy)
        #expect(model.playlists == before) // Preview/cancelling never writes.
        #expect(model.playlistDrop([PlaylistDrag.encode(source.id)], into: source.id) == nil)
        // Another edit between preview and confirmation is deduplicated by the store too.
        await model.add([ids[0]], to: destination)
        await model.applyPlaylistDrop(plan)
        #expect(model.playlists.first { $0.id == destination.id }?.trackIds == [ids[1], ids[0]])
        #expect(model.playlists.first { $0.id == source.id }?.trackIds == ids)
        #expect(model.playlists.first { $0.id == source.id }?.parentId == nil)
        let included = try #require(model.playlistDrop([PlaylistDrag.encode(source.id)], into: destination.id))
        #expect(included.copy?.trackIDs.isEmpty == true && included.operation == .cancel)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.playlists.first { $0.id == destination.id }?.trackIds == [ids[1], ids[0]])
        #expect(reopened.playlists.first { $0.id == source.id }?.trackIds == ids)
        await reopened.closeLibrary()
    }

    @Test func playlistDropPreservesFolderMovesRejectsInvalidAndDeduplicatesTrackPayloads() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        let source = try #require(model.playlists.first), id = try #require(model.allIds.first)
        await model.createPlaylist(named: "Target")
        let target = try #require(model.selectedPlaylist)
        await model.createPlaylist(named: "Folder", isFolder: true)
        let folder = try #require(model.selectedPlaylist)
        let move = try #require(model.playlistDrop([PlaylistDrag.encode(source.id)], into: folder.id))
        #expect(move == .move(source.id, folder.id) && move.operation == .move)
        await model.applyPlaylistDrop(move)
        #expect(model.playlistDrop([PlaylistDrag.encode(source.id)], into: folder.id) == nil)
        #expect(model.playlistDrop([PlaylistDrag.encode(source.id)], into: nil) == .move(source.id, nil))
        #expect(model.playlistDrop([PlaylistDrag.encode(folder.id)], into: target.id) == nil)
        #expect(model.playlistDrop([PlaylistDrag.encode(folder.id)], into: folder.id) == nil)
        #expect(model.playlistDrop([PlaylistDrag.encode("missing")], into: target.id) == nil)
        #expect(model.playlistDrop(["untrusted text"], into: target.id) == nil)
        #expect(model.playlistDrop([TrackDrag.encode([id])], into: folder.id) == nil)
        #expect(model.playlistDrop([TrackDrag.encode([id])], into: nil) == nil)
        #expect(model.playlistDrop([TrackDrag.encode([id])], into: "missing") == nil)
        let tracks = try #require(model.playlistDrop([TrackDrag.encode([id, id, "missing"])], into: target.id))
        #expect(tracks.copy?.trackIDs == [id] && tracks.copy?.skipped == 1)
        await model.applyPlaylistDrop(tracks)
        #expect(model.playlists.first { $0.id == target.id }?.trackIds == [id])
        #expect(model.playlists.first { $0.id == source.id }?.trackIds == source.trackIds)
        await model.deletePlaylist(target.id)
        await model.applyPlaylistDrop(tracks) // A destination deleted while confirming is never resurrected.
        #expect(!model.playlists.contains { $0.id == target.id })
        await model.closeLibrary()
    }

    @Test func insertionReordersTopLevelAndFolderChildrenPreservingIdentityAcrossRestartAndReimport() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let connection = SourceConnection(kind: .folder, location: f.a)
        await model.connect(connection)
        let imported = try #require(model.playlists.first)
        await model.createPlaylist(named: "First")
        let first = try #require(model.selectedPlaylist)
        await model.createPlaylist(named: "Last")
        let last = try #require(model.selectedPlaylist)
        await model.createPlaylist(named: "Folder", isFolder: true)
        let folder = try #require(model.selectedPlaylist)
        let drag = [PlaylistDrag.encode(last.id)]
        let top = try #require(model.playlistInsertion(drag, parentID: nil, before: imported.id))
        await model.applyPlaylistDrop(top)
        #expect(model.playlistEntries.map(\.id) == [last.id, imported.id, first.id, folder.id])
        #expect(model.playlistInsertion(drag, parentID: nil, before: imported.id) == nil) // Already here.
        await model.movePlaylist(imported.id, toFolder: folder.id)
        await model.movePlaylist(first.id, toFolder: folder.id)
        #expect(model.playlistDrop(drag, into: imported.id, at: .before) == model.playlistInsertion(drag, parentID: folder.id, before: imported.id))
        #expect(model.playlistDrop(drag, into: imported.id, at: .after) == model.playlistInsertion(drag, parentID: folder.id, before: first.id))
        #expect(model.playlistDrop(drag, into: folder.id, at: .after) == model.playlistInsertion(drag, parentID: folder.id, before: imported.id))
        model.togglePlaylistFolder(folder.id)
        #expect(model.playlistDrop(drag, into: folder.id, at: .after) == model.playlistInsertion(drag, parentID: nil, before: nil))
        model.togglePlaylistFolder(folder.id)
        let middle = try #require(model.playlistInsertion(drag, parentID: folder.id, before: first.id))
        await model.applyPlaylistDrop(middle)
        #expect(model.playlistEntries.map(\.id) == [folder.id, imported.id, last.id, first.id])
        let end = try #require(model.playlistInsertion([PlaylistDrag.encode(imported.id)], parentID: folder.id, before: nil))
        await model.applyPlaylistDrop(end)
        #expect(model.playlistEntries.map(\.id) == [folder.id, last.id, first.id, imported.id])
        #expect(model.playlistInsertion([PlaylistDrag.encode(folder.id)], parentID: folder.id, before: last.id) == nil)
        #expect(model.playlistInsertion(drag, parentID: nil, before: first.id) == nil) // Anchor belongs to another parent.
        #expect(model.playlistInsertion(drag, parentID: folder.id, before: last.id) == nil)
        #expect(model.playlistInsertion([TrackDrag.encode(imported.trackIds)], parentID: folder.id, before: first.id) == nil)
        let savedImport = try #require(model.importConnections.first { $0.id == connection.id })
        await model.reimport(savedImport.connection)
        let order = model.playlistEntries.map(\.id)
        #expect(order == [folder.id, last.id, first.id, imported.id])
        #expect(model.playlists.first { $0.id == imported.id }?.trackIds == imported.trackIds)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.playlistEntries.map(\.id) == order)
        #expect(reopened.playlists.first { $0.id == imported.id }?.parentId == folder.id)
        await reopened.closeLibrary()
    }

    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-app-library-\(UUID())")
        let suite = "deckhand-app-library-\(UUID())"
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        var database: URL { root.appendingPathComponent("Library") }
        var a: URL { root.appendingPathComponent("A") }
        var b: URL { root.appendingPathComponent("B") }
        init() throws {
            for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            for dir in [a, b] {
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                let output = try AVAudioFile(forWriting: dir.appendingPathComponent("Song.wav"), settings: format.settings)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
                pcm.frameLength = 4410
                try output.write(from: pcm)
                try "Song.wav\n".write(to: dir.appendingPathComponent("\(dir.lastPathComponent) Set.m3u8"), atomically: true, encoding: .utf8)
            }
        }
        deinit { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        @MainActor func model(music: SourceLibrary? = nil, cache: AnalysisCache? = nil, driveReader: @escaping @Sendable () -> [Drive] = { [] }) -> LibraryModel {
            LibraryModel(libraryDirectory: database, legacyDirectory: root.appendingPathComponent("Legacy"),
                         defaults: defaults, observesChanges: false, cache: cache,
                         musicImport: { music ?? SourceLibrary(playlists: [], tracks: [:]) }, driveReader: driveReader)
        }
    }

    @Test func firstLaunchWaitsForSavedLibraryCheckBeforeShowingChooser() async throws {
        let f = try Fixture(); let model = f.model()
        #expect(model.startupScreen == .loading)
        await model.load()
        #expect(model.startupScreen == .sourceChooser)
        await model.startEmptyLibrary()
        #expect(model.startupScreen == .workspace)
        await model.closeLibrary()
    }

    @Test(arguments: [false, true])
    func savedEmptyAndPopulatedLibrariesNeverStartInChooser(populated: Bool) async throws {
        let f = try Fixture(); let original = f.model()
        await original.load(); await original.startEmptyLibrary()
        if populated { await original.connect(SourceConnection(kind: .folder, location: f.a)) }
        let tracks = original.allIds, playlists = original.playlists
        await original.closeLibrary()
        let reopened = f.model()
        #expect(reopened.startupScreen == .loading) // The first render must not be onboarding.
        await reopened.load()
        #expect(reopened.startupScreen == .workspace)
        #expect(reopened.allIds == tracks && reopened.playlists == playlists)
        await reopened.closeLibrary()
    }

    @Test func startupReadFailureShowsErrorAndRetryRechecksSavedLibrary() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.database, withIntermediateDirectories: true)
        let database = f.database.appendingPathComponent("library.sqlite")
        let invalid = Data("not a database".utf8)
        try invalid.write(to: database)
        let model = f.model()
        #expect(model.startupScreen == .loading)
        await model.load()
        guard case .failed = model.startupScreen else { Issue.record("Failed library read showed onboarding"); return }
        #expect(try Data(contentsOf: database) == invalid)
        // Retain the corrupt file while simulating a user restoring their database.
        try FileManager.default.moveItem(at: database, to: f.root.appendingPathComponent("corrupt.sqlite"))
        await model.retryLoad()
        #expect(model.startupScreen == .sourceChooser)
        await model.startEmptyLibrary()
        #expect(model.startupScreen == .workspace)
        await model.closeLibrary()
    }

    @Test func emptyLibraryThenFolderMusicAndSecondFolderKeepsMixedPlaylistAndRatingsAcrossRestart() async throws {
        let f = try Fixture()
        var music = SourceLibrary(playlists: [SourcePlaylist(id: "MP", name: "Music Set", trackIds: ["MT"])],
                                  tracks: ["MT": SourceTrack(id: "MT", title: "Music Song", location: f.a.appendingPathComponent("Song.wav"))])
        music.allTrackIds = ["MT"]
        let model = f.model(music: music)
        await model.load()
        #expect(!model.hasLibrary)
        await model.startEmptyLibrary()
        await model.createPlaylist(named: "My Deckhand Set")
        let local = try #require(model.playlists.first)
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        let id = try #require(model.allIds.first)
        await model.add([id], to: local)
        model.setRating(5, for: [id])
        while model.pendingSourceEdits > 0 { try await Task.sleep(for: .milliseconds(5)) }
        await model.connect(SourceConnection(kind: .music))
        #expect(model.rows.count == 1) // The same file imported by two adapters shares one identity.
        #expect(model.playlists.first { $0.id == "MP" }?.trackIds == [id])
        #expect(model.rows[id]?.rating == 5)
        await model.connect(SourceConnection(kind: .folder, location: f.b))
        let second = try #require(model.allIds.first { $0 != id })
        await model.add([second], to: local)
        #expect(model.selection == .playlist(local.id))
        #expect(model.playlists.count == 4 && model.rows.count == 2)
        let libraryID = model.libraryID
        await model.disconnectSource()
        #expect(model.source == nil && model.sourceAvailable)
        await model.closeLibrary()
        let reopened = f.model()
        await reopened.load()
        #expect(reopened.libraryID == libraryID)
        #expect(reopened.source == nil && reopened.rows.count == 2)
        #expect(reopened.rows[id]?.rating == 5)
        #expect(reopened.playlists.first { $0.id == local.id }?.trackIds == [id, second])
        #expect(reopened.selection == .playlist(local.id))
        await reopened.closeLibrary()
    }

    @Test func failedImportKeepsLibraryEditableAndRestartsWithMissingAudio() async throws {
        let f = try Fixture(); let model = f.model()
        await model.load()
        let source = SourceConnection(kind: .folder, location: f.a)
        await model.connect(source)
        let id = try #require(model.allIds.first)
        let imported = try #require(model.playlists.first)
        try FileManager.default.removeItem(at: f.a)
        await model.connect(source)
        #expect(model.sourceError != nil && model.sourceAvailable)
        #expect(model.rows.count == 1 && model.unavailableTracks == 1)
        await model.createPlaylist(named: "Offline Set")
        let local = try #require(model.playlists.last)
        await model.add([id], to: local)
        await model.remove([id], from: imported)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.rows.count == 1 && reopened.unavailableTracks == 1)
        #expect(reopened.playlists.first?.trackIds.isEmpty == true)
        #expect(reopened.playlists.last?.trackIds == [id])
        await reopened.closeLibrary()
    }

    @Test func invalidFirstImportDoesNotInitializeOrReplaceAnEmptyLibrary() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let xml = f.root.appendingPathComponent("bad.xml")
        try "<bad/>".write(to: xml, atomically: true, encoding: .utf8)
        await model.connect(SourceConnection(kind: .rekordbox, location: xml))
        #expect(!model.hasLibrary && model.rows.isEmpty && model.playlists.isEmpty)
        #expect(model.sourceError != nil)
        await model.startEmptyLibrary()
        #expect(model.hasLibrary && model.sourceAvailable)
        await model.closeLibrary()
    }

    @Test func addingAndUpdatingSecondaryImportKeepsDefaultAndChangingDefaultPersistsWithoutReadingSource() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let a = SourceConnection(kind: .folder, location: f.a)
        let b = SourceConnection(kind: .folder, location: f.b)
        await model.connect(a)
        let id = try #require(model.allIds.first)
        model.setRating(5, for: [id])
        while model.pendingSourceEdits > 0 { try await Task.sleep(for: .milliseconds(5)) }
        await model.connect(b)
        #expect(model.source?.id == a.id)
        let saved = model.playlists
        await model.connect(b, makePrimary: false)
        #expect(model.source?.id == a.id && model.playlists == saved)
        try FileManager.default.moveItem(at: f.b, to: f.root.appendingPathComponent("B Offline"))
        await model.setPrimaryImport(b.id) // Settings changes a preference, even while the import is offline.
        #expect(model.source?.id == b.id && model.sourceError == nil)
        #expect(model.libraryID != nil && model.playlists == saved && model.rows[id]?.rating == 5)
        await model.closeLibrary()
        let restarted = f.model(); await restarted.load()
        #expect(restarted.source?.id == b.id && restarted.importConnections.count == 2)
        #expect(restarted.playlists == saved && restarted.rows[id]?.rating == 5)
        await restarted.closeLibrary()
    }

    @Test func removeReaddAndFailedSecondaryImportPreserveDefaultLocalEditsAndIdentities() async throws {
        let f = try Fixture(); let model = f.model(); await model.load()
        let a = SourceConnection(kind: .folder, location: f.a)
        let b = SourceConnection(kind: .folder, location: f.b)
        await model.connect(a); await model.connect(b)
        let id = try #require(model.allIds.first)
        await model.createPlaylist(named: "My Local Set")
        let local = try #require(model.playlists.last)
        await model.add([id], to: local)
        let before = model.playlists, tracks = Set(model.allIds), libraryID = model.libraryID
        await model.removeImport(b.id)
        #expect(model.importConnections.count == 1 && model.source?.id == a.id)
        #expect(model.playlists == before && Set(model.allIds) == tracks)
        // The normal picker can reuse retained connection IDs when a removed path is added again.
        let retained = try #require(model.recentSources.first { $0.location == b.location })
        await model.connect(retained)
        #expect(model.importConnections.count == 2 && model.source?.id == a.id)
        #expect(model.playlists == before && Set(model.allIds) == tracks)
        try FileManager.default.removeItem(at: f.b)
        await model.connect(b, makePrimary: false)
        #expect(model.sourceError != nil && model.source?.id == a.id)
        #expect(model.playlists == before && model.libraryID == libraryID)
        await model.removeImport(a.id)
        #expect(model.source == nil && model.sourceAvailable)
        await model.closeLibrary()
        let reopened = f.model(); await reopened.load()
        #expect(reopened.source == nil && reopened.importConnections.count == 1)
        #expect(reopened.playlists == before && Set(reopened.allIds) == tracks)
        await reopened.closeLibrary()
    }

    @Test func usbSelectionAndReconnectKeepPlaylistAndKeyboardOrderAndLibraryOwnership() async throws {
        let f = try Fixture()
        let usb = f.root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let volume = Volume(testRoot: usb)
        let model = f.model(driveReader: { [Drive.read(volume)] }); await model.load()
        await model.connect(SourceConnection(kind: .folder, location: f.a))
        await model.connect(SourceConnection(kind: .folder, location: f.b))
        let libraryID = try #require(model.libraryID)
        let selected = try #require(model.playlists.last)
        let entries = model.playlistEntries.map(\.id), order = model.sidebarOrder
        let manifest = try Manifest.update(on: volume, basedOn: nil) {
            $0.sourceID = libraryID
            $0.selectedPlaylistIds = [selected.id]
        }
        model.refreshDrives()
        for _ in 0..<200 where model.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        let drive = try #require(model.activeDrive)
        #expect(model.driveMatchesSource(drive) && model.isOnDrive(selected))
        #expect(model.playlistEntries.map(\.id) == entries && model.sidebarOrder == order)
        model.openSidebarItem(.playlist(entries[0]))
        let focus = model.trackFocusRequest
        #expect(focus > 0 && model.selection == .playlist(entries[0]))
        model.openSidebarItem(.playlist(entries[0])) // Clicking the already-open playlist still returns focus.
        #expect(model.trackFocusRequest == focus + 1)
        model.selectAdjacentSidebarItem(1) // Sidebar arrows retain sidebar focus until Tab.
        #expect(model.trackFocusRequest == focus + 1)
        #expect(model.selection == .playlist(entries[1]))
        model.focusTrackList()
        #expect(model.trackFocusRequest == focus + 2 && model.selection == .playlist(entries[1]))
        await model.setPrimaryImport(nil)
        #expect(model.driveMatchesSource(drive) && model.isOnDrive(selected))
        #expect(model.sidebarOrder == order && model.libraryID == libraryID)
        await model.closeLibrary()
        let restarted = f.model(driveReader: { [Drive.read(volume)] }); await restarted.load(); restarted.refreshDrives()
        for _ in 0..<200 where restarted.activeDrive == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(restarted.activeDrive?.manifest?.selectedPlaylistIds == manifest.selectedPlaylistIds)
        #expect(restarted.isOnDrive(selected) && restarted.sidebarOrder == order)
        await restarted.closeLibrary()
    }
}

actor AppMusicDestination: MusicDestination {
    var songs: [SourceTrack] = []
    var playlists: [String: [String]] = [:]
    var names: [String: String] = [:]
    var parents: [String: String] = [:]
    var nextID = 0
    var mutations = 0
    var ratingWrites = 0
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
        ratingWrites += 1
        if let i = songs.firstIndex(where: { $0.id == trackID }) { songs[i].rating = stars == 0 ? nil : stars }
        mutations += 1
    }
}
