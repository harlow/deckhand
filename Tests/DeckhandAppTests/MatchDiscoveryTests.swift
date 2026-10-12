@testable import DeckhandApp
import Analysis
import AVFoundation
import DeckhandCore
import MusicSource
import Sync
import Testing

@Suite struct MatchDiscoveryTests {
    private func row(_ id: String, key: String? = "8A", bpm: Double? = 120, energy: Int? = 5, genre: String = "House", artist: String = "") -> TrackRow {
        let file = URL(fileURLWithPath: "/music/\(id).wav")
        var row = TrackRow(id: id, source: SourceTrack(id: id, title: id, location: file), title: id,
            artist: artist, genre: genre, duration: 20, location: file, dateAdded: .distantPast)
        row.key = key.flatMap(MusicalKey.init(parsing:)); row.bpm = bpm; row.energy = energy
        return row
    }

    @Test func limitsToFiftyBestUniqueTracksInStableOrder() {
        let seed = row("seed")
        let candidates = (0..<80).map { row("Song \($0)", bpm: Double(120 + $0 % 5)) }
        let first = MatchDiscovery.rank(seed: seed, candidates: candidates + [seed])
        #expect(first.count == 50 && !first.contains { $0.id == seed.id })
        #expect(first == MatchDiscovery.rank(seed: seed, candidates: candidates.reversed()))
        #expect(Set(first.map(\.id)).count == 50)
        #expect(first.first?.id == "Song 0")
    }

    @Test func groupsExplainKeyTempoAndEnergyWithoutClaimingAudioSimilarity() {
        let ranked = MatchDiscovery.rank(seed: row("seed"), candidates: [
            row("smooth", key: "9A"), row("lift", energy: 8), row("turn", key: "3B")])
        #expect(ranked.first { $0.id == "smooth" }?.group == .smooth)
        #expect(ranked.first { $0.id == "lift" }?.group == .lift)
        #expect(ranked.first { $0.id == "turn" }?.group == .changeDirection)
        #expect(ranked.first { $0.id == "lift" }?.reason.contains("energy +3") == true)
    }

    @Test func excludesUnavailableUnrelatedExtremeTempoAndDuplicateFilesOrHashes() {
        var seed = row("seed"); seed.hash = "seed-hash"
        var copy = row("seed copy"); copy.hash = seed.hash
        var duplicate = row("duplicate"); duplicate.location = row("good").location
        var unavailable = row("protected"); unavailable.source.unavailableReason = "DRM"
        let tracks = [seed, copy, duplicate, unavailable, row("good"), row("offline"),
            row("unrelated", key: "3B", genre: "Jazz"), row("fast", bpm: 180)]
        let result = MatchDiscovery.rank(seed: seed, candidates: tracks, excluding: ["offline"])
        #expect(result.count == 1 && ["duplicate", "good"].contains(result[0].id))
    }

    @Test func missingAnalysisUsesMetadataAndInvalidNumbersStayFinite() {
        let seed = row("seed", key: nil, bpm: .nan, energy: nil)
        let result = MatchDiscovery.rank(seed: seed, candidates: [row("genre", key: nil, bpm: .infinity),
            row("nothing", key: nil, bpm: nil, genre: "", artist: "")])
        #expect(result.count == 1 && result[0].id == "genre" && result[0].score.isFinite)
        #expect(result[0].group == .changeDirection && result[0].reason == "House")
        #expect(MatchDiscovery.rank(seed: seed, candidates: [], limit: 0).isEmpty)
    }
}

@MainActor @Suite struct MatchesModelTests {
    /// Real audio, cache and SQLite fixture; every file has a unique hash. Also used for native QA.
    private func populate(_ root: URL, count: Int = 62) throws -> (SourceLibrary, AnalysisCache) {
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let cache = try AnalysisCache(root: root.appendingPathComponent("Cache"))
        var tracks: [String: SourceTrack] = [:]
        for n in 0..<count {
            let id = "song-\(n)", title = n == 0 ? "Seed Song" : "Match \(n)"
            let file = audio.appendingPathComponent(id + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000)!
            pcm.frameLength = pcm.frameCapacity
            memset(pcm.floatChannelData![0], 0, Int(pcm.frameLength) * MemoryLayout<Float>.size)
            pcm.floatChannelData![0][0] = Float(n + 1) * 0.00001
            do { let output = try AVAudioFile(forWriting: file, settings: format.settings); try output.write(from: pcm) }
            let bpm = Double(120 + n % 5), key = n % 3 == 2 ? "3B" : "8A"
            let energy = n % 3 == 1 ? 8 : 5
            let bands = (0..<300).map { Float($0 % 30 + 1) / 60 }
            let wave = TrackAnalysis.Waveforms(peak: bands, rms: bands, low: bands, mid: bands, high: bands)
            let analysis = TrackAnalysis(durationSeconds: 20, sampleRate: 8000, bpm: bpm,
                beats: (0..<40).map { .init(barPosition: $0 % 4 + 1, timeMs: $0 * 500, bpm: bpm) },
                key: MusicalKey(parsing: key), waveforms: wave)
            try cache.store(analysis, cues: .init(cues: [.init(timeMs: 8000, energy: energy)], energy: energy),
                sections: [], forHash: cache.contentHash(of: file))
            tracks[id] = SourceTrack(id: id, title: title, artist: "QA Artist \(n % 6)", genre: "House",
                durationSeconds: 20, location: file)
        }
        try cache.save()
        var music = SourceLibrary(playlists: [SourcePlaylist(id: "origin", name: "My Set", trackIds: ["song-0"]),
            SourcePlaylist(id: "other", name: "Other Set", trackIds: [])], tracks: tracks)
        music.allTrackIds = (0..<count).map { "song-\($0)" }
        return (music, cache)
    }

    private func loaded(_ root: URL) async throws -> LibraryModel {
        let (music, cache) = try populate(root)
        let model = LibraryModel(libraryDirectory: root.appendingPathComponent("Library"), legacyDirectory: root.appendingPathComponent("Legacy"),
            defaults: UserDefaults(suiteName: root.lastPathComponent)!, observesChanges: false, cache: cache,
            musicImport: { music }, driveReader: { [] })
        await model.load(); await model.connect(SourceConnection(kind: .music))
        for _ in 0..<300 where model.rows.values.contains(where: { !$0.checked }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.rows.count == 62 && model.unanalyzedCount == 0)
        return model
    }

    @Test func pinnedSeedDestinationDedupAndViewRestorationSurviveRealPlaybackAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matches-test-\(UUID())")
        defer { UserDefaults(suiteName: root.lastPathComponent)?.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let model = try await loaded(root)
        let origin = try #require(model.playlists.first { $0.name == "My Set" })
        let seed = try #require(model.rows.values.first { $0.title == "Seed Song" })
        model.selection = .playlist(origin.id); model.filter.search = "Seed"; model.sort = TrackSort(column: .title, ascending: false)
        model.trackSelection = [seed.id]
        model.openMatches(seed: seed)
        #expect(model.matches?.tracks.count == 50 && model.matches?.seed.id == seed.id)
        #expect(model.matchDestination?.id == origin.id && model.filter.isEmpty && model.sort == nil)
        let first = try #require(model.listing(playing: seed).rows.first)
        let player = Player(); defer { player.reset() }
        player.play(first, continuingIn: model.listing(playing: seed).rows)
        #expect(player.current?.id == first.id && model.matches?.seed.id == seed.id)
        let all = model.listing(playing: player.current).rows.map(\.id)
        #expect(all.count == 50 && !all.contains(seed.id))
        await model.addMatches([first.id]); await model.addMatches([first.id])
        #expect(model.matchDestination?.trackIds == [seed.id, first.id])
        #expect(model.notice == "Already in My Set" && model.matches?.seed.id == seed.id)
        model.matchGroup = .lift
        #expect(model.listing(playing: player.current).rows.allSatisfy { row in model.matches!.tracks.first { $0.id == row.id }!.group == .lift })
        model.openMatches(seed: first) // Explicit reseeding keeps the original return state and destination.
        model.endMatches()
        #expect(model.selection == .playlist(origin.id) && model.filter.search == "Seed")
        #expect(model.sort == TrackSort(column: .title, ascending: false) && model.trackSelection == [seed.id])
        #expect(player.current?.id == first.id) // Going back does not interrupt listening.
        await model.closeLibrary()
        let reopened = LibraryModel(libraryDirectory: root.appendingPathComponent("Library"), legacyDirectory: root.appendingPathComponent("Legacy"),
            defaults: UserDefaults(suiteName: root.lastPathComponent)!, observesChanges: false, driveReader: { [] })
        await reopened.load()
        #expect(reopened.matches == nil && reopened.playlists.first { $0.id == origin.id }?.trackIds == [seed.id, first.id])
        await reopened.closeLibrary()
    }

    @Test func allTracksHasNoImplicitDestinationAndSidebarNavigationLeavesTemporaryList() async throws {
        let f = try DedicatedLibraryModelTests.Fixture()
        defer { UserDefaults(suiteName: f.root.lastPathComponent)?.removePersistentDomain(forName: f.root.lastPathComponent) }
        let model = try await loaded(f.root)
        let seed = try #require(model.rows.values.first { $0.title == "Seed Song" })
        model.selection = .all; model.trackSelection = [seed.id]
        model.openMatches(seed: seed)
        #expect(model.matchDestination == nil)
        let before = model.playlists
        await model.addMatches([model.matches!.tracks[0].id])
        #expect(model.playlists == before)
        model.sort = TrackSort(column: .bpm, ascending: true)
        model.openMatches(seed: seed); model.endMatches()
        #expect(model.sort == nil) // An originally absent sort is preserved across reseeding.
        model.openMatches(seed: seed); model.openSidebarItem(.all)
        #expect(model.matches == nil && model.trackSelection == [seed.id])
        model.openMatches(seed: seed); model.selection = .needsAnalysis
        #expect(model.matches == nil && model.selection == .needsAnalysis)
        await model.closeLibrary()
    }

    @Test func exportNativeFixtureOnlyWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["DECKHAND_MATCHES_QA_DIR"], path.hasPrefix("/tmp/deckhand-matches-qa-") else { return }
        let model = try await loaded(URL(fileURLWithPath: path))
        model.selection = .playlist(try #require(model.playlists.first { $0.name == "My Set" }).id)
        await model.closeLibrary()
    }
}
