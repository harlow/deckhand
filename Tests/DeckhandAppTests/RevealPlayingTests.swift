@testable import DeckhandApp
import DeckhandAppCore
import MusicSource
import Testing

@MainActor struct RevealPlayingTests {
    @Test func keepsVisiblePlaylistAndFallsBackFromFiltersOtherListsAndMatches() async throws {
        let fixture = try DedicatedLibraryModelTests.Fixture()
        let model = fixture.model()
        await model.load()
        await model.connect(SourceConnection(kind: .folder, location: fixture.a))
        await model.connect(SourceConnection(kind: .folder, location: fixture.b))
        let playlist = try #require(model.playlists.first)
        let track = try #require(playlist.trackIds.first.flatMap { model.rows[$0] })
        let other = try #require(model.playlists.first { !$0.trackIds.contains(track.id) })

        model.selection = .playlist(playlist.id)
        model.trackSelection = []
        model.revealPlaying(track)
        #expect(model.selection == .playlist(playlist.id) && model.trackSelection == [track.id])
        let focus = model.trackFocusRequest
        model.revealPlaying(track) // Already selected, but may have been scrolled off screen.
        #expect(model.trackFocusRequest != focus)

        model.filter.search = "no such song"
        model.revealPlaying(track)
        #expect(model.selection == .all && model.filter.search.isEmpty)
        #expect(model.listing(playing: track).rows.contains { $0.id == track.id })
        model.selection = .playlist(other.id)
        model.revealPlaying(track)
        #expect(model.selection == .all && model.trackSelection == [track.id])

        model.selection = .playlist(playlist.id)
        model.openMatches(seed: track) // The pinned seed is outside the temporary track list.
        #expect(model.matches != nil)
        model.revealPlaying(track)
        #expect(model.matches == nil && model.selection == .playlist(playlist.id))
        #expect(model.trackSelection == [track.id])
        await model.closeLibrary()
    }
}
