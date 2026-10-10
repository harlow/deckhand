import Foundation
import OneLibrary
import Testing
@testable import Sync

@Suite struct DriveProbeTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")

    func touch(_ usbPath: String, _ bytes: Int = 1) throws {
        let url = root.appendingPathComponent(String(usbPath.dropFirst()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    /// FAT drives list names decomposed (NFD) whatever was written, and match case-insensitively; Deckhand's paths
    /// are precomposed (NFC).
    @Test func matchesPathsTheWayFATDoes() throws {
        let nfc = "/Contents/Deckhand/ab/Beyoncé - Déjà Vu [ab12cd34].mp3"
        try touch(nfc.decomposedStringWithCanonicalMapping)
        let anlz = AnlzPath.directory(forAudioPath: nfc)
        for name in ["anlz0000.dat", "ANLZ0000.EXT", "Anlz0000.2ex"] { try touch(anlz.lowercased() + "/" + name) }
        try touch("/Contents/Deckhand/ab/._junk.mp3")
        try touch("/Contents/Deckhand/ab/.deckhand-tmp-partial.mp3")
        try touch("/PIONEER/Artwork/00001/b1.jpg")
        try touch("/Contents/Other/old.mp3", 1234)
        try touch("/PIONEER/rekordbox/exportLibrary.db", 32)

        var m = Manifest()
        m.tracks["X"] = .init(contentId: 1, usbPath: "/Contents/Other/old.mp3", contentHash: "h", analysisVersion: 6)
        let p = DriveProbe.scan(Volume(testRoot: root), manifest: m)
        #expect(p.hasAudio(nfc) && p.hasAudio(nfc.uppercased()))
        #expect(p.hasAllAnlz(forAudio: nfc))
        #expect(!p.hasAudio("/Contents/Deckhand/ab/._junk.mp3") && !p.hasAudio("/Contents/Deckhand/ab/.deckhand-tmp-partial.mp3"))
        #expect(p.hasImage("/PIONEER/Artwork/00001/b1.jpg"))
        // Outside Deckhand's folder: checked one by one; sizes read for records without one.
        #expect(p.hasAudio("/Contents/Other/old.mp3") && p.size("/Contents/Other/old.mp3") == 1234)
        #expect(p.databaseId == String(repeating: "00", count: 16))
    }

    @Test func incompleteAnalysisFolders() throws {
        let path = "/Contents/Deckhand/cd/Track [cd12ab34].mp3"
        try touch(path)
        let dir = AnlzPath.directory(forAudioPath: path)
        try touch(dir + "/ANLZ0000.DAT")
        try touch(dir + "/ANLZ0000.EXT")
        let p = DriveProbe.scan(Volume(testRoot: root), manifest: nil)
        #expect(!p.hasAllAnlz(forAudio: path) && p.databaseId == nil)
    }

    @Test func databaseIdChangesWithEveryWrite() throws {
        let a = root.appendingPathComponent("a.db"), b = root.appendingPathComponent("b.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try OneLibraryDatabase.write(.init(tracks: [], playlists: []), to: a)
        try OneLibraryDatabase.write(.init(tracks: [], playlists: []), to: b)
        let idA = try #require(OneLibraryDatabase.fileId(a))
        #expect(idA != OneLibraryDatabase.fileId(b))
    }
}
