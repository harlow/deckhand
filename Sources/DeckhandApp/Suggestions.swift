import DeckhandCore
import Foundation

/// Ranks unrated tracks by how likely you are to rate them 4★ or more, learned from the tracks you
/// have rated; Quick Rate plays them best guess first. Deliberately simple and explainable: each
/// signal adds or takes away points, and the biggest ones become the reason shown for the track.
struct Suggestion: Sendable {
    var id: String
    var score: Double
    /// Short reasons, strongest first, e.g. "played 14×", "you like 3 Kerri Chandler tracks".
    var reasons: [String]
}

enum Suggestions {
    /// Ranks `candidates` using what `rated` tells us. `playlists` maps track id → the playlists
    /// it's in (names), for "in playlists with tracks you like".
    static func rank(candidates: [TrackRow], rated: [TrackRow], playlists: [SourcePlaylist]) -> [Suggestion] {
        let liked = rated.filter { $0.rating >= 4 }
        let disliked = rated.filter { $0.rating <= 2 }

        // Like rate per value of a feature, smoothed toward the overall rate so one track doesn't
        // decide a whole artist: (likes + 2·base) / (likes + dislikes + 2).
        let base = Double(liked.count + 1) / Double(liked.count + disliked.count + 2)
        func affinity<K: Hashable>(_ key: (TrackRow) -> K?) -> [K: (rate: Double, likes: Int, total: Int)] {
            var counts: [K: (Int, Int)] = [:]
            for r in liked { if let k = key(r) { counts[k, default: (0, 0)].0 += 1 } }
            for r in disliked { if let k = key(r) { counts[k, default: (0, 0)].1 += 1 } }
            return counts.mapValues { l, d in ((Double(l) + 2 * base) / Double(l + d + 2), l, l + d) }
        }
        let byArtist = affinity { $0.artist.isEmpty ? nil : $0.artist.lowercased() }
        let byGenre = affinity { $0.genre.isEmpty ? nil : $0.genre }
        let byEnergy = affinity { $0.energy }
        let byTempo = affinity { $0.bpm.map { Int(($0 / 4).rounded()) } }

        // Playlists you've put liked tracks in say something about the others in them.
        let likedIds = Set(liked.map(\.id)), dislikedIds = Set(disliked.map(\.id))
        var playlistRate: [String: (rate: Double, name: String)] = [:]
        var playlistsOf: [String: [String]] = [:]
        for p in playlists where !p.isFolder && p.trackIds.count < 1000 {
            let l = p.trackIds.filter(likedIds.contains).count, d = p.trackIds.filter(dislikedIds.contains).count
            guard l + d >= 3 else { continue }
            playlistRate[p.id] = ((Double(l) + 2 * base) / Double(l + d + 2), p.name)
            for id in p.trackIds { playlistsOf[id, default: []].append(p.id) }
        }

        return candidates.map { r in
            var parts: [(points: Double, reason: String?)] = []

            let plays = r.source.playCount ?? 0, skips = r.source.skipCount ?? 0
            if plays > 0 { parts.append((0.5 * log2(1 + Double(plays)), plays >= 3 ? "played \(plays)×" : nil)) }
            if skips > 0 { parts.append((-0.7 * log2(1 + Double(skips)), "skipped \(skips)× in Music")) }

            if let a = byArtist[r.artist.lowercased()], a.total > 0 {
                let p = 3 * (a.rate - base)
                parts.append((p, p > 0.3 && a.likes > 0 ? "you like \(a.likes) \(r.artist) track\(a.likes == 1 ? "" : "s")" : nil))
            }
            if let g = byGenre[r.genre], g.total >= 3 {
                let p = 2 * (g.rate - base)
                parts.append((p, p > 0.25 ? "\(r.genre) is a genre you rate highly" : nil))
            }
            if let e = r.energy, let a = byEnergy[e], a.total >= 3 { parts.append((1 * (a.rate - base), nil)) }
            if let b = r.bpm, let a = byTempo[Int((b / 4).rounded())], a.total >= 3 { parts.append((1 * (a.rate - base), nil)) }

            if let best = (playlistsOf[r.id] ?? []).compactMap({ playlistRate[$0] }).max(by: { $0.rate < $1.rate }) {
                let p = 2 * (best.rate - base)
                parts.append((p, p > 0.3 ? "in \(best.name), full of tracks you like" : nil))
            }

            let score = parts.reduce(0) { $0 + $1.points }
            let reasons = parts.filter { $0.points > 0 && $0.reason != nil }
                .sorted { $0.points > $1.points }
                .prefix(2).map { $0.reason! }
            return Suggestion(id: r.id, score: score, reasons: reasons)
        }
        .sorted { $0.score > $1.score }
    }
}
