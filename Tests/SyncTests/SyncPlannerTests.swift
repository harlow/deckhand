import DeckhandCore
import CryptoKit
import Foundation
import OneLibrary
import Testing
@testable import Sync

@Suite struct SyncPlannerTests {
    func harness(_ house: [String]) throws -> SyncHarness {
        let h = try SyncHarness()
        for id in ["A", "B", "C", "D"] { try h.addTrack(id) }
        h.setPlaylist("house", "House", house)
        try h.select(["house"])
        return h
    }

    @Test func incrementalReorderAddRemove() throws {
        let h = try harness(["A", "B", "C"])
        let first = try h.sync()
        #expect(first.before.tracks.map(\.changes) == [[.new], [.new], [.new]])
        let ids = try h.manifest().tracks

        h.setPlaylist("house", "House", ["C", "A", "D"])
        let second = try h.evaluate()
        #expect(second.track("C")?.status == .clean && second.track("A")?.status == .clean)
        #expect(second.track("D")?.changes == [.new])
        #expect(second.removedTracks.map(\.record.usbPath) == [ids["B"]!.usbPath])
        #expect(second.bytesToCopy == FileOps.size(h.file("D")))
        // IDs are stable and order follows the source.
        let next = second.nextManifest.tracks
        #expect(next["A"]!.contentId == ids["A"]!.contentId)
        #expect(second.playlists.first?.record.contentIds == [next["C"]!.contentId, next["A"]!.contentId, next["D"]!.contentId])
        #expect(second.playlists.first?.status == .pending([.contents]))
        #expect(second.playlists.first?.record.playlistId == first.before.playlists.first?.record.playlistId)
        try h.sync()
    }

    @Test func sharedTrackIsNotRemovedWhileReferenced() throws {
        let h = try harness(["A", "B"])
        h.setPlaylist("disco", "Disco", ["B"])
        try h.select(["house", "disco"])
        try h.sync()
        h.setPlaylist("house", "House", ["A"])
        let second = try h.evaluate()
        #expect(second.removedTracks.isEmpty)
        #expect(second.tracks.allSatisfy { $0.status == .clean })
        try h.sync()
    }

    @Test func missingAndChangedFiles() throws {
        let h = try harness(["A", "B"])
        try h.sync()
        let first = try h.manifest()
        // Deleted from the drive behind Deckhand's back → recopied.
        try FileManager.default.removeItem(at: h.volume.url(forUsbPath: first.tracks["A"]!.usbPath))
        // Source audio changed → replaced at a new path, old file removed.
        try h.writeAudio(h.file("B"), audio: "new audio B")
        let second = try h.evaluate()
        #expect(second.track("A")?.changes == [.missingOnDrive])
        #expect(second.track("B")?.changes.contains(.audioChanged) == true)
        #expect(second.track("B")?.usbPath != first.tracks["B"]!.usbPath)
        #expect(second.removedTracks.map(\.record.usbPath) == [first.tracks["B"]!.usbPath])
        try h.sync()
    }

    @Test func ineligibleTracksAreReported() throws {
        let h = try harness(["A", "B"])
        h.library.tracks["B"]!.location = nil
        h.library.tracks["B"]!.unavailableReason = "Protected (DRM) track; no exportable local file"
        let plan = try h.evaluate()
        #expect(plan.tracks.filter(\.isPlaced).map(\.id) == ["A"])
        #expect(plan.track("B")?.status == .ineligible("Protected (DRM) track; no exportable local file"))
        #expect(plan.summary.ineligible == 1 && plan.summary.pending == 1)
    }

    @Test func sanitizesFileNames() {
        #expect(SyncPlanner.sanitize("AC/DC: Back? <In> \"Black\"") == "AC_DC_ Back_ _In_ _Black_")
        #expect(SyncPlanner.sanitize("...") == "Track")
    }

    @Test func entireLibraryAddsEverySongButOnlySelectedPlaylists() throws {
        let h = try harness(["A", "B"])
        h.library.allTrackIds = ["A", "B", "C", "D"]
        let songsOnly = try h.evaluate(selection: Selection(playlistIds: [], entireLibrary: true))
        #expect(songsOnly.tracks.map(\.id) == ["A", "B", "C", "D"])
        #expect(songsOnly.nextManifest.entireLibrary == true)
        #expect(songsOnly.playlists.isEmpty)

        let whole = try h.evaluate(selection: Selection(playlistIds: ["house"], entireLibrary: true))
        #expect(whole.tracks.map(\.id) == ["A", "B", "C", "D"])
        #expect(whole.playlists.map(\.source.name) == ["House"])

        let selected = try h.evaluate()
        #expect(selected.tracks.map(\.id) == ["A", "B"])
    }

    @Test func entireLibraryWithoutAllSongsLoadedRemovesNothing() throws {
        let h = try harness(["A"])
        h.library.allTrackIds = ["A", "B"]
        try h.select(["house"], entireLibrary: true)
        try h.sync()
        h.library.allTrackIds = nil
        let c = try h.evaluate()
        #expect(c.removedTracks.isEmpty && !c.isComplete)
        #expect(c.nextManifest.tracks["B"] != nil)
    }

    @Test func avoidsAnalysisPathCollisions() throws {
        // Find titles for tracks A and B whose Deckhand paths (which embed each track's real audio
        // fingerprint) hash to the same ANLZ directory. Varied names are needed: near-identical strings
        // spread perfectly under this hash.
        let h = try harness(["A", "B"])
        let hashA = try h.hash("A"), hashB = try h.hash("B")
        func title(_ i: Int) -> String {
            "Track " + String(Insecure.MD5.hash(data: Data(String(i).utf8)).map { String(format: "%02x", $0) }.joined().prefix(10))
        }
        func dir(_ title: String, _ hash: String) -> String {
            OneLibrary.AnlzPath.directory(forAudioPath: SyncPlanner.usbPath(
                for: SourceTrack(id: "x", title: title, artist: "A"), file: URL(fileURLWithPath: "/x.mp3"), hash: hash))
        }
        var aDirs: [String: String] = [:]
        for i in 0..<2000 { aDirs[dir(title(i), hashA)] = title(i) }
        var pair: (String, String)?
        for j in 2000..<200_000 where pair == nil {
            if let t1 = aDirs[dir(title(j), hashB)] { pair = (t1, title(j)) }
        }
        let (t1, t2) = try #require(pair)
        h.library.tracks["A"]!.title = t1
        h.library.tracks["A"]!.artist = "A"
        h.library.tracks["B"]!.title = t2
        h.library.tracks["B"]!.artist = "A"
        let plan = try h.evaluate()
        let dirs = plan.tracks.map { OneLibrary.AnlzPath.directory(forAudioPath: $0.usbPath!) }
        #expect(Set(dirs).count == plan.tracks.count)
    }

    @Test func analysisVersionChangeDoesNotRecopyAudio() throws {
        let h = try harness(["A", "B"])
        try h.sync()
        var m = try h.manifest()
        for id in m.tracks.keys { m.tracks[id]!.analysisVersion = TrackAnalysis.currentVersion - 1 }
        try Manifest.update(on: h.volume, basedOn: try h.manifest()) { $0 = m }
        let second = try h.evaluate()
        #expect(second.isClean && second.bytesToCopy == 0)
    }
}
