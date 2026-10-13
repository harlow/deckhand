@testable import DeckhandApp
import Analysis
import DeckhandLibrary
import Foundation
import Sync
import Testing

/// Opt-in, read-only evaluation of the real collection. The normal test suite uses fixtures.
/// No audio is decoded, no cache is saved, and the library database opens read-only.
@MainActor struct AudioMatchEvaluationTests {
    @Test func compareTwentySeedsWithMetadataOnlyRanking() throws {
        guard let reportPath = ProcessInfo.processInfo.environment["DECKHAND_AUDIO_MATCH_REPORT"] else { return }
        let saved = try DeckhandLibraryStore.savedLibrary()
        let music = try #require(saved)
        let cache = try AnalysisCache()
        let start = Date()
        let candidates = (music.allTrackIds ?? Array(music.tracks.keys)).compactMap { id -> TrackRow? in
            guard let track = music.tracks[id], let location = track.location, track.unavailableReason == nil,
                  let hash = cache.cachedContentHash(of: location), let summary = cache.summary(forHash: hash) else { return nil }
            var row = TrackRow(id: id, source: track, title: track.title, artist: track.artist ?? "", genre: track.genre ?? "",
                duration: summary.durationSeconds, location: location, dateAdded: track.dateAdded ?? .distantPast)
            row.hash = hash; row.bpm = summary.bpm; row.key = summary.key; row.energy = summary.energy
            row.matchProfile = cache.cachedMatchProfile(forHash: hash) ?? cache.matchProfile(forHash: hash)
            return row
        }.sorted { $0.id < $1.id }
        let extractionSeconds = Date().timeIntervalSince(start)
        let seeds = candidates.filter { $0.matchProfile?.groove != nil }
        #expect(seeds.count >= 20)
        let sample = stride(from: 0, to: seeds.count, by: max(1, seeds.count / 20)).prefix(20).map { seeds[$0] }
        let metadataOnly = candidates.map { row -> TrackRow in var row = row; row.matchProfile = nil; return row }
        var overlaps: [Int] = [], durations: [Double] = [], groups: [String: Int] = [:]
        for seed in sample {
            var plainSeed = seed; plainSeed.matchProfile = nil
            let baseline = MatchDiscovery.rank(seed: plainSeed, candidates: metadataOnly)
            let before = Date()
            let matches = MatchDiscovery.rank(seed: seed, candidates: candidates)
            durations.append(Date().timeIntervalSince(before))
            overlaps.append(Set(matches.prefix(10).map(\.id)).intersection(baseline.prefix(10).map(\.id)).count)
            for match in matches { groups[match.group.rawValue, default: 0] += 1 }
            #expect(!matches.isEmpty && matches.count <= 50 && matches.allSatisfy { $0.score.isFinite })
        }
        let report: [String: Any] = ["evaluatedSeeds": sample.count, "analyzedCandidates": candidates.count,
            "textureProfiles": candidates.filter { $0.matchProfile != nil }.count,
            "grooveProfiles": seeds.count, "descriptorReadSeconds": extractionSeconds,
            "meanRankMilliseconds": durations.reduce(0, +) / Double(max(1, durations.count)) * 1000,
            "maximumRankMilliseconds": (durations.max() ?? 0) * 1000,
            "meanTopTenOverlapWithMetadataOnly": Double(overlaps.reduce(0, +)) / Double(max(1, overlaps.count)),
            "groupCountsAcrossSeeds": groups,
            "note": "Metadata-only baseline uses the same group/diversity rules. This measures behavior and latency, not listening preference."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
