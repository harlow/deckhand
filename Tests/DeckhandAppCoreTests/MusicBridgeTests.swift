import DeckhandAppCore
import Foundation
import MusicSource
import Testing

/// A Music stand-in: records every event in the order it ran, can hold a write until released, and can fail.
final class FakeMusic: MusicTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var ratings: [String: Int] = [:]
    var failSet: [String: Int32] = [:]
    var failGet: [String: Int32] = [:]
    /// Tracks Music doesn't have: setting their rating matches nothing (no error), reading it fails.
    var missing: Set<String> = []
    /// The next write waits for `release()`; `started` is signalled when it begins.
    private var holdNext = false
    private let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)

    var events: [String] { lock.withLock { _events } }
    func stars(_ id: String) -> Int? { lock.withLock { ratings[id] } }

    func hold() { lock.withLock { holdNext = true } }

    /// Waits until the held write has begun.
    func waitUntilStarted() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.started.wait()
                c.resume()
            }
        }
    }
    func release() { gate.signal() }

    func access(ask: Bool) -> MusicEvents.Access { .granted }

    func readLive() throws -> [String: LiveTrack] {
        lock.withLock {
            _events.append("read")
            return ratings.mapValues { LiveTrack(title: "t", rating: $0) }
        }
    }

    func setRating(_ stars: Int, trackId: String) throws {
        let wait = lock.withLock { () -> Bool in
            defer { holdNext = false }
            return holdNext
        }
        if wait {
            started.signal()
            gate.wait()
        }
        try lock.withLock {
            _events.append("set \(trackId) \(stars)")
            if let status = failSet[trackId] { throw MusicEvents.Failure(status) }
            if !missing.contains(trackId) { ratings[trackId] = stars }
        }
    }

    func rating(trackId: String) throws -> Int {
        try lock.withLock {
            _events.append("get \(trackId)")
            if let status = failGet[trackId] { throw MusicEvents.Failure(status) }
            guard let r = ratings[trackId] else { throw MusicEvents.Failure(MusicEvents.Failure.noSuchObject) }
            return r
        }
    }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MusicBridge.RatingResult] = []
    func add(_ r: MusicBridge.RatingResult) { lock.withLock { items.append(r) } }
    var all: [MusicBridge.RatingResult] { lock.withLock { items } }
}

@Suite struct MusicBridgeTests {
    private func bridge(_ music: FakeMusic) -> (MusicBridge, Results) {
        let results = Results()
        return (MusicBridge(transport: music) { results.add($0) }, results)
    }

    @Test func coalescesRatingsPerTrackLastOneWins() async {
        let music = FakeMusic()
        let (bridge, results) = bridge(music)
        music.hold()
        bridge.setRating(1, ids: ["A"], generation: 1)
        await music.waitUntilStarted()
        // While the first write is in Music: two more for A (only the last one matters) and one for B.
        bridge.setRating(2, ids: ["A"], generation: 2)
        bridge.setRating(3, ids: ["A"], generation: 3)
        bridge.setRating(4, ids: ["B"], generation: 4)
        #expect(bridge.hasQueuedRatings)
        music.release()
        await bridge.drain()
        #expect(music.events == ["set A 1", "get A", "set A 3", "get A", "set B 4", "get B"])
        #expect(results.all.map(\.generation) == [1, 3, 4])
        #expect(results.all.map(\.confirmed) == [1, 3, 4])
        #expect(music.stars("A") == 3)
        #expect(!bridge.hasQueuedRatings)
    }

    @Test func writesRunInTheOrderAskedOneAtATime() async {
        let music = FakeMusic()
        let (bridge, results) = bridge(music)
        for (i, id) in ["C", "A", "B"].enumerated() { bridge.setRating(i + 1, ids: [id], generation: i + 1) }
        await bridge.drain()
        #expect(music.events.filter { $0.hasPrefix("set") } == ["set C 1", "set A 2", "set B 3"])
        let sequences = results.all.map(\.sequence)
        #expect(sequences == sequences.sorted())
    }

    @Test func errorsAreReportedWithWhatMusicHasNow() async {
        let music = FakeMusic()
        let (bridge, results) = bridge(music)
        bridge.setRating(2, ids: ["X"], generation: 1)
        await bridge.drain()
        // Not allowed: the write fails, and reading back shows the rating Music still has. Not found: the write
        // matches nothing; reading back says so. Timed out reading back after a write that went through.
        music.failSet["X"] = MusicEvents.Failure.notPermitted
        music.missing = ["gone"]
        music.failGet["Y"] = MusicEvents.Failure.timedOut
        bridge.setRating(5, ids: ["X"], generation: 2)
        bridge.setRating(4, ids: ["gone"], generation: 3)
        bridge.setRating(1, ids: ["Y"], generation: 4)
        await bridge.drain()
        let r = results.all
        #expect(r[1].error == MusicEvents.Failure(-1743))
        #expect(r[1].confirmed == 2)
        #expect(r[2].error == MusicEvents.Failure(-1728))
        #expect(r[2].confirmed == nil)
        #expect(r[3].error == MusicEvents.Failure(-1712))
        #expect(r[3].confirmed == nil)
    }

    @Test func drainWaitsForARatingSetJustBeforeSync() async {
        let music = FakeMusic()
        let (bridge, _) = bridge(music)
        music.hold()
        bridge.setRating(4, ids: ["A"], generation: 1)
        let drained = Results()
        let task = Task {
            await bridge.drain()
            drained.add(.init(id: "drained", generation: 0, requested: 0, confirmed: nil, error: nil, sequence: 0))
        }
        await music.waitUntilStarted()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drained.all.isEmpty, "drain returned while a rating was still being written")
        music.release()
        await task.value
        #expect(drained.all.count == 1)
        // The sync's library read happens after this, so it sees the rating.
        #expect(music.stars("A") == 4)
    }

    @Test func readsKnowWhichWritesTheyInclude() async throws {
        let music = FakeMusic()
        let (bridge, results) = bridge(music)
        bridge.setRating(3, ids: ["A"], generation: 1)
        let read = try await bridge.run { try $0.readLive() }
        await bridge.drain()
        let write = try #require(results.all.first)
        #expect(read.sequence > write.sequence)
        #expect(read.value["A"]?.rating == 3)

        // A read that ran before a write has a lower number and doesn't include it.
        let early = try await bridge.run { try $0.readLive() }
        bridge.setRating(5, ids: ["B"], generation: 2)
        await bridge.drain()
        let second = try #require(results.all.last)
        #expect(early.sequence < second.sequence)
        #expect(early.value["B"] == nil)
    }
}
