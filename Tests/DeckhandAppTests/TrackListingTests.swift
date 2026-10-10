@testable import DeckhandApp
import DeckhandCore
import Foundation
import Testing

@Suite struct TrackListingTests {
    private func row(_ id: String, _ title: String, bpm: Double? = nil, key: String? = nil, genre: String = "", rating: Int? = nil) -> TrackRow {
        var r = TrackRow(id: id, source: SourceTrack(id: id, title: title, rating: rating), title: title, artist: "Artist",
                         genre: genre, duration: 300, location: URL(fileURLWithPath: "/m/\(id).mp3"), dateAdded: .distantPast)
        r.bpm = bpm
        r.key = key.flatMap(MusicalKey.init(parsing:))
        return r
    }

    private var rows: [TrackRow] {
        [row("a", "Track 10", bpm: 124, key: "8A", genre: "House", rating: 4),
         row("b", "track 2", bpm: 128, key: "9A", genre: "Techno"),
         row("c", "Alpha", bpm: 140, key: "3B", genre: "House", rating: 5)]
    }

    @Test func emptyFilterKeepsEverything() {
        #expect(TrackListing.filter(rows, by: TrackFilter(), playing: nil).map(\.id) == ["a", "b", "c"])
    }

    @Test func filtersBySearchKeyAndRating() {
        var f = TrackFilter()
        f.search = "house"
        #expect(TrackListing.filter(rows, by: f, playing: nil).map(\.id) == ["a", "c"])
        f.search = "8a"
        #expect(TrackListing.filter(rows, by: f, playing: nil).map(\.id) == ["a"])
        f = TrackFilter()
        f.minRating = 5
        #expect(TrackListing.filter(rows, by: f, playing: nil).map(\.id) == ["c"])
    }

    @Test func mixesWithPlayingUsesKeyAndTempo() {
        var f = TrackFilter()
        f.mixesWithPlaying = true
        // 8A mixes with 9A, and 128 is within 6% of 124; 3B is neither.
        #expect(TrackListing.filter(rows, by: f, playing: rows[0]).map(\.id) == ["b"])
    }

    @Test func sortsNaturallyByTitle() {
        let up = TrackListing.sort(rows, by: TrackSort(column: .title, ascending: true))
        #expect(up.map(\.id) == ["c", "b", "a"])
        let down = TrackListing.sort(rows, by: TrackSort(column: .bpm, ascending: false))
        #expect(down.map(\.id) == ["c", "b", "a"])
        #expect(TrackListing.sort(rows, by: nil).map(\.id) == ["a", "b", "c"])
    }

    @Test func reusesPreviousOrderOnlyWhileItStillHolds() {
        let sort = TrackSort(column: .bpm, ascending: true)
        let previous = TrackListing.sort(rows, by: sort)
        var changed = rows
        changed[0].genre = "Disco"
        // Same tracks, still in order: previous order kept (with the updated rows).
        let kept = TrackListing.sort(changed.reversed(), by: sort, previous: previous)
        #expect(kept.map(\.id) == ["a", "b", "c"])
        #expect(kept[0].genre == "Disco")
        // A tempo changed so the old order is wrong: re-sorted.
        changed[0].bpm = 150
        #expect(TrackListing.sort(changed, by: sort, previous: previous).map(\.id) == ["b", "c", "a"])
    }
}
