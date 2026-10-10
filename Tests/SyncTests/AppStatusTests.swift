import DeckhandAppCore
import DeckhandCore
import Foundation
import MusicSource
import Testing
@testable import Sync

/// The app's status (`StatusEvaluator`, which never hashes) against real syncs: it agrees with the engine, a sync
/// leaves it clean, and Music's live fields keep it clean when iTunesLibrary's snapshot drifts.
@Suite struct AppStatusTests {
    private func appStatus(_ h: SyncHarness, library: SourceLibrary? = nil) throws -> DriveStatus {
        let m = try h.manifest()
        let inputs = StatusInputs(library: library ?? h.library, driveId: h.drive.path, volume: h.volume, manifest: m,
                                  probe: DriveProbe.scan(h.volume, manifest: m))
        return StatusEvaluator.evaluate(inputs, cache: h.cache)
    }

    private func setUp() throws -> SyncHarness {
        let h = try SyncHarness()
        h.analyzeMissing = true
        for id in ["A", "B"] {
            try h.addTrack(id)
            try h.analyze(id)
        }
        h.setPlaylist("P", "Set", ["A", "B"])
        try h.select(["P"])
        return h
    }

    @Test func agreesWithTheEngineAndASyncLeavesItClean() throws {
        let h = try setUp()
        let before = try appStatus(h)
        #expect(before.summary == (try h.evaluate()).summary)
        #expect(before.tracks["A"] == .pending)
        #expect(before.playlists["P"] == .pending(2))
        #expect(before.wontFit == false)

        let run = try h.sync()
        let after = try appStatus(h)
        #expect(after.summary == run.after.summary)
        #expect(after.isClean, "app still shows pending after sync: \(after.details)")
        #expect(after.tracks["A"] == .synced)
        #expect(after.playlists["P"] == .synced)
        #expect(after.onDrive == ["A", "B"])
        // What the app showed optimistically on the sync's word is what reading everything again shows.
        #expect(before.markedClean().tracks == after.tracks)
        #expect(before.markedClean().playlists == after.playlists)
    }

    @Test func aRatingEditIsPendingUntilSynced() throws {
        let h = try setUp()
        try h.sync()
        h.edit("A") { $0.rating = 4 }
        let edited = try appStatus(h)
        #expect(edited.tracks["A"] == .pending)
        #expect(edited.tracks["B"] == .synced)
        #expect(edited.playlists["P"] == .pending(1))
        #expect(edited.summary.records == 1)
        try h.sync()
        #expect(try appStatus(h).isClean)
    }

    @Test func musicBackFillingACommentAfterASyncStaysClean() throws {
        let h = try setUp()
        // iTunesLibrary's snapshot has no comment; Music has back-filled one from the file's tags.
        let snapshot = h.library
        let a = snapshot.tracks["A"]!
        let live = ["A": LiveTrack(title: a.title, artist: a.artist, genre: a.genre, rating: 0, comment: "07A - Energy 8")]
        var overlaid = snapshot
        #expect(MusicLive.overlay(live, onto: &overlaid) == ["A"])

        // The CLI syncs what Music has now.
        h.library = overlaid
        try h.sync()

        // The app reads the same stale snapshot again: with the live overlay it matches the drive...
        var appLibrary = snapshot
        MusicLive.overlay(live, onto: &appLibrary)
        #expect(try appStatus(h, library: appLibrary).isClean)
        // ...where the snapshot alone would say "1 to sync" forever.
        let stale = try appStatus(h, library: snapshot)
        #expect(stale.tracks["A"] == .pending)
        #expect(stale.summary.records == 1)
    }

    @Test func tracksNotHashedYetAreUnknownNotPending() throws {
        let h = try setUp()
        try h.sync()
        // A new track the app hasn't hashed yet.
        try h.addTrack("C")
        h.setPlaylist("P", "Set", ["A", "B", "C"])
        let s = try appStatus(h)
        #expect(s.tracks["C"] == .unknown)
        #expect(s.summary.unknown == 1)
        #expect(s.summary.pending == 0)
        #expect(s.playlists["P"] == .unknown)
        #expect(!s.complete)
        // Once hashed (the app's background analysis load), it's known.
        _ = try h.hash("C")
        #expect(try appStatus(h).tracks["C"] == .pending)
    }
}
