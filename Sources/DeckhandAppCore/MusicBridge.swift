import Foundation
import MusicSource

/// What the app asks of Music. `AppleEventTransport` is the real one; tests use a fake.
public protocol MusicTransport: Sendable {
    func access(ask: Bool) -> MusicEvents.Access
    /// Every file track's database fields, read live.
    func readLive() throws -> [String: LiveTrack]
    func setRating(_ stars: Int, trackId: String) throws
    func rating(trackId: String) throws -> Int
}

public struct AppleEventTransport: MusicTransport {
    public init() {}
    public func access(ask: Bool) -> MusicEvents.Access { MusicEvents.access(ask: ask) }
    public func readLive() throws -> [String: LiveTrack] { try MusicLive.read(prompt: true) }
    public func setRating(_ stars: Int, trackId: String) throws { try MusicEvents.setRating(stars, trackId: trackId) }
    public func rating(trackId: String) throws -> Int { try MusicEvents.rating(trackId: trackId) }
}

/// The one way the app talks to Music: every Apple Event goes through a single serial queue, so they run one at a
/// time in the order asked (concurrent ones fail or reorder) and never on the main thread. Each operation gets a
/// sequence number when it runs, so a library read can tell which rating writes it already reflects.
///
/// Ratings are coalesced per track (the last one asked for wins), written, then read back; the result, Music's
/// value or the error, is reported through `onRating`. `drain()` waits for everything queued so far, e.g. before a
/// sync reads the library.
public final class MusicBridge: @unchecked Sendable {
    public struct RatingResult: Sendable, Equatable {
        public var id: String
        public var generation: Int
        public var requested: Int
        /// What Music reports after the write; nil if it couldn't be read back.
        public var confirmed: Int?
        /// Why the write (or reading it back) failed.
        public var error: MusicEvents.Failure?
        /// When the write ran: library reads with a higher sequence number include it.
        public var sequence: Int

        public init(id: String, generation: Int, requested: Int, confirmed: Int?, error: MusicEvents.Failure?, sequence: Int) {
            self.id = id
            self.generation = generation
            self.requested = requested
            self.confirmed = confirmed
            self.error = error
            self.sequence = sequence
        }
    }

    private let transport: any MusicTransport
    private let queue = DispatchQueue(label: "rocks.deckhand.music", qos: .userInitiated)
    private let onRating: @Sendable (RatingResult) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var queued: [String: (stars: Int, generation: Int)] = [:]
    private var order: [String] = []
    private var flushing = false
    // Only touched on `queue`.
    private var sequence = 0

    public init(transport: any MusicTransport = AppleEventTransport(),
                onRating: @escaping @Sendable (RatingResult) -> Void) {
        self.transport = transport
        self.onRating = onRating
    }

    /// Queues rating writes (0–5; 0 clears). A track's newer rating replaces one still waiting.
    public func setRating(_ stars: Int, ids: [String], generation: Int) {
        lock.withLock {
            for id in ids {
                if queued[id] == nil { order.append(id) }
                queued[id] = (stars, generation)
            }
            guard !flushing, !order.isEmpty else { return }
            flushing = true
            queue.async { self.flush() }
        }
    }

    /// Whether ratings are waiting to be written.
    public var hasQueuedRatings: Bool { lock.withLock { flushing } }

    private func flush() {
        while true {
            let batch: [(id: String, stars: Int, generation: Int)] = lock.withLock {
                let b = order.compactMap { id in queued[id].map { (id, $0.stars, $0.generation) } }
                queued = [:]
                order = []
                if b.isEmpty { flushing = false }
                return b
            }
            if batch.isEmpty { return }
            for r in batch {
                sequence += 1
                var failure: MusicEvents.Failure?
                var confirmed: Int?
                do {
                    try transport.setRating(r.stars, trackId: r.id)
                } catch {
                    failure = Self.failure(error)
                }
                // Read back what Music has now, also after a failure: the row shows Music's value, not a guess.
                do {
                    confirmed = try transport.rating(trackId: r.id)
                } catch {
                    if failure == nil { failure = Self.failure(error) }
                }
                onRating(RatingResult(id: r.id, generation: r.generation, requested: r.stars, confirmed: confirmed,
                                      error: failure, sequence: sequence))
            }
        }
    }

    /// Runs `work` on the queue after everything queued before it. Returns its result and sequence number.
    public func run<T: Sendable>(_ work: @escaping @Sendable (any MusicTransport) throws -> T) async throws -> (value: T, sequence: Int) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.sequence += 1
                let s = self.sequence
                do {
                    continuation.resume(returning: (try work(self.transport), s))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns once everything queued before the call (rating writes included) has run.
    public func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Any error from the transport as a Music failure (with its OSStatus).
    public static func failure(_ error: Error) -> MusicEvents.Failure {
        error as? MusicEvents.Failure ?? MusicEvents.Failure(Int32(truncatingIfNeeded: (error as NSError).code))
    }
}
