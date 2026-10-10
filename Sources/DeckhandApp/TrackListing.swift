import Foundation

/// The track list as shown: the sidebar selection's tracks, filtered and sorted. `LibraryModel`
/// rebuilds it only when rows, selection, filter, sort or (for "mixes with playing") the playing
/// track change, so views read it for free.
struct TrackListing {
    /// The sidebar selection's tracks, before filtering.
    var base: [TrackRow] = []
    /// What the table shows.
    var rows: [TrackRow] = []
    var minutes = 0
    var genres: [String] = []
    /// Bumped on every rebuild, so the table can skip diffing when nothing changed.
    var version = 0

    static func filter(_ base: [TrackRow], by filter: TrackFilter, playing: TrackRow?) -> [TrackRow] {
        guard !filter.isEmpty else { return base }
        let mixKeys = filter.mixesWithPlaying ? playing?.key.map(Harmony.compatible) : nil
        let mixBpm = filter.mixesWithPlaying ? playing?.bpm : nil
        let q = filter.search.trimmingCharacters(in: .whitespaces)
        return base.filter { r in
            if !q.isEmpty {
                let hit = r.title.localizedCaseInsensitiveContains(q) || r.artist.localizedCaseInsensitiveContains(q)
                    || r.genre.localizedCaseInsensitiveContains(q) || r.key?.alphanumeric == q.uppercased()
                if !hit { return false }
            }
            if !filter.keys.isEmpty, !(r.key.map { filter.keys.contains($0.alphanumeric) } ?? false) { return false }
            if let lo = filter.bpmMin, (r.bpm ?? 0) < lo { return false }
            if let hi = filter.bpmMax, (r.bpm ?? .infinity) > hi { return false }
            if let e = filter.minEnergy, (r.energy ?? 0) < e { return false }
            if let s = filter.minRating, r.rating < s { return false }
            if !filter.genres.isEmpty, !filter.genres.contains(r.genre) { return false }
            if filter.mixesWithPlaying, let playing {
                if r.id == playing.id { return false }
                if let keys = mixKeys, !(r.key.map { keys.contains($0.alphanumeric) } ?? false) { return false }
                if let b = mixBpm, let rb = r.bpm, abs(rb / b - 1) > Harmony.pitchRange { return false }
            }
            return true
        }
    }

    /// Sorts `rows`. When `previous` (the last result) holds the same tracks and is still in order,
    /// keeps its order: one pass of comparisons instead of a full sort, which matters for title sorts
    /// while analysis streams in.
    static func sort(_ rows: [TrackRow], by sort: TrackSort?, previous: [TrackRow] = []) -> [TrackRow] {
        guard let sort, sort.column != .status, sort.column != .overview else { return rows }
        func less(_ a: TrackRow, _ b: TrackRow) -> Bool {
            switch sort.column {
            case .title: a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .bpm: a.bpmSort < b.bpmSort
            case .key: a.keySort < b.keySort
            case .energy: a.energySort < b.energySort
            case .rating: a.rating < b.rating
            case .genre: a.genre.localizedStandardCompare(b.genre) == .orderedAscending
            case .time: a.duration < b.duration
            case .status, .overview: false
            }
        }
        let inOrder: (TrackRow, TrackRow) -> Bool = sort.ascending ? less : { less($1, $0) }
        if previous.count == rows.count, !rows.isEmpty {
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let reordered = previous.compactMap { byId[$0.id] }
            if reordered.count == rows.count, byId.count == rows.count,
               zip(reordered, reordered.dropFirst()).allSatisfy({ !inOrder($1, $0) }) {
                return reordered
            }
        }
        return rows.sorted(by: inOrder)
    }
}
