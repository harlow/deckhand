@testable import DeckhandApp
import Analysis
import AVFoundation
import DeckhandCore
import DeckhandLibrary
import MusicSource
import Sync
import Testing

@MainActor @Suite(.serialized) struct PlayerShortcutTests {
    @Test func playbackSeeksAndCuesUseTheGridAndKeepPauseState() async throws {
        // Retaining this fixture is optional, for the native keyboard walkthrough. It contains only
        // generated silent WAVs and synthetic analysis, never the user's Music library or USB.
        let retained = ProcessInfo.processInfo.environment["DECKHAND_SHORTCUT_QA_DIR"]
        let root = retained.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        let files = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let cache = try AnalysisCache(root: root.appendingPathComponent("Cache"))
        let beats = (0..<360).map { TrackAnalysis.Beat(barPosition: $0 % 4 + 1, timeMs: $0 * 500, bpm: 120) }
        let sections: [StructureAnalyzer.Section] = [
            .init(kind: .intro, startBeat: 0, startMs: 0, endMs: 32000, energy: 0.2),
            .init(kind: .drop, startBeat: 64, startMs: 32000, endMs: 64000, energy: 0.8),
            .init(kind: .breakdown, startBeat: 128, startMs: 64000, endMs: 96000, energy: 0.3),
            .init(kind: .drop, startBeat: 192, startMs: 96000, endMs: 160000, energy: 1),
            .init(kind: .outro, startBeat: 320, startMs: 160000, endMs: 180000, energy: 0.2),
        ]
        let analysis = TrackAnalysis(durationSeconds: 180, sampleRate: 8000, bpm: 120, beats: beats,
            key: MusicalKey(parsing: "8A"), waveforms: .init(peak: [0.1], rms: [0.05], low: [0.1], mid: [0.1], high: [0.1]))
        var tracks: [String: SourceTrack] = [:]
        var firstHash = ""
        for i in 1...3 {
            let url = files.appendingPathComponent("Song \(i).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8000 * (179 + i)))!
            buffer.frameLength = buffer.frameCapacity
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
            try file!.write(from: buffer)
            file = nil // Finalize the WAV header before hashing it or launching native QA.
            let hash = try cache.contentHash(of: url)
            try cache.store(analysis, cues: .init(cues: [], energy: 6), sections: sections, forHash: hash)
            if i == 1 { firstHash = hash }
            tracks["track-\(i)"] = SourceTrack(id: "track-\(i)", title: "Song \(i)", artist: "Keyboard Test",
                genre: "House", rating: 0, durationSeconds: Double(179 + i), location: url)
        }
        try cache.save()
        let store = try DeckhandLibraryStore(directory: root.appendingPathComponent("Library"))
        var imported = SourceLibrary(playlists: [
            SourcePlaylist(id: "test", name: "Keyboard Test", trackIds: ["track-1", "track-2", "track-3"]),
            SourcePlaylist(id: "target", name: "Target Playlist", trackIds: []),
        ], tracks: tracks)
        imported.allTrackIds = ["track-1", "track-2", "track-3"]
        let snapshot = try await store.importLibrary(imported, from: SourceConnection(kind: .folder, location: files))
        let source = try #require(snapshot.library.tracks.values.first { $0.title == "Song 1" })
        var row = TrackRow(id: source.id, source: source, title: source.title, artist: "Keyboard Test", genre: "House",
                           duration: 180, location: source.location!, dateAdded: .distantPast)
        row.hash = firstHash
        row.bpm = 120
        let player = Player()
        player.cache = cache
        defer { player.reset() }
        player.play(row)
        #expect(player.current?.id == row.id && player.isPlaying)
        for _ in 0..<100 where player.detail == nil { try await Task.sleep(for: .milliseconds(10)) }
        let detail = try #require(player.detail)
        player.pause()
        #expect(!player.isPlaying)
        player.seek(seconds: 80)
        player.jumpBeats(-64)
        #expect(abs(player.time - 48) < 0.01)
        player.jumpBeats(64)
        #expect(abs(player.time - 80) < 0.01)
        player.jumpToPreview()
        #expect(abs(player.time - 24) < 0.01) // 16 beats before the first drop at 32 seconds.
        player.seek(to: 0)
        #expect(player.time == 0 && !player.isPlaying)
        for slot in 1...5 {
            let cue = try #require(detail.hotCues.first { $0.slot == slot })
            #expect(player.jumpToHotCue(slot))
            #expect(abs(player.time - cue.position * player.duration) < 0.01)
            #expect(!player.isPlaying)
        }
        player.seek(to: 0)
        player.jumpBeats(-64)
        #expect(player.time == 0)
        player.seek(seconds: 170)
        player.jumpBeats(64)
        #expect(player.time <= player.duration)
        player.toggle()
        #expect(player.isPlaying)
        player.toggle()
        #expect(!player.isPlaying)
        await store.close()
        let suite = "KeyboardQA.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryModel(libraryDirectory: root.appendingPathComponent("Library"),
            legacyDirectory: root.appendingPathComponent("Legacy"), defaults: defaults,
            observesChanges: false, cache: cache, driveReader: { [] })
        await model.load()
        let order = model.playlistEntries.filter { !$0.playlist.isFolder }.map { SidebarItem.playlist($0.id) }
        #expect(order.count == 2)
        model.selection = .all
        model.selectAdjacentPlaylist(1)
        #expect(model.selection == order.first)
        model.selectAdjacentPlaylist(-1)
        #expect(model.selection == order.last)
        model.selectAdjacentPlaylist(1)
        #expect(model.selection == order.first)
        await model.closeLibrary()
    }
}
