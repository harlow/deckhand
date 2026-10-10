import DeckhandCore
import Foundation
@testable import OneLibrary
import Testing
@testable import Sync

/// Syncs cut short, analysis that stops being current, and libraries that read wrong.
@Suite struct SyncRecoveryTests {
    func synced(_ ids: [String]) throws -> SyncHarness {
        let h = try SyncHarness()
        for id in ids { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("P1", "One", ids)
        try h.select(["P1"])
        try h.sync()
        return h
    }

    func cutShort(_ h: SyncHarness) throws {
        var e = h.executor()
        e.stopBeforeManifest = true
        let plan = try h.evaluate()
        #expect(throws: SyncError.self) { try e.execute(plan, on: h.volume) }
    }

    @Test func analysisFilesRewrittenInPlaceAreCheckedAgainAfterACutShortSync() throws {
        let h = try synced(["A", "B"])
        let usb = try h.manifest().tracks["A"]!.usbPath
        let original = try Data(contentsOf: h.anlz(usb, "EXT"))
        // `--cues none`, unplugged before the manifest is saved: the files hold the new cues, half-written here.
        h.settings.cues = .none
        let generation = try h.manifest().generationNumber
        try cutShort(h)
        // Before writing in place, the manifest stopped vouching for the files.
        #expect(try h.manifest().generationNumber == generation + 1 && h.manifest().tracks["A"]!.anlzFingerprint == nil)
        let rewritten = try Data(contentsOf: h.anlz(usb, "EXT"))
        #expect(rewritten != original)
        try rewritten.prefix(rewritten.count / 2).write(to: h.anlz(usb, "EXT"))
        // The next sync runs without the flag, so with the settings the drive last saved.
        h.settings.cues = .both
        let c = try h.evaluate()
        #expect(c.track("A")?.changes == [.analysisFiles] && c.track("B")?.changes == [.analysisFiles])
        try h.sync()
        #expect(try Data(contentsOf: h.anlz(usb, "EXT")) == original)
    }

    @Test func filesWrittenWithoutADatabaseWriteReachTheDriveBeforeTheManifest() throws {
        // Only the order can be observed here: a missing-file repair (no database write) saves the manifest after.
        let h = try synced(["A"])
        let usb = try h.manifest().tracks["A"]!.usbPath
        try FileManager.default.removeItem(at: h.anlz(usb, "DAT"))
        let run = try h.sync()
        #expect(!run.result.wroteDatabase && run.result.anlzWritten == ["A"] && run.result.manifest != nil)
    }

    @Test func retainedTrackKeepsItsAnalysisWhenTheCacheEntryIsGone() throws {
        let h = try synced(["A", "B"])
        let m = try h.manifest()
        let bpm = try h.rawBPM(contentId: m.tracks["A"]!.contentId)
        // A's source goes offline, and its analysis stops being current (an analyzer change, or a lost cache).
        try FileManager.default.moveItem(at: h.file("A"), to: h.root.appendingPathComponent("A-away.mp3"))
        try FileManager.default.removeItem(at: h.cache.root.appendingPathComponent("analysis/\(m.tracks["A"]!.contentHash).json"))
        let c = try h.evaluate()
        guard case .retained = c.track("A")!.status else { Issue.record("A should be retained: \(c.track("A")!.status)"); return }
        // Another change rewrites the database; A's row keeps its BPM and analysis files.
        h.edit("B") { $0.rating = 5 }
        try h.sync()
        #expect(try h.database().tracks[m.tracks["A"]!.contentId] != nil)
        #expect(try h.rawBPM(contentId: m.tracks["A"]!.contentId) == bpm && bpm != 0)
        #expect(try h.rawAnalysisPath(contentId: m.tracks["A"]!.contentId) != nil)
    }

    @Test func syncWithoutAnalyzingKeepsAnalysisThatStoppedBeingCurrent() throws {
        let h = try synced(["A"])
        let m = try h.manifest()
        let bpm = try h.rawBPM(contentId: m.tracks["A"]!.contentId)
        try FileManager.default.removeItem(at: h.cache.root.appendingPathComponent("analysis/\(m.tracks["A"]!.contentHash).json"))
        #expect(try h.evaluate().isClean)
        h.edit("A") { $0.title = "Retitled" }
        try h.sync()
        #expect(try h.rawBPM(contentId: m.tracks["A"]!.contentId) == bpm && bpm != 0)
    }

    @Test func contentIdsFromACutShortSyncAreNotReused() throws {
        let h = try synced(["A"])
        try h.addTrack("B"); try h.analyze("B")
        h.setPlaylist("P1", "One", ["A", "B"])
        try cutShort(h)                                   // the database now gives B content ID 2
        #expect(try h.database().tracks[2]?.title == "Song B")
        // B leaves before the next sync; C arrives.
        try h.addTrack("C"); try h.analyze("C")
        h.setPlaylist("P1", "One", ["A", "C"])
        try h.sync()
        #expect(try h.manifest().tracks["C"]!.contentId == 3)
    }

    @Test func duplicateWithOtherTagsSharesTheFileWithoutCopying() throws {
        let h = try synced(["A"])
        let a = try h.manifest().tracks["A"]!
        try h.addTrack("A2", title: "Song A", audio: "A")
        try h.writeAudio(h.file("A2"), audio: "A", tag: "other tags, other size")
        h.setPlaylist("P1", "One", ["A", "A2"])
        let run = try h.sync()
        #expect(run.result.copied.isEmpty && run.result.adopted == ["A2"])
        let m = try h.manifest()
        #expect(m.tracks["A2"]!.usbPath == a.usbPath && m.tracks["A"]!.fileSize == FileOps.size(h.volume.url(forUsbPath: a.usbPath)))
    }

    @Test func emptyLibraryReadChangesNothing() throws {
        let h = try synced(["A", "B"])
        h.library = SourceLibrary(playlists: [], tracks: [:])
        let c = try h.evaluate()
        #expect(c.removedTracks.isEmpty && c.removedPlaylists.isEmpty && !c.isComplete)
        #expect(throws: SyncError.self) { try h.executor().execute(c, on: h.volume) }
    }

    @Test func unreadableFilesAreNotRecordedAsAnalyzerFailures() throws {
        let h = try SyncHarness()
        try h.addTrack("A")
        let runner = AnalysisRunner(cache: h.cache)
        _ = runner.run([.init(url: h.root.appendingPathComponent("gone.mp3"), contentHash: "gone", title: "Gone"),
                        .init(url: h.file("A"), contentHash: try h.hash("A"), title: "A")])
        #expect(h.cache.analysisFailure(forHash: "gone") == nil)
        #expect(h.cache.analysisFailure(forHash: try h.hash("A")) != nil)   // readable but not audio: the analyzer failed
    }
}

extension SyncHarness {
    /// `content.bpmx100` as written.
    func rawBPM(contentId: Int) throws -> Int64? {
        let db = try OneLibraryDatabase.open(dbURL)
        return try db.query("SELECT bpmx100 FROM content WHERE content_id = \(contentId)").first?["bpmx100"]?.int
    }

    func rawAnalysisPath(contentId: Int) throws -> String? {
        let db = try OneLibraryDatabase.open(dbURL)
        return try db.query("SELECT analysisDataFilePath FROM content WHERE content_id = \(contentId)").first?["analysisDataFilePath"]?.string
    }
}
