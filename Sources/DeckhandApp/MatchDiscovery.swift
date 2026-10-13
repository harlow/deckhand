import DeckhandCore
import Foundation

/// Conservative audio-envelope similarity with metadata fallback, not a guarantee of a good mix.
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
            let texture = seed.matchProfile.flatMap { a in row.matchProfile.flatMap { a.textureSimilarity(to: $0) } }
            let groove = seed.matchProfile.flatMap { a in row.matchProfile.flatMap { a.grooveSimilarity(to: $0) } }
            let shape = seed.matchProfile.flatMap { a in row.matchProfile.flatMap { a.energySimilarity(to: $0) } }
            let audioRelated = (texture.map { $0 >= 0.96 } ?? false) && (groove.map { $0 >= 0.94 } ?? false)
            // Audio can connect differently tagged tracks. Harmonic/tempo fit alone remains useful
            // when descriptors are unavailable, without inventing sound-based explanations.
            guard harmonic || sameGenre || sameArtist || audioRelated else { return nil }
            if let distance, distance > 0.15 { return nil }
            let delta = energy(seed).flatMap { a in energy(row).map { $0 - a } }
            let closeTempo = distance.map { $0 <= Harmony.pitchRange } ?? false
            let group: MatchGroup
            let coherent = (texture.map { $0 >= 0.65 } ?? true) && (groove.map { $0 >= 0.5 } ?? true)
            if harmonic && closeTempo && coherent, let delta, delta >= 2 { group = .lift }
            else if harmonic && closeTempo && coherent && (delta.map { abs($0) <= 1 } ?? true) { group = .smooth }
            else { group = .changeDirection }
            var score = harmonic ? 18.0 : 0
            if seed.key != nil, seed.key == row.key { score += 2 }
            score += distance.map { max(0, 20 - $0 * 120) } ?? 0
            let targetEnergy = group == .lift ? 2 : 0
            score += delta.map { max(0, 8 - Double(abs($0 - targetEnergy)) * 2) } ?? 0
            if sameGenre { score += 8 }
            if sameArtist { score += 3 }
            // Only evidence above a neutral baseline earns a bonus. Missing or uncorrelated
            // descriptors contribute zero, rather than rewarding a track just for being cached.
            score += texture.map { 24 * max(0, ($0 - 0.8) / 0.2) } ?? 0
            score += groove.map { 24 * max(0, ($0 - 0.55) / 0.45) } ?? 0
            score += shape.map { 6 * max(0, ($0 - 0.7) / 0.3) } ?? 0
            var reasons: [String] = []
            if let groove, groove >= 0.85 { reasons.append("similar groove") }
            if let texture, texture >= 0.88 { reasons.append("similar band balance") }
            if group == .lift { reasons.append("energy +\(delta!)") }
            else if let delta, delta <= -2 { reasons.append("energy \(delta)") }
            if group == .changeDirection, let texture, texture < 0.65 { reasons.append("different texture") }
            if reasons.isEmpty, let shape, shape >= 0.9 { reasons.append("similar energy shape") }
            if harmonic { reasons.append(seed.key == row.key ? "same key" : "compatible key") }
            if closeTempo { reasons.append("close tempo") }
            if sameGenre { reasons.append(row.genre) }
            else if sameArtist { reasons.append("same artist") }
            return (row, TrackMatch(id: row.id, group: group, score: score, reason: reasons.prefix(3).joined(separator: " · ")))
        }.sorted {
            if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
            let order = $0.0.title.localizedStandardCompare($1.0.title)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }
        var ids = Set<String>(), files = Set<String>(), hashes = Set<String>()
        let unique = ranked.filter { row, _ in
            guard ids.insert(row.id).inserted,
                  files.insert(row.location.standardizedFileURL.path).inserted else { return false }
            if let hash = row.hash, !hashes.insert(hash).inserted { return false }
            return true
        }
        // Reserve up to eight places per group, then fill by score. This keeps alternatives
        // visible without forcing equal shares of weak and strong matches.
        var pools = MatchGroup.allCases.map { group in unique.filter { $0.1.group == group } }
        var chosen: [(TrackRow, TrackMatch)] = [], artists: [String: Int] = [:]
        func take(_ pool: inout [(TrackRow, TrackMatch)]) {
            let pick = pool.firstIndex {
                let artist = normalized($0.0.artist)
                return artist.isEmpty || artists[artist, default: 0] < 3
            } ?? 0
            let item = pool.remove(at: pick)
            chosen.append(item)
            let artist = normalized(item.0.artist)
            if !artist.isEmpty { artists[artist, default: 0] += 1 }
        }
        let reserved = min(8, limit / 3)
        for _ in 0..<reserved {
            for i in pools.indices where !pools[i].isEmpty { take(&pools[i]) }
        }
        let picked = Set(chosen.map { $0.0.id })
        var remaining = unique.filter { !picked.contains($0.0.id) }
        while chosen.count < limit && !remaining.isEmpty {
            take(&remaining)
        }
        return chosen.sorted {
            if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
            let order = $0.0.title.localizedStandardCompare($1.0.title)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }.map(\.1)
    }
}
