import DeckhandCore
import Foundation
import OneLibrary
import Testing
@testable import Sync

/// Scenario 18: random sequences of library, drive, selection and settings changes. After every sync, evaluating
/// again is clean, the executor did what was planned, the drive's library validates, nothing retained was deleted,
/// and content IDs of tracks that stayed are stable.
@Suite struct SyncPropertyTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func evaluateAfterExecuteIsClean(seed: UInt64) throws {
        var rng = Generator(state: seed)
        let h = try SyncHarness()
        h.useArtwork = true
        let away = h.root.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        var ids = (0..<8).map { "T\($0)" }
        var nextTrack = 8
        var audioVersion: [String: Int] = [:]
        for id in ids {
            try h.addTrack(id)
            if Bool.random(using: &rng) { try h.analyze(id) }
            if Bool.random(using: &rng) { h.art[id] = TestArtwork.png(Double.random(in: 0...1, using: &rng)) }
        }
        h.setPlaylist("F", "Folder", folder: true)
        h.setPlaylist("P0", "Zero", Array(ids.prefix(4)))
        h.setPlaylist("P1", "One", parent: "F", Array(ids[2..<6]))
        h.setPlaylist("P2", "Two", Array(ids.suffix(3)) + [ids[0]])
        h.library.allTrackIds = ids
        try h.select(["P0", "P1"])

        func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
        func available(_ id: String) -> Bool { FileManager.default.fileExists(atPath: h.file(id).path) }

        for step in 0..<25 {
            let context = "seed \(seed) step \(step)"
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let id = pick(ids)
                switch Int.random(in: 0..<20, using: &rng) {
                case 17:
                    // Analysis stops being current (analyzer changed, cache lost).
                    if available(id) { try? FileManager.default.removeItem(at: h.cache.root.appendingPathComponent("analysis/\(try h.hash(id)).json")) }
                case 18:
                    if let art = try h.manifest().artwork?.values.first {
                        try? FileManager.default.removeItem(at: h.volume.url(forUsbPath: ArtworkWriter.path(imageId: art)))
                    }
                case 19:
                    // A duplicate: same audio and name, other tags.
                    guard available(id), let t = h.library.tracks[id] else { break }
                    let dup = "T\(nextTrack)"
                    nextTrack += 1
                    try h.addTrack(dup, title: t.title, artist: t.artist, audio: "x")
                    try FileManager.default.removeItem(at: h.file(dup))
                    try FileManager.default.copyItem(at: h.file(id), to: h.file(dup))
                    try h.writeAudio(h.file(dup), audio: audioVersion[id].map { "\(id)-\($0)" } ?? id, tag: "dup \(dup)")
                    ids.append(dup)
                    h.library.allTrackIds = ids
                    h.library.playlists[Int.random(in: 1..<h.library.playlists.count, using: &rng)].trackIds.append(dup)
                case 0: h.edit(id) { $0.rating = Int.random(in: 0...5, using: &rng) }
                case 1: h.edit(id) { $0.title = "Song \(id) v\(Int.random(in: 0...9, using: &rng))" }
                case 2:
                    guard available(id) else { break }
                    audioVersion[id, default: 0] += 1
                    try h.writeAudio(h.file(id), audio: "\(id)-\(audioVersion[id]!)")
                    if Bool.random(using: &rng) { try h.analyze(id) }
                case 3: if available(id), !h.cache.isAnalyzed(try h.hash(id)) { try h.analyze(id) }
                case 4:
                    if available(id) {
                        try FileManager.default.moveItem(at: h.file(id), to: away.appendingPathComponent(id))
                    } else if FileManager.default.fileExists(atPath: away.appendingPathComponent(id).path) {
                        try FileManager.default.moveItem(at: away.appendingPathComponent(id), to: h.file(id))
                    }
                case 5:
                    if let t = try h.manifest().tracks[id] { try? FileManager.default.removeItem(at: h.volume.url(forUsbPath: t.usbPath)) }
                case 6:
                    if let t = try h.manifest().tracks[id] { try? FileManager.default.removeItem(at: h.anlz(t.usbPath, pick(["DAT", "EXT", "2EX"]))) }
                case 7: try? FileManager.default.removeItem(at: h.dbURL)
                case 8:
                    let i = Int.random(in: 1..<h.library.playlists.count, using: &rng)
                    h.library.playlists[i].trackIds.shuffle(using: &rng)
                case 9:
                    let i = Int.random(in: 1..<h.library.playlists.count, using: &rng)
                    if h.library.playlists[i].trackIds.contains(id), Bool.random(using: &rng) {
                        h.library.playlists[i].trackIds.removeAll { $0 == id }
                    } else {
                        h.library.playlists[i].trackIds.append(id)
                    }
                case 10:
                    let i = Int.random(in: 0..<h.library.playlists.count, using: &rng)
                    h.library.playlists[i].name += "'"
                case 11:
                    let i = Int.random(in: 1..<h.library.playlists.count, using: &rng)
                    h.library.playlists[i].parentId = h.library.playlists[i].parentId == nil ? "F" : nil
                case 12:
                    let p = pick(["P0", "P1", "P2"])
                    var selected = try h.manifest().selectedPlaylistIds
                    if selected.contains(p) { selected.removeAll { $0 == p } } else { selected.append(p) }
                    try h.select(selected, entireLibrary: Int.random(in: 0..<6, using: &rng) == 0 ? !(try h.manifest().entireLibrary ?? false) : nil)
                case 13:
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: h.settings.cues = pick(CueMode.allCases)
                    case 1: h.settings.keyFormat = pick(OneLibraryDatabase.KeyFormat.allCases)
                    case 2: h.settings.trackColor = pick(TrackColorRule.allCases)
                    default: h.settings.phrases.toggle()
                    }
                case 14:
                    h.art[id] = Bool.random(using: &rng) ? TestArtwork.png(Double.random(in: 0...1, using: &rng)) : nil
                    h.edit(id) { _ in }
                case 15:
                    guard available(id) else { break }
                    let handle = try FileHandle(forWritingTo: h.file(id))
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("TAG".utf8) + Data(repeating: 0x20, count: 125))
                    try handle.close()
                default:
                    if Bool.random(using: &rng), ids.count > 3 {
                        // Deleted from Music entirely.
                        h.library.tracks[id] = nil
                        ids.removeAll { $0 == id }
                        for i in h.library.playlists.indices { h.library.playlists[i].trackIds.removeAll { $0 == id } }
                    } else {
                        let new = "T\(nextTrack)"
                        nextTrack += 1
                        try h.addTrack(new)
                        if Bool.random(using: &rng) { try h.analyze(new) }
                        ids.append(new)
                        h.library.playlists[Int.random(in: 1..<h.library.playlists.count, using: &rng)].trackIds.append(new)
                    }
                    h.library.allTrackIds = ids
                }
            }
            h.analyzeMissing = Int.random(in: 0..<4, using: &rng) == 0
            if Int.random(in: 0..<5, using: &rng) == 0 {
                // Unplugged just before the manifest is saved; the next sync recovers.
                var e = h.executor()
                e.stopBeforeManifest = true
                let plan = try h.evaluate()
                if !plan.isClean { _ = try? e.execute(plan, on: h.volume) }
            }

            let before = try h.manifest()
            let run = try h.sync()
            let after = try h.manifest()
            #expect(run.after.isClean, "\(context): \(h.describe(run.after))")
            // Never deleted for being temporarily unavailable: a selected track whose source can't be read stays
            // if its copy was on the drive.
            for t in run.before.tracks where !available(t.id) {
                guard let old = before.tracks[t.id], run.before.probe.hasAudio(old.usbPath) else { continue }
                // Retained (perhaps with metadata or analysis-file work to do).
                guard t.usbPath == old.usbPath, t.unavailableReason != nil else {
                    Issue.record("\(context): \(t.id) unavailable but \(t.status)")
                    continue
                }
                #expect(h.exists(old.usbPath), "\(context): retained \(t.id) deleted")
                #expect(after.tracks[t.id]?.usbPath == old.usbPath, "\(context): retained \(t.id) dropped")
            }
            #expect(run.before.removedTracks.allSatisfy { $0.reason != .deselected || run.before.track($0.id) == nil },
                    "\(context): removed a selected track")
            // Stable content IDs; every recorded file present; the database holds exactly the manifest's tracks.
            for (id, t) in after.tracks {
                if let old = before.tracks[id] { #expect(old.contentId == t.contentId, "\(context): \(id) content ID changed") }
                #expect(h.exists(t.usbPath), "\(context): \(id) audio missing")
            }
            if FileManager.default.fileExists(atPath: h.dbURL.path) {
                let db = try h.database()
                #expect(Set(db.tracks.keys) == Set(after.tracks.values.map(\.contentId)), "\(context): database tracks")
                #expect(Set(db.playlists.map(\.playlistId)) == Set(after.playlists.values.map(\.playlistId)), "\(context): database playlists")
            } else {
                #expect(after.tracks.isEmpty && after.playlists.isEmpty, "\(context): database missing")
            }
        }
    }
}
