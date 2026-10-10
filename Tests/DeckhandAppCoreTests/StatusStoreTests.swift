import DeckhandAppCore
import DeckhandCore
import Foundation
import Sync
import Testing

enum Fixture {
    static let drive = "/Volumes/DECK"

    static func track(_ id: String) -> SourceTrack {
        SourceTrack(id: id, title: "Song \(id)", artist: "Artist", location: URL(fileURLWithPath: "/m/\(id).mp3"))
    }

    static func facts(_ ids: [String]) -> [String: TrackFacts] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, TrackFacts(audio: .ok(hash: "h1:\($0)0123456789", size: 1000, modified: 1))) })
    }

    /// An evaluation of a library against a drive that has nothing on it yet: every known track is pending.
    static func status(playlists: [SourcePlaylist], known: [String], selected: [String], drive: String = drive) -> DriveStatus {
        var m = Manifest()
        m.selectedPlaylistIds = selected
        let ids = Set(playlists.flatMap(\.trackIds))
        let lib = SourceLibrary(playlists: playlists, tracks: Dictionary(uniqueKeysWithValues: ids.map { ($0, track($0)) }))
        var profile = OutputProfile()
        profile.artwork = false
        let c = SyncStatus.evaluate(library: lib, manifest: m, facts: facts(known), drive: DriveProbe(), profile: profile)
        return DriveStatus(c, driveId: drive, available: 1 << 30)
    }

    static var pending: DriveStatus {
        status(playlists: [SourcePlaylist(id: "P", name: "Set", trackIds: ["T"])], known: ["T"], selected: ["P"])
    }

    /// Nothing selected, nothing on the drive.
    static var clean: DriveStatus { status(playlists: [SourcePlaylist(id: "P", name: "Set", trackIds: ["T"])], known: ["T"], selected: []) }
}

@Suite struct DriveStatusTests {
    @Test func tracksAndPlaylistsComeFromTheEvaluation() {
        let f = SourcePlaylist(id: "F", name: "Folder", isFolder: true)
        let p1 = SourcePlaylist(id: "P1", name: "One", parentId: "F", trackIds: ["A", "B"])
        let p2 = SourcePlaylist(id: "P2", name: "Two", parentId: "F", trackIds: ["B", "C"])
        let p3 = SourcePlaylist(id: "P3", name: "Three", trackIds: ["U"])
        let s = Fixture.status(playlists: [f, p1, p2, p3], known: ["A", "B", "C"], selected: ["P1", "P2", "P3"])
        #expect(s.tracks["A"] == .pending)
        // Unknown (not hashed yet) is neither synced nor pending, and isn't counted.
        #expect(s.tracks["U"] == .unknown)
        #expect(s.summary.unknown == 1)
        #expect(s.summary.pending == 3)
        #expect(s.playlists["P1"] == .pending(2))
        #expect(s.playlists["F"] == .pending(3))
        #expect(s.playlists["P3"] == .unknown)
        #expect(!s.complete)
        #expect(s.onDrive.isEmpty)
        #expect(s.details.contains { $0.hasPrefix("Artist — Song A: new") })
        #expect(s.bytesToCopy == 3000)
        #expect(s.spaceNeeded == 3000 + SyncStatus.spaceMargin)
    }

    @Test func wontFitUsesTheSyncsOwnSpaceCheck() {
        var s = Fixture.pending
        s.available = s.spaceNeeded
        #expect(!s.wontFit)
        s.available = s.spaceNeeded - 1
        #expect(s.wontFit)
        // Nothing to do: nothing to fit.
        var clean = Fixture.clean
        clean.available = 0
        #expect(!clean.wontFit)
    }

    @Test func aCleanSyncMarksPendingTracksSynced() {
        let s = Fixture.pending.markedClean()
        #expect(s.optimistic)
        #expect(s.isClean)
        #expect(s.tracks["T"] == .synced)
        #expect(s.playlists["P"] == .synced)
        #expect(s.onDrive == ["T"])
        #expect(s.summary.clean == 1)
        #expect(s.bytesToCopy == 0)
        #expect(s.details.isEmpty)
    }
}

@Suite struct StatusStoreTests {
    @Test func theNewestEvaluationWins() {
        var store = StatusStore()
        #expect(store.status == nil)
        let older = store.begin()
        let newer = store.begin()
        let o1 = store.finish(Fixture.clean, request: newer)
        #expect(o1 == .applied)
        let o2 = store.finish(Fixture.pending, request: older)
        #expect(o2 == .stale)
        #expect(store.status == Fixture.clean)
    }

    @Test func syncFinishingWhileAnEvaluationIsInFlight() {
        var store = StatusStore()
        _ = store.finish(Fixture.pending, request: store.begin())
        // An evaluation starts (a library reload landed), then the sync finishes before it does.
        let inFlight = store.begin()
        store.syncFinished(driveId: Fixture.drive, report: SyncReport(generation: 2, clean: true, pending: 0))
        #expect(store.status?.isClean == true)
        #expect(store.status?.optimistic == true)
        // Its result describes the drive before the sync: dropped.
        let o3 = store.finish(Fixture.pending, request: inFlight)
        #expect(o3 == .stale)
        // So is one issued before the drive was read again.
        let o4 = store.finish(Fixture.pending, request: store.begin())
        #expect(o4 == .stale)
        #expect(store.status?.optimistic == true)
        // The verification, issued after reading the library and drive again, replaces the optimistic status.
        let verification = store.beginVerification()
        let o5 = store.finish(Fixture.clean, request: verification)
        #expect(o5 == .verified)
        #expect(store.status?.optimistic == false)
        #expect(!store.awaitingVerification)
        // Later evaluations apply as usual.
        let o6 = store.finish(Fixture.pending, request: store.begin())
        #expect(o6 == .applied)
    }

    @Test func verificationReportsWhatsStillPending() {
        var store = StatusStore()
        _ = store.finish(Fixture.pending, request: store.begin())
        store.syncFinished(driveId: Fixture.drive, report: SyncReport(generation: 2, clean: true, pending: 0))
        let verification = store.beginVerification()
        let o7 = store.finish(Fixture.pending, request: verification)
        #expect(o7 == .leftover(Fixture.pending))
        #expect(store.status?.tracks["T"] == .pending)
    }

    @Test func aSyncThatDidntReportCleanShowsNothingOptimistic() {
        var store = StatusStore()
        _ = store.finish(Fixture.pending, request: store.begin())
        store.syncFinished(driveId: Fixture.drive, report: SyncReport(generation: 2, clean: false, pending: 1))
        #expect(store.status?.optimistic == false)
        store.syncFinished(driveId: Fixture.drive, report: nil)
        #expect(store.status?.optimistic == false)
        // Another drive's status isn't marked clean by this drive's sync.
        var other = StatusStore()
        _ = other.finish(Fixture.status(playlists: [SourcePlaylist(id: "P", name: "S", trackIds: ["T"])], known: ["T"],
                                        selected: ["P"], drive: "/Volumes/OTHER"), request: other.begin())
        other.syncFinished(driveId: Fixture.drive, report: SyncReport(generation: 2, clean: true, pending: 0))
        #expect(other.status?.optimistic == false)
    }

    @Test func switchingDrivesForgetsTheStatus() {
        var store = StatusStore()
        let before = store.begin()
        store.reset()
        #expect(store.status == nil)
        let o8 = store.finish(Fixture.pending, request: before)
        #expect(o8 == .stale)
        let o9 = store.finish(Fixture.clean, request: store.begin())
        #expect(o9 == .applied)
        // A reset during a sync's verification lets later evaluations through.
        store.syncFinished(driveId: Fixture.drive, report: nil)
        store.reset()
        let o10 = store.finish(Fixture.clean, request: store.begin())
        #expect(o10 == .applied)
    }
}

@Suite struct ReadLedgerTests {
    @Test func aStaleDriveProbeNeverOverwritesANewerOne() {
        var ledger = ReadLedger()
        let first = ledger.begin()
        let second = ledger.begin()
        let newer = ledger.accept("/Volumes/DECK", second)
        let stale = ledger.accept("/Volumes/DECK", first)
        // Other drives are ordered separately.
        let otherDrive = ledger.accept("/Volumes/DJTEST", first)
        #expect(newer && !stale && otherDrive)
    }

    @Test func aLocalChangeBeatsReadsBegunBeforeIt() {
        var ledger = ReadLedger()
        let read = ledger.begin()
        // The app saves a selection edit while the read is in flight.
        let edit = ledger.accept("/Volumes/DECK", ledger.begin())
        let staleRead = ledger.accept("/Volumes/DECK", read)
        let laterRead = ledger.accept("/Volumes/DECK", ledger.begin())
        #expect(edit && !staleRead && laterRead)
    }
}
