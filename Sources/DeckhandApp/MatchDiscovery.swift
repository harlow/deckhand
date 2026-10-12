import DeckhandCore
import Foundation

/// Metadata-based suggestions, not a promise that two recordings sound alike.
enum MatchGroup: String, CaseIterable, Identifiable {
    case smooth = "Smooth", lift = "Lift", changeDirection = "Change Direction"
    var id: String { rawValue }
}

struct TrackMatch: Equatable {
    var id: String
    var group: MatchGroup
    var score: Double
    var reason: String
}

struct MatchSession {
    let id = UUID()
    let seed: TrackRow
    let tracks: [TrackMatch]
    let origin: SidebarItem?
    let filter: TrackFilter
    let sort: TrackSort?
    let selection: Set<String>
    let destinationID: String?
}

enum MatchDiscovery {
    static func rank(seed: TrackRow, candidates: [TrackRow], excluding: Set<String> = [], limit: Int = 50) -> [TrackMatch] {
        guard limit > 0 else { return [] }
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func tempo(_ row: TrackRow) -> Double? { row.bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        func energy(_ row: TrackRow) -> Int? { row.energy.flatMap { (1...10).contains($0) ? $0 : nil } }
        let genre = normalized(seed.genre), artist = normalized(seed.artist)
        let compatible = seed.key.map(Harmony.compatible) ?? []
        let ranked: [(TrackRow, TrackMatch)] = candidates.compactMap { row -> (TrackRow, TrackMatch)? in
            guard row.id != seed.id, !excluding.contains(row.id), row.source.unavailableReason == nil,
                  row.location.standardizedFileURL != seed.location.standardizedFileURL,
                  seed.hash == nil || row.hash != seed.hash else { return nil }
            let sameGenre = !genre.isEmpty && normalized(row.genre) == genre
            let sameArtist = !artist.isEmpty && normalized(row.artist) == artist
            let harmonic = row.key.map { compatible.contains($0.alphanumeric) } ?? false
            let distance = tempo(seed).flatMap { a in tempo(row).map { abs($0 - a) / a } }
            // Keep a reason to recommend each song, with enough latitude for a change in direction.
            guard harmonic || sameGenre || sameArtist else { return nil }
            if let distance, distance > 0.15 { return nil }
            let delta = energy(seed).flatMap { a in energy(row).map { $0 - a } }
            let closeTempo = distance.map { $0 <= Harmony.pitchRange } ?? false
            let group: MatchGroup
            if harmonic && closeTempo, let delta, delta >= 2 { group = .lift }
            else if harmonic && closeTempo && (delta.map { abs($0) <= 1 } ?? true) { group = .smooth }
            else { group = .changeDirection }
            var score = harmonic ? 40.0 : 0
            if seed.key != nil, seed.key == row.key { score += 8 }
            score += distance.map { max(0, 30 - $0 * 200) } ?? 0
            score += delta.map { max(0, 12 - Double(abs($0)) * 2) } ?? 0
            if sameGenre { score += 15 }
            if sameArtist { score += 5 }
            var reasons: [String] = []
            if harmonic { reasons.append(seed.key == row.key ? "same key" : "compatible key") }
            if closeTempo { reasons.append("close tempo") }
            if group == .lift { reasons.append("energy +\(delta!)") }
            if sameGenre { reasons.append(row.genre) }
            else if sameArtist { reasons.append("same artist") }
            return (row, TrackMatch(id: row.id, group: group, score: score, reason: reasons.joined(separator: " · ")))
        }.sorted {
            if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
            let order = $0.0.title.localizedStandardCompare($1.0.title)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }
        var ids = Set<String>(), files = Set<String>(), hashes = Set<String>()
        return ranked.filter { row, _ in
            guard ids.insert(row.id).inserted,
                  files.insert(row.location.standardizedFileURL.path).inserted else { return false }
            if let hash = row.hash, !hashes.insert(hash).inserted { return false }
            return true
        }.prefix(limit).map(\.1)
    }
}
