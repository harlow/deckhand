import Foundation
import Testing
@testable import Sync

/// Scenario 19: manifest saves never lose an update and never overwrite the only valid copy.
@Suite struct ManifestConcurrencyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-cc-\(UUID().uuidString)")
    var volume: Volume { Volume(testRoot: root) }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func slot(_ i: Int) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: Manifest.urls(root: root)[i]))
    }

    @Test func updateWritesTheOtherFileAndChecksTheGeneration() throws {
        try Manifest().save(to: volume)                       // generation 1 → first file
        let base = try #require(try Manifest.load(from: volume))
        try Manifest.update(on: volume, basedOn: base) { $0.selectedPlaylistIds = ["P1"] }
        #expect(try slot(0).generation == 1 && slot(1).generation == 2)
        // A stale base is refused.
        #expect(throws: SyncError.self) { try Manifest.update(on: volume, basedOn: base) { $0.selectedPlaylistIds = ["P2"] } }
        #expect(try Manifest.load(from: volume)?.selectedPlaylistIds == ["P1"])
    }

    @Test func interleavedAppEditsBothSurvive() throws {
        try Manifest().save(to: volume)
        // Two edits based on the same read: the second is refused, and `edit` re-applies it to the newer copy.
        let base = try #require(try Manifest.load(from: volume))
        try Manifest.update(on: volume, basedOn: base) { $0.selectedPlaylistIds.append("P1") }
        #expect(throws: SyncError.self) { try Manifest.update(on: volume, basedOn: base) { $0.selectedPlaylistIds.append("P2") } }
        try Manifest.edit(on: volume) { $0.selectedPlaylistIds.append("P2") }
        #expect(try Manifest.load(from: volume)?.selectedPlaylistIds == ["P1", "P2"])

        // Concurrent edits from one process are serialized.
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            _ = try? Manifest.edit(on: volume) { $0.selectedPlaylistIds.append("Q\(i)") }
        }
        #expect(try Manifest.load(from: volume)?.selectedPlaylistIds.count == 10)
    }

    @Test func firstSaveOfALegacyFileKeepsIt() throws {
        let url = Manifest.urls(root: root)[0]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = Data(#"{"format":1,"createdAt":"2026-10-07T19:00:53Z","deviceId":"X","nextContentId":5,"nextPlaylistId":1,"selectedPlaylistIds":["P1"],"tracks":{},"playlists":{},"settings":{"cueSource":"deckhand"}}"#.utf8)
        try legacy.write(to: url)
        try Manifest.edit(on: volume) { $0.selectedPlaylistIds.append("P2") }
        #expect(try Data(contentsOf: url) == legacy)
        #expect(try slot(1).generation == 1 && slot(1).selectedPlaylistIds == ["P1", "P2"])
    }

    @Test func tornNewestFileFallsBackAndIsOverwritten() throws {
        var m = Manifest()
        m.nextContentId = 7
        try m.save(to: volume)                                     // gen 1, file 0
        m.nextContentId = 8
        try m.save(to: volume)                                     // gen 2, file 1
        try Data("{\"truncat".utf8).write(to: Manifest.urls(root: root)[1])
        let loaded = try #require(try Manifest.load(from: volume))
        #expect(loaded.nextContentId == 7)
        try Manifest.update(on: volume, basedOn: loaded) { $0.nextContentId = 9 }
        // The valid copy is untouched; the torn one was replaced.
        #expect(try slot(0).nextContentId == 7 && slot(1).nextContentId == 9 && slot(1).generation == 2)
    }

    @Test func equalGenerationsPickTheSecondFileAndWriteTheFirst() throws {
        var a = Manifest(), b = Manifest()
        a.generation = 5; a.nextContentId = 1
        b.generation = 5; b.nextContentId = 2
        let encoder = JSONEncoder.iso
        try FileManager.default.createDirectory(at: Manifest.urls(root: root)[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(a).write(to: Manifest.urls(root: root)[0])
        try encoder.encode(b).write(to: Manifest.urls(root: root)[1])
        let loaded = try #require(try Manifest.load(from: volume))
        #expect(loaded.nextContentId == 2)
        try Manifest.update(on: volume, basedOn: loaded) { $0.nextContentId = 3 }
        #expect(try slot(0).generation == 6 && slot(0).nextContentId == 3 && slot(1).nextContentId == 2)
    }

    @Test func refusesNewerFormats() throws {
        var m = Manifest()
        m.format = Manifest.currentFormat + 1
        try m.save(to: volume)
        let loaded = try #require(try Manifest.load(from: volume))
        #expect(throws: SyncError.self) { try Manifest.update(on: volume, basedOn: loaded) { $0.nextContentId = 2 } }
    }

    @Test func mergeKeepsAppEditsAndRejectsOtherSyncs() throws {
        var base = Manifest()
        base.generation = 3
        base.selectedPlaylistIds = ["P1"]
        var ours = base
        ours.nextContentId = 10
        ours.tracks["A"] = .init(contentId: 9, usbPath: "/a.mp3", contentHash: "h", analysisVersion: 6)
        var theirs = base
        theirs.generation = 4
        theirs.selectedPlaylistIds = ["P1", "P2"]
        theirs.entireLibrary = true
        let merged = try #require(Manifest.merged(ours: ours, base: base, theirs: theirs))
        #expect(merged.selectedPlaylistIds == ["P1", "P2"] && merged.entireLibrary == true && merged.tracks["A"] != nil)
        var otherSync = base
        otherSync.nextContentId = 11
        #expect(Manifest.merged(ours: ours, base: base, theirs: otherSync) == nil)
    }

    @Test func lockIsExclusiveAndStaleLocksAreReplaced() throws {
        let lock = try SyncLock.acquire(on: volume)
        #expect(SyncLock.current(on: volume)?.token == lock.info.token)
        #expect(throws: SyncError.self) { try SyncLock.acquire(on: volume) }
        // The app's edits wait for the sync.
        try Manifest().save(to: volume)
        #expect(throws: SyncError.self) { try Manifest.edit(on: volume) { $0.selectedPlaylistIds = ["P1"] } }
        lock.release()
        #expect(SyncLock.current(on: volume) == nil)
        try Manifest.edit(on: volume) { $0.selectedPlaylistIds = ["P1"] }

        // Left behind by a process that's gone, by another Mac, or long ago: stale.
        let url = SyncLock.url(root: root)
        for info in [SyncLock.Info(pid: 999_999, host: SyncLock.hostName, startedAt: Date(), token: "x"),
                     SyncLock.Info(pid: getpid(), host: "elsewhere", startedAt: Date(), token: "x"),
                     SyncLock.Info(pid: getpid(), host: SyncLock.hostName, startedAt: Date().addingTimeInterval(-7 * 3600), token: "x"),
                     // A live pid that started after the lock was taken is a reused pid.
                     SyncLock.Info(pid: getpid(), host: SyncLock.hostName, startedAt: Date(timeIntervalSince1970: 1_000_000), token: "x")] {
            try JSONEncoder.iso.encode(info).write(to: url)
            #expect(SyncLock.current(on: volume) == nil)
            let fresh = try SyncLock.acquire(on: volume)
            fresh.release()
        }
        // A live holder (this process, started before its lock).
        try JSONEncoder.iso.encode(SyncLock.Info(pid: getpid(), host: SyncLock.hostName, startedAt: Date(), token: "x")).write(to: url)
        #expect(SyncLock.current(on: volume) != nil)
        try FileManager.default.removeItem(at: url)
    }
}

/// Scenario 19 end to end: the app edits the selection while the CLI syncs.
@Suite struct SyncConflictTests {
    @Test func appEditDuringSyncIsKept() throws {
        let h = try SyncHarness()
        for id in ["A", "B"] { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("P1", "One", ["A"])
        h.setPlaylist("P2", "Two", ["B"])
        try h.select(["P1"])
        let plan = try h.evaluate()
        // While the CLI copies and analyzes, the app adds P2 to the drive.
        try h.select(["P1", "P2"])
        let result = try h.executor().execute(plan, on: h.volume)
        #expect(result.wroteDatabase && result.keptConcurrentEdits)
        let m = try h.manifest()
        #expect(m.selectedPlaylistIds == ["P1", "P2"] && m.tracks.keys.sorted() == ["A"] && m.generation == 4)
        // The next sync picks the edit up.
        let next = try h.sync()
        #expect(next.before.track("B")?.changes.contains(.new) == true && next.before.summary.playlistsToCreate == 1)
    }

    @Test func anotherSyncMeanwhileAbortsBeforeTheDatabaseIsTouched() throws {
        let h = try SyncHarness()
        for id in ["A", "B"] { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("P1", "One", ["A"])
        try h.select(["P1"])
        try h.sync()
        h.setPlaylist("P1", "One", ["A", "B"])
        let stale = try h.evaluate()
        // Another process syncs first (e.g. an older Deckhand ignoring the lock).
        try h.sync()
        let db = try Data(contentsOf: h.dbURL)
        h.setPlaylist("P1", "One", ["B"])
        #expect(throws: SyncError.self) { try h.executor().execute(stale, on: h.volume) }
        #expect(try Data(contentsOf: h.dbURL) == db)
    }
}
