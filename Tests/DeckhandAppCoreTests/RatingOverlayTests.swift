import DeckhandAppCore
import DeckhandCore
import Foundation
import MusicSource
import Testing

/// Ratings set in the app against library reads that may or may not include them.
@Suite struct RatingOverlayTests {
    private func library(_ ratings: [String: Int?]) -> SourceLibrary {
        SourceLibrary(playlists: [], tracks: Dictionary(uniqueKeysWithValues: ratings.map { id, r in
            (id, SourceTrack(id: id, title: id, rating: r))
        }))
    }

    private func result(_ id: String, _ generation: Int, confirmed: Int?, sequence: Int,
                        error: MusicEvents.Failure? = nil) -> MusicBridge.RatingResult {
        MusicBridge.RatingResult(id: id, generation: generation, requested: confirmed ?? 0, confirmed: confirmed, error: error,
                                 sequence: sequence)
    }

    @Test func ratingSetDuringALibraryReloadSurvivesTheReload() {
        var overlay = RatingOverlay()
        // A reload's live read runs (sequence 10) with the old rating; meanwhile the user sets 4 stars, written at 11.
        let gen = overlay.begin(4, ids: ["A"])
        var lib = library(["A": 2])
        overlay.apply(to: &lib, readAt: 10)
        #expect(lib.tracks["A"]?.rating == 4, "the reload put the old rating back")
        // Music confirms the write at 11; a read that ran before it still doesn't win.
        #expect(overlay.finish(result("A", gen, confirmed: 4, sequence: 11)) == 4)
        lib = library(["A": 2])
        overlay.apply(to: &lib, readAt: 10)
        #expect(lib.tracks["A"]?.rating == 4)
        // A read after the write is the truth from then on.
        lib = library(["A": 4])
        overlay.apply(to: &lib, readAt: 12)
        #expect(overlay.isEmpty)
        #expect(lib.tracks["A"]?.rating == 4)
    }

    @Test func snapshotOnlyReadsKeepTheOverlay() {
        var overlay = RatingOverlay()
        let gen = overlay.begin(5, ids: ["A"])
        _ = overlay.finish(result("A", gen, confirmed: 5, sequence: 3))
        // Music couldn't be read live: iTunesLibrary's snapshot may lag the write by seconds or more.
        var lib = library(["A": nil])
        overlay.apply(to: &lib, readAt: nil)
        #expect(lib.tracks["A"]?.rating == 5)
        #expect(!overlay.isEmpty)
    }

    @Test func onlyTheNewestRatingOnATrackIsApplied() {
        var overlay = RatingOverlay()
        let first = overlay.begin(2, ids: ["A"])
        let second = overlay.begin(5, ids: ["A"])
        // The first write's answer arrives after the second rating was set: ignored.
        #expect(overlay.finish(result("A", first, confirmed: 2, sequence: 1)) == nil)
        var lib = library(["A": 0])
        overlay.apply(to: &lib, readAt: 1)
        #expect(lib.tracks["A"]?.rating == 5)
        #expect(overlay.finish(result("A", second, confirmed: 5, sequence: 2)) == 5)
    }

    @Test func musicsAnswerWinsOverWhatWasAskedFor() {
        var overlay = RatingOverlay()
        let gen = overlay.begin(3, ids: ["A", "B"])
        // Not allowed: Music still has 1 star, and the row shows that rather than the guess.
        #expect(overlay.finish(result("A", gen, confirmed: 1, sequence: 5, error: MusicEvents.Failure(-1743))) == 1)
        // Couldn't even read it back: the overlay lets go, and the caller reads the library again.
        #expect(overlay.finish(result("B", gen, confirmed: nil, sequence: 6, error: MusicEvents.Failure(-1712))) == nil)
        #expect(overlay.entries["B"] == nil)
        var lib = library(["A": 3, "B": 3])
        overlay.apply(to: &lib, readAt: 4)
        #expect(lib.tracks["A"]?.rating == 1)
        #expect(lib.tracks["B"]?.rating == 3)
    }

    @Test func clearingARatingShowsNoStars() {
        var overlay = RatingOverlay()
        _ = overlay.begin(0, ids: ["A"])
        var lib = library(["A": 4])
        overlay.apply(to: &lib, readAt: nil)
        #expect(lib.tracks["A"]?.rating == nil)
    }
}
