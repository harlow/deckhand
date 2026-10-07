import DeckhandCore
import Foundation
import Testing
@testable import OneLibrary

@Suite struct OneLibraryDatabaseTests {
    static func sampleContents() -> OneLibraryDatabase.Contents {
        let tracks = (1...3).map { i in
            ExportTrack(contentId: i, title: "Track \(i)", artist: "Artist", album: "Album", genre: "House",
                        durationSeconds: 300, bpm: 124.5, key: MusicalKey(tonic: 9, mode: .minor), color: .red,
                        usbPath: "/Contents/Deckhand/t\(i).mp3", fileSize: 1000, fileType: .mp3,
                        bitrateKbps: 320, sampleRate: 44100, analysisPath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT")
        }
        let playlists = [
            ExportPlaylist(playlistId: 1, name: "DJ", isFolder: true, sequenceNo: 1),
            ExportPlaylist(playlistId: 2, name: "Friday", parentId: 1, sequenceNo: 1, contentIds: [3, 1, 2]),
        ]
        return .init(tracks: tracks, playlists: playlists)
    }

    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("exportLibrary.db")

        try OneLibraryDatabase.write(Self.sampleContents(), to: path)

        // Unreadable without the key.
        let header = try Data(contentsOf: path).prefix(16)
        #expect(header != Data("SQLite format 3\0".utf8))

        let db = try OneLibraryDatabase.open(path)
        let order = try db.query("SELECT content_id FROM playlist_content WHERE playlist_id = 2 ORDER BY sequenceNo")
        #expect(order.compactMap { if case .int(let v) = $0["content_id"] { v } else { nil } } == [Int64(3), 1, 2])
        let rows = try db.query("SELECT bpmx100, k.name AS key FROM content c JOIN key k ON c.key_id = k.key_id WHERE content_id = 1")
        guard case .int(let bpm) = rows.first?["bpmx100"], case .text(let key) = rows.first?["key"] else {
            Issue.record("missing row"); return
        }
        #expect(bpm == 12450)
        #expect(key == "Am")
    }

    @Test func refusesOverwrite() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(throws: OneLibraryError.self) { try OneLibraryDatabase.write(Self.sampleContents(), to: path) }
    }

    @Test func carriesPlayerHistoryAcrossRebuilds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.db")
        try OneLibraryDatabase.write(Self.sampleContents(), to: first)
        do {
            // Simulate the player recording a set.
            let db = try OneLibraryDatabase.open(first)
            try db.execute("INSERT INTO history VALUES (1, 1, 'HISTORY 001', 0, 0)")
            try db.execute("INSERT INTO history_content VALUES (1, 2, 1), (1, 3, 2)")
            try db.execute("UPDATE content SET djPlayCount = 4 WHERE content_id = 2")
        }

        var next = Self.sampleContents()
        next.tracks.removeAll { $0.contentId == 3 }
        next.playlists[1].contentIds = [1, 2]
        let second = dir.appendingPathComponent("b.db")
        try OneLibraryDatabase.write(next, to: second, previous: first)

        let db = try OneLibraryDatabase.open(second)
        #expect(try db.query("SELECT name FROM history").first?["name"]?.string == "HISTORY 001")
        #expect(try db.query("SELECT content_id FROM history_content").compactMap { $0["content_id"]?.int } == [2])
        #expect(try db.query("SELECT djPlayCount FROM content WHERE content_id = 2").first?["djPlayCount"]?.int == 4)
    }

    @Test func journalIsCheckpointed() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: path) }
        try OneLibraryDatabase.write(Self.sampleContents(), to: path)
        #expect(!FileManager.default.fileExists(atPath: path.path + "-wal"))
    }

    /// Compares our schema with a Rekordbox export when one is available locally (not committed).
    @Test func schemaMatchesGoldenExport() throws {
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/private/golden-rats/exportLibrary.db")
        guard FileManager.default.fileExists(atPath: golden.path) else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: path) }
        try OneLibraryDatabase.write(Self.sampleContents(), to: path)
        func schema(_ u: URL) throws -> Set<String> {
            Set(try OneLibraryDatabase.open(u).query("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL")
                .compactMap { $0["sql"]?.string?.replacingOccurrences(of: " ", with: "") })
        }
        #expect(try schema(path) == schema(golden))
    }
}
