import DeckhandCore
import Foundation

/// Ratings set in the app that a library read may not reflect yet. A rating shows the moment it's set; once Music
/// confirms the write, the row holds Music's value; a library read replaces it only if the read ran after the write
/// (a read already in flight when the rating was set would put the old rating back).
///
/// Each rating set takes a generation: when several are set on one track in quick succession, only the newest one's
/// result is applied.
public struct RatingOverlay: Sendable {
    public struct Entry: Sendable, Equatable {
        public var stars: Int
        public var generation: Int
        /// Bridge sequence number of the write Music confirmed; nil while it's waiting.
        public var confirmedAt: Int?
    }

    public private(set) var entries: [String: Entry] = [:]
    private var lastGeneration = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Records ratings the user just set. Returns the generation to tag the writes with.
    public mutating func begin(_ stars: Int, ids: [String]) -> Int {
        lastGeneration += 1
        for id in ids { entries[id] = Entry(stars: stars, generation: lastGeneration) }
        return lastGeneration
    }

    /// A write finished. Returns the stars the track should show, or nil if a newer rating owns the track, or Music
    /// couldn't be read back (the overlay lets go; read the library again for the truth).
    public mutating func finish(_ r: MusicBridge.RatingResult) -> Int? {
        guard let e = entries[r.id], e.generation == r.generation else { return nil }
        guard let confirmed = r.confirmed else {
            entries[r.id] = nil
            return nil
        }
        entries[r.id] = Entry(stars: confirmed, generation: r.generation, confirmedAt: r.sequence)
        return confirmed
    }

    /// Lays the overlay over a library read. `readAt`: the bridge sequence number of the live read the library was
    /// built with (nil if Music couldn't be read live). Entries that read already reflects are dropped.
    public mutating func apply(to lib: inout SourceLibrary, readAt: Int?) {
        for (id, e) in entries {
            if let c = e.confirmedAt, let r = readAt, r > c {
                entries[id] = nil
                continue
            }
            lib.tracks[id]?.rating = e.stars == 0 ? nil : e.stars
        }
    }
}
