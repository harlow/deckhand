import AppKit
import Observation

/// Quick Rate: plays unrated tracks one after another from their preview point. Rating one (⌥1–⌥5)
/// moves straight on; j moves on without rating; k goes back to change the last one.
@MainActor @Observable
final class Review {
    enum Action: Equatable {
        case rated(Int)
        /// "Not now": no rating; hidden from review until the snooze runs out.
        case skipped
    }

    struct Step {
        var id: String
        var action: Action
    }

    /// Where the tracks came from, e.g. "Deep House".
    let source: String
    let startedAt = Date()
    /// Shuffled track ids still to review; `queue[0]` is the current track.
    private(set) var queue: [String]
    private(set) var history: [Step] = []
    let total: Int

    @ObservationIgnored private unowned let library: LibraryModel
    @ObservationIgnored private unowned let player: Player

    static let snoozeDays = 30

    /// Best guess first (by what your ratings say you like), or shuffled. Toggled with o.
    var bestFirst = true {
        didSet { reorder() }
    }
    /// Track ids best guess first, and why each is ranked where it is.
    @ObservationIgnored private let rank: [String: Int]
    @ObservationIgnored private let why: [String: [String]]
    /// Pick each next track to follow the current one in key and tempo, so a session stays in one
    /// groove. Toggled with g.
    var groove = true

    init(ranked: [Suggestion], source: String, library: LibraryModel, player: Player) {
        self.queue = ranked.map(\.id)
        self.rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.id, $0) })
        self.why = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0.reasons) })
        self.total = ranked.count
        self.source = source
        self.library = library
        self.player = player
    }

    var current: TrackRow? { queue.first.flatMap { library.rows[$0] } }
    /// Why this track came up, e.g. ["played 14×", "you like 3 Kerri Chandler tracks"].
    func reasons(_ id: String) -> [String] { why[id] ?? [] }

    /// Re-sorts what's left after the current track when the order changes.
    private func reorder() {
        guard queue.count > 2 else { return }
        let rest = queue.dropFirst()
        queue = [queue[0]] + (bestFirst ? rest.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) } : rest.shuffled())
    }
    var upcoming: [TrackRow] { queue.dropFirst().prefix(3).compactMap { library.rows[$0] } }
    var remaining: Int { queue.count }
    var done: Bool { queue.isEmpty }

    /// How many of each outcome this session: index 1–5 = stars, 0 = skipped.
    var tally: [Int] {
        var t = Array(repeating: 0, count: 6)
        for s in history {
            switch s.action {
            case .rated(let n): t[n] += 1
            case .skipped: t[0] += 1
            }
        }
        return t
    }

    var last: (row: TrackRow, action: Action)? {
        guard let s = history.last, let r = library.rows[s.id] else { return nil }
        return (r, s.action)
    }

    func start() { playCurrent() }

    func rate(_ stars: Int) {
        guard let id = queue.first else { return }
        library.setRating(stars, for: [id])
        advance(Step(id: id, action: .rated(stars)))
    }

    /// Moves on without rating. An unrated track is snoozed so review doesn't offer it again for a
    /// while; one rated earlier (after going back with k) keeps its rating.
    func skip() {
        guard let row = current else { return }
        if row.rating > 0 {
            advance(Step(id: row.id, action: .rated(row.rating)))
        } else {
            library.snooze(row.id, days: Self.snoozeDays)
            advance(Step(id: row.id, action: .skipped))
        }
    }

    /// Returns to the previous track. Its rating stays until you give it another; a skip is undone.
    func back() {
        guard let step = history.popLast() else { NSSound.beep(); return }
        if step.action == .skipped { library.unsnooze(step.id) }
        queue.insert(step.id, at: 0)
        playCurrent()
    }

    /// Starts the current track again from its preview point.
    func replay() { playCurrent() }

    private func advance(_ step: Step) {
        history.append(step)
        queue.removeFirst()
        if groove, let from = library.rows[step.id] { bringForwardBestMatch(after: from) }
        if queue.isEmpty { player.pause() } else { playCurrent() }
    }

    /// Moves the queued track that mixes best out of `from` to the front: compatible key (same,
    /// ±1, relative) and tempo within pitch range score highest. In best-first order only the next
    /// 30 are considered, so it still works through the best guesses first.
    private func bringForwardBestMatch(after from: TrackRow) {
        let window = bestFirst ? min(queue.count, 30) : queue.count
        guard window > 1 else { return }
        let keys = from.key.map(Harmony.compatible) ?? []
        func score(_ r: TrackRow) -> Double {
            var s = 0.0
            if let k = r.key?.alphanumeric, keys.contains(k) { s += k == from.key?.alphanumeric ? 2.5 : 2 }
            if let a = from.bpm, let b = r.bpm, a > 0 {
                // Half/double time counts as close.
                let ratio = [b / a, b * 2 / a, b / (a * 2)].map { abs($0 - 1) }.min()!
                s += max(0, 2 - ratio / Harmony.pitchRange * 2)
            }
            if !from.genre.isEmpty, r.genre == from.genre { s += 0.5 }
            return s
        }
        let best = (0..<window).max { a, b in
            score(library.rows[queue[a]] ?? from) < score(library.rows[queue[b]] ?? from)
        } ?? 0
        if best > 0 { queue.insert(queue.remove(at: best), at: 0) }
    }

    private func playCurrent() {
        guard let row = current else { return }
        player.play(from: .preview, row, artwork: library.artwork)
    }
}

extension LibraryModel {
    /// Starts Quick Rate on the unrated tracks currently listed (sidebar selection plus filters),
    /// leaving out tracks skipped in the last 30 days.
    func startReview(player: Player) {
        let now = Date()
        let unrated = listing(playing: player.current).rows
            .filter { $0.rating == 0 && (snoozedUntil($0.id).map { $0 <= now } ?? true) }
        guard !unrated.isEmpty else {
            flash("Nothing to rate here: every track in \(title) is rated or skipped")
            return
        }
        let r = Review(ranked: rankForReview(unrated), source: title, library: self, player: player)
        review = r
        Log.info("review", "Quick Rate: \(unrated.count) unrated tracks in \(title)")
        r.start()
    }

    func endReview() {
        if let r = review { Log.info("review", "Quick Rate ended: \(r.history.count) reviewed, \(r.remaining) left") }
        review = nil
        backUpRatings()
    }
}
