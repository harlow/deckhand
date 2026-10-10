import DeckhandCore
import Foundation
import Testing

@Suite struct RatingsBackupTests {
    private func track(_ id: String, _ title: String, rating: Int? = nil, path: String? = nil, seconds: Double = 300) -> SourceTrack {
        SourceTrack(id: id, title: title, artist: "Artist", rating: rating, durationSeconds: seconds,
                    location: path.map { URL(fileURLWithPath: $0) })
    }

    @Test func keepsOnlyRatedTracks() {
        let b = RatingsBackup(tracks: [track("A", "One", rating: 4), track("B", "Two")])
        #expect(b.entries.map(\.id) == ["A"])
    }

    @Test func restoresIntoRebuiltLibraryByPathThenName() {
        let b = RatingsBackup(tracks: [
            track("A", "One", rating: 4, path: "/m/one.mp3"),
            track("B", "Two", rating: 5, path: "/m/two.mp3"),
            track("C", "Three", rating: 2),
        ])
        // New IDs everywhere: "One" matches by path, "Two" by title + artist + length.
        let rebuilt = [track("X", "One", path: "/m/one.mp3"), track("Y", "Two", path: "/other/two.mp3"), track("Z", "Three", seconds: 100)]
        let changes = b.changes(for: rebuilt)
        #expect(changes.map(\.trackId) == ["X", "Y"])
        #expect(changes.map(\.to) == [4, 5])
    }

    @Test func keepsNewerRatingsUnlessOverwriting() {
        let b = RatingsBackup(tracks: [track("A", "One", rating: 4)])
        let now = [track("A", "One", rating: 2)]
        #expect(b.changes(for: now).isEmpty)
        #expect(b.changes(for: now, overwrite: true).first?.to == 4)
    }

    @Test func savesOnlyWhenChangedAndNeverEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = RatingsBackup(tracks: [track("A", "One", rating: 4)])
        #expect(try b.save(to: dir) != nil)
        #expect(try b.save(to: dir) == nil)
        #expect(try RatingsBackup(tracks: []).save(to: dir) == nil)
        #expect(try RatingsBackup.load(from: RatingsBackup.latest(in: dir)!).entries == b.entries)
    }
}
