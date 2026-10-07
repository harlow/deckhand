import DeckhandCore
import Foundation
import OneLibrary
import Testing
@testable import Sync

@Suite struct SyncPlannerTests {
    let root: URL
    let source: URL
    let drive: URL
    let cache: AnalysisCache

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("music")
        drive = root.appendingPathComponent("DRIVE")
        for d in [source, drive] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for name in ["A", "B", "C", "D"] {
            try Data("audio \(name)".utf8).write(to: source.appendingPathComponent("\(name).mp3"))
        }
        cache = try AnalysisCache(root: root.appendingPathComponent("cache"))
    }

    func library(_ house: [String], extra: [SourcePlaylist] = []) -> SourceLibrary {
        let tracks = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D"].map {
            ($0, SourceTrack(id: $0, title: "Song \($0)", artist: "Artist", location: source.appendingPathComponent("\($0).mp3")))
        })
        return SourceLibrary(playlists: [SourcePlaylist(id: "house", name: "House", trackIds: house)] + extra, tracks: tracks)
    }

    /// Simulates a completed sync: files present on the "drive" with analysis files.
    func materialize(_ plan: SyncPlan) throws {
        for t in plan.tracks {
            let audio = plan.volume.url(forUsbPath: t.usbPath)
            try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: t.sourceFile, to: audio)
            let anlz = plan.volume.url(forUsbPath: AnlzPath.directory(forAudioPath: t.usbPath) + "/ANLZ0000.DAT")
            try FileManager.default.createDirectory(at: anlz.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: anlz)
        }
    }

    @Test func incrementalReorderAddRemove() throws {
        let volume = Volume(testRoot: drive)
        let first = try SyncPlanner(library: library(["A", "B", "C"]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house"], previous: Manifest())
        #expect(first.tracks.map(\.action) == [.add, .add, .add])
        try materialize(first)

        let second = try SyncPlanner(library: library(["C", "A", "D"]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house"], previous: first.manifest)
        let actions = Dictionary(uniqueKeysWithValues: second.tracks.map { ($0.source.id, $0.action) })
        #expect(actions == ["C": .unchanged, "A": .unchanged, "D": .add])
        #expect(second.removedTracks.map(\.usbPath) == [first.manifest.tracks["B"]!.usbPath])
        #expect(second.bytesToCopy == FileOps.size(source.appendingPathComponent("D.mp3")))

        // IDs are stable and order follows the source.
        let ids = second.manifest.tracks
        #expect(ids["A"]!.contentId == first.manifest.tracks["A"]!.contentId)
        #expect(second.playlists.first?.contentIds == [ids["C"]!.contentId, ids["A"]!.contentId, ids["D"]!.contentId])
        #expect(second.playlists.first?.action == .change)
        #expect(second.playlists.first?.playlistId == first.playlists.first?.playlistId)
    }

    @Test func sharedTrackIsNotRemovedWhileReferenced() throws {
        let volume = Volume(testRoot: drive)
        let disco = SourcePlaylist(id: "disco", name: "Disco", trackIds: ["B"])
        let first = try SyncPlanner(library: library(["A", "B"], extra: [disco]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house", "disco"], previous: Manifest())
        #expect(first.tracks.count == 2)
        try materialize(first)

        let second = try SyncPlanner(library: library(["A"], extra: [disco]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house", "disco"], previous: first.manifest)
        #expect(second.removedTracks.isEmpty)
        #expect(!second.hasChanges || second.playlists.contains { $0.action == .change })
    }

    @Test func missingAndChangedFiles() throws {
        let volume = Volume(testRoot: drive)
        let first = try SyncPlanner(library: library(["A", "B"]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house"], previous: Manifest())
        try materialize(first)

        // Deleted from the drive behind Deckhand's back → recopied.
        try FileManager.default.removeItem(at: volume.url(forUsbPath: first.manifest.tracks["A"]!.usbPath))
        // Source audio changed → replaced at a new path, old file removed.
        try Data("new audio B".utf8).write(to: source.appendingPathComponent("B.mp3"))

        let second = try SyncPlanner(library: library(["A", "B"]), cache: cache)
            .plan(volume: volume, selectedPlaylistIds: ["house"], previous: first.manifest)
        let byId = Dictionary(uniqueKeysWithValues: second.tracks.map { ($0.source.id, $0) })
        #expect(byId["A"]?.action == .replace)
        #expect(byId["B"]?.action == .replace)
        #expect(byId["B"]?.usbPath != first.manifest.tracks["B"]!.usbPath)
        #expect(second.removedTracks.map(\.usbPath) == [first.manifest.tracks["B"]!.usbPath])
    }

    @Test func ineligibleTracksAreReported() throws {
        var lib = library(["A", "B"])
        lib.tracks["B"]!.location = nil
        lib.tracks["B"]!.unavailableReason = "Protected (DRM) track; no exportable local file"
        let plan = try SyncPlanner(library: lib, cache: cache)
            .plan(volume: Volume(testRoot: drive), selectedPlaylistIds: ["house"], previous: Manifest())
        #expect(plan.tracks.map(\.source.id) == ["A"])
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason.contains("DRM") == true)
    }

    @Test func sanitizesFileNames() {
        #expect(SyncPlanner.sanitize("AC/DC: Back? <In> \"Black\"") == "AC_DC_ Back_ _In_ _Black_")
        #expect(SyncPlanner.sanitize("...") == "Track")
    }
}
