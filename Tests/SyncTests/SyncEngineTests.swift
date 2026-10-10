import DeckhandCore
import Foundation
import OneLibrary
import Testing
@testable import Sync

/// End-to-end scenarios: what evaluate predicts is what execute does, and evaluating after execute is clean.
@Suite struct SyncEngineTests {
    /// Three analyzed tracks in playlist P1, synced once.
    func synced(_ ids: [String] = ["A", "B", "C"]) throws -> SyncHarness {
        let h = try SyncHarness()
        for id in ids {
            try h.addTrack(id)
            try h.analyze(id)
        }
        h.setPlaylist("P1", "One", ids)
        try h.select(["P1"])
        try h.sync()
        return h
    }

    // 1
    @Test func freshDrive() throws {
        let h = try SyncHarness()
        for id in ["A", "B", "C"] { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("P1", "One", ["C", "A", "B"])
        try h.select(["P1"])
        let run = try h.sync()
        #expect(run.before.summary.toCopy == 3 && run.before.summary.playlistsToCreate == 1)
        #expect(run.before.drive == [.databaseMissing])
        #expect(Set(run.result.anlzWritten) == ["A", "B", "C"])
        let db = try h.database()
        let m = try h.manifest()
        #expect(db.tracks.count == 3)
        #expect(db.playlists.map(\.name) == ["One"])
        #expect(db.playlists[0].contentIds == ["C", "A", "B"].map { m.tracks[$0]!.contentId })
        #expect(m.databaseId == OneLibraryDatabase.fileId(h.dbURL) && m.databaseId != nil)
        for t in m.tracks.values {
            #expect(h.exists(t.usbPath))
            #expect(t.fileSize == FileOps.size(h.volume.url(forUsbPath: t.usbPath)))
            for ext in ["DAT", "EXT", "2EX"] { #expect(FileManager.default.fileExists(atPath: h.anlz(t.usbPath, ext).path)) }
        }
    }

    // 2
    @Test func immediateResyncWritesNothing() throws {
        let h = try synced()
        let generation = try h.manifest().generation
        let files = h.snapshot()
        let run = try h.sync()
        #expect(run.before.isClean)
        #expect(run.result.manifest == nil && !run.result.wroteDatabase && run.result.copied.isEmpty)
        #expect(try h.manifest().generation == generation)
        #expect(h.snapshot() == files)
    }

    // 3
    @Test func metadataEditsRewriteOnlyTheDatabase() throws {
        let h = try synced()
        h.edit("A") { $0.rating = 4; $0.title = "Retitled"; $0.genre = "Disco"; $0.comment = "nice" }
        let before = try h.evaluate()
        #expect(before.track("A")?.changes == [.record, .artworkCheck] || before.track("A")?.changes == [.record])
        #expect(before.track("B")?.status == .clean)
        let files = h.snapshot()
        let run = try h.sync()
        #expect(run.result.wroteDatabase && run.result.copied.isEmpty && run.result.anlzWritten.isEmpty)
        let row = try h.database().tracks[try h.manifest().tracks["A"]!.contentId]!
        #expect(row.title == "Retitled" && row.genre == "Disco")
        // Audio and analysis files untouched.
        let after = h.snapshot()
        #expect(files.filter { !$0.key.contains("rekordbox") && !$0.key.contains(".deckhand") }
            == after.filter { !$0.key.contains("rekordbox") && !$0.key.contains(".deckhand") })
    }

    // 4
    @Test func tagEditThatGrowsTheSourceKeepsTheDriveSize() throws {
        let h = try synced(["A"])
        let usb = try h.manifest().tracks["A"]!.usbPath
        let driveSize = FileOps.size(h.volume.url(forUsbPath: usb))
        // Music rewrites tags in place: an ID3v1 tag appended, audio unchanged.
        let handle = try FileHandle(forWritingTo: h.file("A"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("TAG".utf8) + Data(repeating: 0x20, count: 125))
        try handle.close()
        h.edit("A") { $0.title = "Retitled" }
        let run = try h.sync()
        #expect(run.before.track("A")?.changes.contains(.record) == true)
        #expect(run.result.copied.isEmpty)
        let row = try h.database().tracks[try h.manifest().tracks["A"]!.contentId]!
        #expect(row.fileSize == driveSize && Int64(row.fileSize) != FileOps.size(h.file("A")))

        // The file's tag grew again with no field changing: only the art is rechecked, the database stays.
        try h.writeAudio(h.file("A"), audio: "A", tag: "a longer tag than before")
        #expect(FileOps.size(h.file("A")) != driveSize)
        let run2 = try h.sync()
        #expect(run2.before.track("A")?.changes.contains(.record) == false)
        #expect(!run2.result.wroteDatabase)
    }

    // 5
    @Test func artworkChangesAndUnchangedArt() throws {
        let h = try SyncHarness()
        h.useArtwork = true
        try h.addTrack("A"); try h.analyze("A")
        try h.addTrack("B"); try h.analyze("B")
        h.art["A"] = TestArtwork.png(0.1)
        h.art["B"] = TestArtwork.png(0.1)   // same cover: one image
        h.setPlaylist("P1", "One", ["A", "B"])
        try h.select(["P1"])
        try h.sync()
        let first = try h.manifest()
        #expect(first.artwork?.count == 1)
        let oldImage = ArtworkWriter.path(imageId: first.artwork!.values.first!)

        // Unchanged art, new modification date (Music bumps it for ratings, and its snapshot can catch up after
        // the sync): the art is reread and hashes the same, so nothing is pending.
        h.edit("A") { _ in }
        let same = try h.sync()
        #expect(same.before.track("A")?.changes.isEmpty == true)
        #expect(same.before.isClean && !same.result.wroteDatabase)
        // The drifted key is recorded by the next sync that saves the manifest.
        h.edit("A") { $0.rating = 3 }
        let rated = try h.sync()
        #expect(rated.before.track("A")?.changes == [.record])
        let key = try h.manifest().tracks["A"]?.artworkKey
        #expect(key != nil && key == rated.before.track("A")?.artworkKey)

        // New art for A.
        h.art["A"] = TestArtwork.png(0.9)
        h.edit("A") { _ in }
        let changed = try h.sync()
        #expect(changed.result.wroteDatabase && changed.result.imagesWritten == 1)
        let m = try h.manifest()
        #expect(m.artwork?.count == 2)
        // B keeps the old image; when B's art changes too, the old image goes.
        h.art["B"] = TestArtwork.png(0.5)
        h.edit("B") { _ in }
        try h.sync()
        #expect(!h.exists(oldImage))
        #expect(try h.manifest().artwork?.count == 2)

        // Art removed from a track.
        h.art["B"] = nil
        h.edit("B") { _ in }
        try h.sync()
        #expect(try h.manifest().tracks["B"]?.artworkHash == nil)
    }

    // 6
    @Test func playlistReorderRenameFolderMoveAndSwap() throws {
        let h = try SyncHarness()
        for id in ["A", "B"] { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("F", "Folder", folder: true)
        h.setPlaylist("P1", "One", parent: "F", ["A", "B"])
        h.setPlaylist("P2", "Two", ["A"])
        try h.select(["P1", "P2"])
        try h.sync()

        func expectOnly(_ changes: ChangeSet.PlaylistStatus, for id: String) throws {
            let c = try h.evaluate()
            #expect(c.playlists.first { $0.source.id == id }?.status == changes)
            #expect(c.tracks.allSatisfy { $0.status == .clean })
            let run = try h.sync()
            #expect(run.result.wroteDatabase)
            let db = try h.database()
            let m = try h.manifest()
            for p in h.library.playlists where m.playlists[p.id] != nil {
                let row = try #require(db.playlists.first { $0.playlistId == m.playlists[p.id]!.playlistId })
                #expect(row.name == p.name && row.sequenceNo == m.playlists[p.id]!.sequenceNo)
                #expect(row.parentId == m.playlists[p.id]!.parentPlaylistId)
                #expect(row.contentIds == p.trackIds.compactMap { m.tracks[$0]?.contentId })
            }
        }
        h.setPlaylist("P1", "One", parent: "F", ["B", "A"])
        try expectOnly(.pending([.contents]), for: "P1")
        h.setPlaylist("P1", "One (renamed)", parent: "F", ["B", "A"])
        try expectOnly(.pending([.name]), for: "P1")
        h.setPlaylist("F", "Folder (renamed)", folder: true)
        try expectOnly(.pending([.name]), for: "F")
        h.setPlaylist("P2", "Two", parent: "F", ["A"])
        try expectOnly(.pending([.parent]), for: "P2")
        h.library.playlists.swapAt(1, 2)   // P2 before P1 inside the folder
        let c = try h.evaluate()
        #expect(c.playlists.filter { $0.status != .clean }.count == 2)
        try h.sync()
    }

    // 7
    @Test func overlappingPlaylistsAndDeletedPlaylist() throws {
        let h = try synced(["A", "B"])
        h.setPlaylist("P2", "Two", ["B"])
        try h.select(["P1", "P2"])
        let add = try h.sync()
        #expect(add.before.summary.playlistsToCreate == 1 && add.before.summary.pending == 0 && add.result.copied.isEmpty)
        try h.select(["P1"])
        let remove = try h.sync()
        #expect(remove.before.removedPlaylists.map(\.name) == ["Two"] && remove.before.removedTracks.isEmpty)

        // P1 deleted in Music: dropped from the selection, its tracks and playlist removed.
        let paths = try h.manifest().tracks.values.map(\.usbPath)
        h.library.playlists.removeAll { $0.id == "P1" }
        let gone = try h.sync()
        #expect(gone.before.drive.contains(.selection))
        #expect(gone.before.summary.toRemove == 2)
        #expect(try h.manifest().selectedPlaylistIds.isEmpty)
        #expect(paths.allSatisfy { !h.exists($0) })
    }

    // 8
    @Test func duplicates() throws {
        let h = try SyncHarness()
        for id in ["A", "B"] { try h.addTrack(id); try h.analyze(id) }
        try h.addTrack("A2", title: "Song A", audio: "A")   // same audio and name as A
        h.setPlaylist("P1", "One", ["A", "B", "A", "A2"])
        h.setPlaylist("P2", "Two", ["A"])
        try h.select(["P1", "P2"])
        let run = try h.sync()
        #expect(Set(run.result.copied) == ["A", "B", "A2"])
        #expect(Set(try h.manifest().tracks.values.map(\.usbPath)).count == 2)    // A and A2 share a file
        let m = try h.manifest()
        #expect(m.tracks["A"]!.usbPath == m.tracks["A2"]!.usbPath && m.tracks["A"]!.contentId != m.tracks["A2"]!.contentId)
        let one = try #require(try h.database().playlists.first { $0.name == "One" })
        #expect(one.contentIds == [m.tracks["A"]!.contentId, m.tracks["B"]!.contentId, m.tracks["A"]!.contentId, m.tracks["A2"]!.contentId])
        h.setPlaylist("P1", "One", ["A", "B", "A2"])
        let dedup = try h.sync()
        #expect(dedup.before.removedTracks.isEmpty)
        // Dropping A2 leaves the shared file for A.
        h.setPlaylist("P1", "One", ["A", "B"])
        let drop = try h.sync()
        #expect(drop.before.removedTracks.map(\.id) == ["A2"] && drop.result.removed.isEmpty)
        #expect(h.exists(m.tracks["A"]!.usbPath))
    }

    // 9
    @Test func unavailableSourcesAreRetainedOrIneligible() throws {
        let h = try synced(["A", "B"])
        let m = try h.manifest()
        // A's file disappears (external disk unmounted, file moved, offloaded).
        try FileManager.default.moveItem(at: h.file("A"), to: h.root.appendingPathComponent("A-away.mp3"))
        // Never-synced tracks that can't be read, and an unsupported format.
        try h.addTrack("C")
        try FileManager.default.removeItem(at: h.file("C"))
        try h.addTrack("D")
        h.library.tracks["D"]!.location = nil
        h.library.tracks["D"]!.unavailableReason = "Protected (DRM) track; no exportable local file"
        try h.addTrack("E", ext: "ogg")
        h.setPlaylist("P1", "One", ["A", "B", "C", "D", "E"])
        let c = try h.evaluate()
        #expect(c.track("A")?.status == .retained("Local file is missing: \(h.file("A").path)"))
        for id in ["C", "D", "E"] {
            guard case .ineligible = c.track(id)!.status else { Issue.record("\(id) should be ineligible"); continue }
        }
        #expect(c.isClean && c.summary.pending == 0)

        // Retained tracks still take metadata edits; nothing of theirs is deleted.
        h.edit("A") { $0.title = "Offline but renamed" }
        let run = try h.sync()
        #expect(run.result.removed.isEmpty)
        #expect(h.exists(m.tracks["A"]!.usbPath) && FileManager.default.fileExists(atPath: h.anlz(m.tracks["A"]!.usbPath).path))
        let db = try h.database()
        #expect(db.tracks[m.tracks["A"]!.contentId]?.title == "Offline but renamed")
        #expect(db.playlists[0].contentIds == [m.tracks["A"]!.contentId, m.tracks["B"]!.contentId])

        // Back again: same copy, nothing to do.
        try FileManager.default.moveItem(at: h.root.appendingPathComponent("A-away.mp3"), to: h.file("A"))
        #expect(try h.evaluate().track("A")?.status == .clean)

        // Unavailable and gone from the drive too: forgotten, not deleted.
        try FileManager.default.removeItem(at: h.file("B"))
        try FileManager.default.removeItem(at: h.volume.url(forUsbPath: m.tracks["B"]!.usbPath))
        let lost = try h.sync()
        #expect(lost.before.removedTracks.map(\.reason) == [.lost] && lost.result.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.anlz(m.tracks["B"]!.usbPath).path))
    }

    // 10
    @Test func analyzedAfterSyncAndRecordedFailures() throws {
        let h = try SyncHarness()
        try h.addTrack("A"); try h.analyze("A")
        try h.addTrack("B")
        h.setPlaylist("P1", "One", ["A", "B"])
        try h.select(["P1"])
        let first = try h.sync()
        #expect(first.before.track("B")?.changes == [.new])
        let usbB = try h.manifest().tracks["B"]!.usbPath
        #expect(!FileManager.default.fileExists(atPath: h.anlz(usbB).path))

        try h.analyze("B")
        let later = try h.sync()
        #expect(later.before.track("B")?.changes == [.analysisFiles, .record])
        #expect(later.result.anlzWritten == ["B"])
        #expect(try h.database().tracks[try h.manifest().tracks["B"]!.contentId]?.durationSeconds == 20)

        // The analyzer fails on C (not real audio): recorded, not retried, not pending.
        try h.addTrack("C")
        h.setPlaylist("P1", "One", ["A", "B", "C"])
        h.analyzeMissing = true
        let failing = try h.sync()
        #expect(failing.result.analysisFailed == ["C"])
        guard case .failed = failing.after.track("C")!.status else { Issue.record("C should show as failed"); return }
        #expect(try h.evaluate().isClean)
        let retry = h.planner.plan(volume: h.volume, manifest: try h.manifest(), profile: h.profile, retryFailedAnalysis: true)
        #expect(retry.track("C")?.changes == [.analyze])
    }

    // 11
    @Test func repairsMissingFiles() throws {
        let h = try synced(["A", "B"])
        let m = try h.manifest()
        let a = m.tracks["A"]!.usbPath, b = m.tracks["B"]!.usbPath
        for ext in ["DAT", "EXT", "2EX"] {
            let original = try Data(contentsOf: h.anlz(a, ext))
            try FileManager.default.removeItem(at: h.anlz(a, ext))
            let run = try h.sync()
            #expect(run.before.track("A")?.changes == [.analysisFiles])
            #expect(run.result.anlzWritten == ["A"] && !run.result.wroteDatabase)
            #expect(try Data(contentsOf: h.anlz(a, ext)) == original)
        }
        try FileManager.default.removeItem(at: h.volume.url(forUsbPath: b))
        let audio = try h.sync()
        #expect(audio.before.track("B")?.changes == [.missingOnDrive] && audio.result.copied == ["B"])
        #expect(!audio.result.wroteDatabase)

        try FileManager.default.removeItem(at: h.dbURL)
        let db = try h.sync()
        #expect(db.before.drive == [.databaseMissing] && db.result.wroteDatabase)
    }

    // 12
    @Test func changedSourceAudioMovesToANewPath() throws {
        let h = try synced(["A"])
        let old = try h.manifest().tracks["A"]!
        try h.writeAudio(h.file("A"), audio: "A remastered")
        try h.analyze("A")
        let run = try h.sync()
        #expect(run.before.track("A")?.changes.contains(.audioChanged) == true)
        let new = try h.manifest().tracks["A"]!
        #expect(new.usbPath != old.usbPath && new.contentId == old.contentId)
        #expect(!h.exists(old.usbPath) && h.exists(new.usbPath))
        #expect(!FileManager.default.fileExists(atPath: h.anlz(old.usbPath).deletingLastPathComponent().path))
        #expect(run.result.removed == [old.usbPath])
    }

    // 13
    @Test func unknownFactsAreNeitherSyncedNorPending() throws {
        let h = try synced(["A", "B"])
        try h.addTrack("C")
        h.setPlaylist("P1", "One", ["A", "B", "C"])
        let m = try h.manifest()
        var facts = h.planner.facts(for: ["A", "B", "C"], manifest: m)
        facts["A"] = TrackFacts(audio: .unknown)
        facts["C"] = TrackFacts(audio: .unknown)
        let c = SyncStatus.evaluate(library: h.library, manifest: m, facts: facts, drive: DriveProbe.scan(h.volume, manifest: m),
                                    profile: h.profile)
        #expect(c.track("A")?.status == .unknown && c.track("C")?.status == .unknown)
        #expect(c.summary.pending == 0 && c.summary.unknown == 2 && c.removedTracks.isEmpty)
        #expect(c.playlists[0].status == .unknown && !c.isComplete)
        #expect(throws: SyncError.self) { try h.executor().execute(c, on: h.volume) }
    }

    // 14
    @Test func entireLibraryWithUnsyncableSongs() throws {
        let h = try synced(["A"])
        try h.addTrack("B"); try h.analyze("B")
        try h.addTrack("X", ext: "ogg")
        try h.addTrack("Z")
        h.library.tracks["Z"]!.location = nil
        h.library.tracks["Z"]!.unavailableReason = "Apple Music / iCloud track with no downloaded local file"
        h.library.allTrackIds = ["A", "B", "X", "Z"]
        try h.select(["P1"], entireLibrary: true)
        let on = try h.sync()
        #expect(on.before.summary.toCopy == 1 && on.before.summary.ineligible == 2)
        #expect(on.after.summary.ineligible == 2 && on.after.isClean)
        #expect(try h.manifest().tracks.keys.sorted() == ["A", "B"])
        try h.select(["P1"], entireLibrary: false)
        let off = try h.sync()
        #expect(off.before.removedTracks.map(\.id) == ["B"])
    }

    // 15
    @Test func settingsAndRecipeChanges() throws {
        let h = try synced(["A", "B"])
        // Cues off: every analysis file checked and rewritten (their cues differ).
        h.settings.cues = .none
        let cues = try h.sync()
        #expect(cues.before.drive == [.settings] && cues.before.summary.analysisFiles == 2)
        #expect(Set(cues.result.anlzWritten) == ["A", "B"] && !cues.result.wroteDatabase)
        // Key format: database rows change, analysis files don't.
        h.settings.keyFormat = .alphanumeric
        let keys = try h.sync()
        #expect(keys.before.summary.records == 2 && keys.before.summary.analysisFiles == 0 && keys.result.wroteDatabase)
        // Track colour.
        h.settings.trackColor = .none
        let colors = try h.sync()
        #expect(colors.before.summary.records == 2)
        // A recipe bump (here: inputs recorded by another recipe) checks every track, rewriting nothing that's the same.
        var m = try h.manifest()
        for id in m.tracks.keys { m.tracks[id]!.anlzInputs = "d:otherrecipe" }
        try Manifest.update(on: h.volume, basedOn: try h.manifest()) { $0 = m }
        let files = h.snapshot()
        let recipe = try h.sync()
        #expect(recipe.before.summary.analysisFiles == 2 && recipe.result.anlzWritten.isEmpty && !recipe.result.wroteDatabase)
        #expect(h.snapshot().filter { $0.key.contains("USBANLZ") } == files.filter { $0.key.contains("USBANLZ") })
        // Phrases off changes the files.
        h.settings.phrases = false
        let phrases = try h.sync()
        #expect(Set(phrases.result.anlzWritten) == ["A", "B"])
    }

    // 16
    @Test func legacyManifestIsConvertedOnceWithoutRecopying() throws {
        let h = try synced(["A", "B"])
        let files = h.snapshot()
        // Rewrite the manifest as an older Deckhand (DJTEST) left it: one file, no generation, full fingerprints,
        // a dropped setting, no record fingerprints, sizes or database id.
        let m = try h.manifest()
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder.iso.encode(m)) as! [String: Any]
        json.removeValue(forKey: "generation")
        json.removeValue(forKey: "databaseId")
        var settings = json["settings"] as! [String: String]
        settings["cueSource"] = "deckhand"
        json["settings"] = settings
        var tracks = json["tracks"] as! [String: [String: Any]]
        let cache = h.cache
        for (id, var t) in tracks {
            for k in ["recordFingerprint", "fileSize", "metadataFingerprint", "anlzInputs", "artworkKey"] { t.removeValue(forKey: k) }
            t["analysisVersion"] = 5
            // The full fingerprint string, as older versions stored it, from an older analysis version whose files
            // came out the same (as on DJTEST).
            let hash = t["contentHash"] as! String
            let built = SyncExecutor.anlzContent(analysis: cache.analysis(forHash: hash)!, sections: cache.sections(forHash: hash),
                                                 detected: cache.detectedCues(forHash: hash), profile: h.profile)
            t["anlzFingerprint"] = "v5" + built.fingerprint.drop { $0 != ";" }
            tracks[id] = t
        }
        json["tracks"] = tracks
        for u in Manifest.urls(root: h.drive) { try? FileManager.default.removeItem(at: u) }
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        try legacyData.write(to: Manifest.urls(root: h.drive)[0])

        let c = try h.evaluate()
        #expect(c.drive == [.legacyManifest, .databaseChanged])
        #expect(c.summary.records == 2 && c.summary.toCopy == 0)
        let run = try h.sync()
        #expect(run.result.copied.isEmpty && run.result.anlzWritten.isEmpty && Set(run.result.anlzChecked) == ["A", "B"])
        // Saved to the other file; the old one is left as it was.
        #expect(try Data(contentsOf: Manifest.urls(root: h.drive)[0]) == legacyData)
        #expect(try h.manifest().generation == 1)
        let after = h.snapshot()
        #expect(files.filter { $0.key.hasPrefix("/Contents") || $0.key.contains("USBANLZ") }
            == after.filter { $0.key.hasPrefix("/Contents") || $0.key.contains("USBANLZ") })
    }

    // 17
    @Test func adoptsExistingAudio() throws {
        let h = try SyncHarness()
        try h.addTrack("A"); try h.analyze("A")
        try h.addTrack("B"); try h.analyze("B")
        let existing = h.drive.appendingPathComponent("Contents/Old Artist")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: h.file("A"), to: existing.appendingPathComponent("a-old.mp3"))
        let adoptable = AdoptScanner.scan(h.volume, owned: [], cache: h.cache)
        h.setPlaylist("P1", "One", ["A", "B"])
        try h.select(["P1"])
        let run = try h.sync(adoptable: adoptable)
        #expect(run.before.track("A")?.changes.contains(.adopt) == true && run.before.track("B")?.changes.contains(.new) == true)
        #expect(run.before.bytesToCopy == FileOps.size(h.file("B")))
        #expect(run.result.adopted == ["A"] && run.result.copied == ["B"])
        #expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("a-old.mp3").path))
    }

    // 17
    @Test func recoversFromASyncCutShortAfterTheDatabaseSwap() throws {
        let h = try synced(["A"])
        let manifestFiles = try Manifest.urls(root: h.drive).map { try? Data(contentsOf: $0) }
        for id in ["B", "C"] { try h.addTrack(id); try h.analyze(id) }
        h.setPlaylist("P1", "One", ["A", "B", "C"])
        try h.sync()
        let ids = try h.manifest().tracks.mapValues(\.contentId)
        // As if the sync had stopped after replacing the database: its audio and analysis files are there, but
        // the manifest is the one from before.
        for (u, data) in zip(Manifest.urls(root: h.drive), manifestFiles) {
            if let data { try data.write(to: u) } else { try? FileManager.default.removeItem(at: u) }
        }
        // And the playlist order changed since, so fresh content IDs would come out the other way round.
        h.setPlaylist("P1", "One", ["A", "C", "B"])
        let c = try h.evaluate()
        #expect(c.drive.contains(.databaseChanged))
        #expect(c.track("B")?.changes.contains(.adopt) == true && c.bytesToCopy == 0)
        let run = try h.sync()
        #expect(run.result.copied.isEmpty && Set(run.result.adopted) == ["B", "C"])
        #expect(try h.manifest().tracks.mapValues(\.contentId) == ids)
    }

    // 12 (gap): free space counts what will be copied, re-copies included, ineligible excluded.
    @Test func freeSpaceCheckUsesBytesToCopy() throws {
        let h = try synced(["A"])
        try h.addTrack("B"); try h.analyze("B")
        try h.addTrack("X", ext: "ogg")
        try FileManager.default.removeItem(at: h.volume.url(forUsbPath: try h.manifest().tracks["A"]!.usbPath))
        h.setPlaylist("P1", "One", ["A", "B", "X"])
        let c = try h.evaluate()
        #expect(c.bytesToCopy == FileOps.size(h.file("A")) + FileOps.size(h.file("B")))
        h.volume = Volume(testRoot: h.drive, available: c.spaceNeeded - 1)
        #expect(throws: SyncError.self) { try h.executor().execute(c, on: h.volume) }
        h.volume = Volume(testRoot: h.drive, available: c.spaceNeeded)
        try h.sync()
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
