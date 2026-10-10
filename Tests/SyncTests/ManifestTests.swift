import Foundation
import Testing
@testable import Sync

@Suite struct ManifestFileTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")

    func manifest(nextContentId: Int, generation: Int? = nil) -> Manifest {
        var m = Manifest()
        m.nextContentId = nextContentId
        m.generation = generation
        return m
    }

    @Test func savesAlternateFilesAndLoadsTheNewest() throws {
        var m = manifest(nextContentId: 1)
        for id in 2...4 {
            try m.save(root: root)
            m = try #require(try Manifest.load(root: root))
            m.nextContentId = id
        }
        let loaded = try #require(try Manifest.load(root: root))
        #expect(loaded.nextContentId == 3 && loaded.generation == 3)
        #expect(Manifest.urls(root: root).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func fallsBackWhenTheNewestIsCorrupt() throws {
        try manifest(nextContentId: 7, generation: 0).save(root: root)  // generation 1 → manifest.json
        try manifest(nextContentId: 8, generation: 1).save(root: root)  // generation 2 → manifest-b.json
        try Data("{\"truncat".utf8).write(to: Manifest.urls(root: root)[1])
        #expect(try Manifest.load(root: root)?.nextContentId == 7)
    }

    @Test func loadsAnOlderSingleFileManifest() throws {
        let url = Manifest.urls(root: root)[0]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"format":1,"createdAt":"2026-10-07T19:00:53Z","deviceId":"X","nextContentId":5,"nextPlaylistId":1,"selectedPlaylistIds":[],"tracks":{},"playlists":{}}"#.utf8).write(to: url)
        let m = try #require(try Manifest.load(root: root))
        #expect(m.nextContentId == 5 && m.generation == nil)
    }

    @Test func digestsMatchFullAndDigestedFingerprints() {
        let full = "v6;pqt2=false;cues=m@49:Energy 5"
        #expect(Manifest.matches(full, full))
        #expect(Manifest.matches(Manifest.digest(full), full))
        #expect(!Manifest.matches(Manifest.digest(full), full + "x"))
        #expect(!Manifest.matches(nil, full))
    }
}
