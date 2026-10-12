@testable import DeckhandApp
import AVFoundation
import DeckhandCore
import Foundation
import Testing

@MainActor @Suite(.serialized) struct ContinuousPlaybackTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID())")
        let player = Player()
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func row(_ id: String, seconds: Double = 10, missing: Bool = false) throws -> TrackRow {
            let url = root.appendingPathComponent(id + ".wav")
            if !missing {
                let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8000 * seconds))!
                buffer.frameLength = buffer.frameCapacity
                memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                do {
                    let file = try AVAudioFile(forWriting: url, settings: format.settings)
                    try file.write(from: buffer)
                }
            }
            return TrackRow(id: id, source: SourceTrack(id: id, title: id, durationSeconds: seconds, location: url),
                            title: id, artist: "Test", genre: "", duration: seconds, location: url, dateAdded: .distantPast)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func naturalSongEndAdvancesInCapturedVisibleOrder() async throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A"), b = try f.row("B", seconds: 0.15), c = try f.row("C")
        var visibleList = [c, b, a]
        f.player.play(b, continuingIn: visibleList)
        #expect(f.player.nextInList?.id == a.id && f.player.canAdvance)
        visibleList = [a, c, b] // Browsing or sorting another list cannot retarget playback.
        try await waitUntil { f.player.current?.id == a.id }
        #expect(f.player.isPlaying && f.player.history.map(\.id) == [b.id])
        #expect(f.player.nextInList == nil && !f.player.canAdvance)
    }

    @Test func naturalEndsHonorTheQueueThenReturnToTheList() async throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A", seconds: 0.15), b = try f.row("B"), x = try f.row("Queued", seconds: 0.15)
        f.player.play(a, continuingIn: [a, b])
        f.player.enqueue([x])
        try await waitUntil { f.player.current?.id == b.id }
        #expect(f.player.isPlaying && f.player.queue.isEmpty)
        #expect(f.player.history.map(\.id) == [a.id, x.id])
    }

    @Test func queuedListSongsDoNotRepeatAndPreviousKeepsContinuation() throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A"), b = try f.row("B"), c = try f.row("C")
        f.player.play(a, continuingIn: [a, b, c])
        f.player.enqueue([c])
        f.player.next()
        #expect(f.player.current?.id == c.id && f.player.nextInList?.id == b.id)
        f.player.previous()
        #expect(f.player.current?.id == a.id && f.player.nextInList?.id == b.id)
        f.player.next()
        #expect(f.player.current?.id == c.id)
        f.player.next()
        #expect(f.player.current?.id == b.id && !f.player.canAdvance)
        f.player.next()
        #expect(!f.player.isPlaying && f.player.history.map(\.id) == [a.id, c.id])
    }

    @Test func naturalEndSkipsMissingAndUnreadableFiles() async throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A", seconds: 0.15), missing = try f.row("Missing", missing: true)
        let broken = try f.row("Broken"), b = try f.row("B")
        try Data([0, 1, 2]).write(to: broken.location)
        f.player.play(a, continuingIn: [a, missing, broken, b])
        try await waitUntil { f.player.current?.id == b.id }
        #expect(f.player.isPlaying && f.player.error == nil && !f.player.canAdvance)
    }

    @Test func lastSongStopsWithoutRepeatingAndCanBePlayedAgain() async throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A", seconds: 0.15)
        f.player.play(a, continuingIn: [a])
        try await waitUntil { !f.player.isPlaying }
        #expect(f.player.current?.id == a.id && !f.player.canAdvance && f.player.history.isEmpty)
        f.player.toggle()
        #expect(f.player.isPlaying && f.player.current?.id == a.id && f.player.history.isEmpty)
    }

    @Test func newListAndStandalonePreviewReplaceOldContinuation() throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A"), b = try f.row("B"), x = try f.row("X"), y = try f.row("Y")
        f.player.play(a, continuingIn: [a, b])
        f.player.play(x, continuingIn: [x, y])
        f.player.next()
        #expect(f.player.current?.id == y.id && !f.player.canAdvance)
        f.player.play(a, continuingIn: [a, b])
        f.player.play(from: .preview, x) // Quick Rate supplies its own next-song decisions.
        #expect(f.player.current?.id == x.id && !f.player.canAdvance)
        f.player.reset()
        #expect(f.player.following.isEmpty && f.player.nextInList == nil)
    }

    @Test func playQueuedNowPreservesListAndStaleCompletionCannotSkip() async throws {
        let f = try Fixture(); defer { f.player.reset() }
        let a = try f.row("A"), b = try f.row("B"), x = try f.row("X")
        f.player.play(a, continuingIn: [a, b])
        f.player.enqueue([x])
        f.player.playQueued(x)
        #expect(f.player.current?.id == x.id && f.player.nextInList?.id == b.id && f.player.queue.isEmpty)
        let oldAudio = try AVAudioPlayer(contentsOf: a.location)
        f.player.audioPlayerDidFinishPlaying(oldAudio, successfully: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.player.current?.id == x.id)
        f.player.next()
        #expect(f.player.current?.id == b.id && f.player.isPlaying)
    }
}
