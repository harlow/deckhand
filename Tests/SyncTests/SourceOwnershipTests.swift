import DeckhandCore
import Foundation
import Testing
@testable import Sync

@Suite struct SourceOwnershipTests {
    @Test func folderPlaylistExecutesAndVerifiesOnADeviceLibrary() throws {
        let h = try SyncHarness()
        try h.addTrack("folder:track:A", rating: 4)
        h.library.sourceID = "folder"
        h.library.allTrackIds = ["folder:track:A"]
        h.setPlaylist("folder:playlist:P", "Friday", ["folder:track:A"])
        try Manifest.edit(on: h.volume) { $0.sourceID = "folder" }
        try h.select(["folder:playlist:P"])
        try h.sync()
        let manifest = try h.manifest()
        #expect(manifest.sourceID == "folder")
        #expect(manifest.tracks.count == 1 && manifest.playlists.count == 1)
        #expect(try h.validate().isEmpty)
    }

    @Test func sourceSwitchCannotRemoveExistingDriveContents() throws {
        let h = try SyncHarness()
        try h.addTrack("A")
        h.setPlaylist("P", "Friday", ["A"])
        try h.select(["P"])
        try h.sync()
        let original = try h.manifest()
        h.library.sourceID = "different-folder"
        h.library.tracks = [:]
        h.library.playlists = []
        h.library.allTrackIds = []
        let changes = try h.evaluate()
        #expect(!changes.isComplete)
        #expect(changes.removedTracks.isEmpty && changes.removedPlaylists.isEmpty)
        #expect(changes.nextManifest.tracks == original.tracks)
        #expect(changes.nextManifest.playlists == original.playlists)
    }

    @Test func newDriveBindsToFolderAndThenRejectsMusic() throws {
        let h = try SyncHarness()
        try h.addTrack("A")
        h.library.sourceID = "folder-library"
        h.library.allTrackIds = ["A"]
        let first = try h.evaluate(selection: Selection(playlistIds: [], entireLibrary: true))
        #expect(first.isComplete)
        #expect(first.nextManifest.sourceID == "folder-library")
        #expect(first.nextManifest.format == Manifest.currentFormat)
        #expect(!first.nextManifest.acceptsSource(nil))
        #expect(first.nextManifest.acceptsSource("folder-library"))
    }

    @Test func validEmptyFolderIsCompleteWhileEmptyMusicRemainsUnreadable() {
        var library = SourceLibrary(playlists: [], tracks: [:])
        library.allTrackIds = []
        let selection = Selection(playlistIds: [], entireLibrary: true)
        #expect(SyncStatus.scope(library: library, selection: selection).unreadable)
        library.sourceID = "folder-library"
        #expect(!SyncStatus.scope(library: library, selection: selection).unreadable)
    }

    @Test func legacyDriveIDsRemainValidForMusic() {
        var legacy = Manifest()
        legacy.lastSyncedAt = Date()
        #expect(legacy.acceptsSource(nil))
        #expect(legacy.acceptsSource("apple-music"))
        #expect(!legacy.acceptsSource("folder"))
    }
}
