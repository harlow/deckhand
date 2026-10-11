import DeckhandCore
import Foundation
import MusicSource
import Testing
@testable import DeckhandLibrary

@Suite struct AudioRepairTests {
    @Test func protectedAudioRepairKeepsIdentityMembershipRatingsAndSurvivesRestartAndReimport() async throws {
        let f = try LibraryFixture(), audio = try f.audio("Replacement.wav")
        let source = SourceConnection(kind: .music)
        var imported = f.music(audio, members: ["MUSIC1", "MUSIC1"])
        imported.tracks["MUSIC1"]?.location = nil
        imported.tracks["MUSIC1"]?.unavailableReason = "Protected (DRM) track; no exportable local file"
        let store = try DeckhandLibraryStore(directory: f.directory)
        let original = try await store.importLibrary(imported, from: source)
        _ = try await store.setRating(5, ids: ["MUSIC1"])
        let repaired = try await store.locateAudioFile(for: "MUSIC1", at: audio)
        #expect(repaired.library.tracks.count == 1)
        #expect(repaired.library.tracks["MUSIC1"]?.location == audio)
        #expect(repaired.library.tracks["MUSIC1"]?.unavailableReason == nil)
        #expect(repaired.library.tracks["MUSIC1"]?.rating == 5)
        #expect(repaired.library.playlists == original.library.playlists)
        #expect(repaired.library.tracks["MUSIC1"]?.durationSeconds == 0.1)
        await store.close()
        let reopened = try DeckhandLibraryStore(directory: f.directory)
        #expect(await reopened.snapshot().library.tracks == repaired.library.tracks)
        let refreshed = try await reopened.importLibrary(imported, from: source)
        #expect(refreshed.library.tracks == repaired.library.tracks)
        #expect(refreshed.library.playlists == original.library.playlists)
        let saved = try #require(try DeckhandLibraryStore.savedLibrary(in: f.directory))
        #expect(saved.tracks == repaired.library.tracks) // The sync CLI reads the repaired audio too.
        await reopened.close()
    }

    @Test func missingFileCanBeRelocatedAndReconnectRecheckRestoresAvailability() async throws {
        let f = try LibraryFixture(), original = try f.audio("Original.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let imported = try await store.importLibrary(f.music(original), from: SourceConnection(kind: .music))
        let moved = f.b.appendingPathComponent("Moved.wav")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(await store.snapshot(checkAvailability: true).library.tracks["MUSIC1"]?.unavailableReason != nil)
        let repaired = try await store.locateAudioFile(for: "MUSIC1", at: moved)
        #expect(repaired.library.tracks["MUSIC1"]?.location == moved)
        #expect(repaired.library.playlists == imported.library.playlists)
        let hidden = f.b.appendingPathComponent("TemporarilyHidden.wav")
        try FileManager.default.moveItem(at: moved, to: hidden)
        #expect(await store.snapshot(checkAvailability: true).library.tracks["MUSIC1"]?.unavailableReason != nil)
        try FileManager.default.moveItem(at: hidden, to: moved)
        #expect(await store.snapshot(checkAvailability: true).library.tracks["MUSIC1"]?.unavailableReason == nil)
        await store.close()
    }

    @Test func invalidFilesAndFailedTransactionsLeaveTheTrackUnchanged() async throws {
        let f = try LibraryFixture(), original = try f.audio("Original.wav"), replacement = try f.audio("Replacement.wav")
        let store = try DeckhandLibraryStore(directory: f.directory)
        let before = try await store.importLibrary(f.music(original), from: SourceConnection(kind: .music))
        let fake = f.a.appendingPathComponent("Fake.wav")
        try "not audio".write(to: fake, atomically: true, encoding: .utf8)
        for file in [fake, f.a.appendingPathComponent("Absent.wav"), f.a] {
            await #expect(throws: (any Error).self) { try await store.locateAudioFile(for: "MUSIC1", at: file) }
        }
        await #expect(throws: (any Error).self) { try await store.locateAudioFile(for: "unknown", at: replacement) }
        try f.rawSQL("CREATE TRIGGER fail_audio_repair BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        await #expect(throws: (any Error).self) { try await store.locateAudioFile(for: "MUSIC1", at: replacement) }
        #expect(await store.snapshot().library.tracks == before.library.tracks)
        #expect(await store.snapshot().revision == before.revision)
        #expect(try DeckhandLibraryStore.savedLibrary(in: f.directory)?.tracks == before.library.tracks)
        await store.close()
    }
}
