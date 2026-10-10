import Analysis
import DeckhandCore
import Foundation
import Testing
@testable import Sync

@Suite struct AnalysisCacheTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-cache-\(UUID().uuidString)")

    func sample(bpm: Double = 124) -> TrackAnalysis {
        let n = 1000
        let wave = (0..<n).map { Float(($0 * 37) % 101) / 100 }
        return TrackAnalysis(durationSeconds: Double(n) / 150, sampleRate: 44100, bpm: bpm,
                             beats: (0..<16).map { .init(barPosition: $0 % 4 + 1, timeMs: $0 * 480, bpm: bpm) },
                             key: MusicalKey(tonic: 9, mode: .minor),
                             waveforms: .init(peak: wave, rms: wave, low: wave, mid: wave.reversed(), high: wave))
    }

    let cues = CueAnalyzer.Result(cues: [.init(timeMs: 1000, energy: 5), .init(timeMs: 4000, energy: 7)], energy: 6)

    func entry(_ hash: String) -> URL { root.appendingPathComponent("analysis/\(hash).json") }

    /// Rewrites a stored entry's JSON fields, as an older Deckhand would have written them.
    func edit(_ hash: String, _ change: (inout [String: Any]) -> Void) throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: entry(hash))) as! [String: Any]
        change(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: entry(hash))
    }

    @Test func summaryMatchesFullAnalysis() throws {
        let cache = try AnalysisCache(root: root)
        let a = sample()
        try cache.store(a, cues: cues, sections: [], forHash: "h1")
        let s = try #require(cache.summary(forHash: "h1"))
        let full = try #require(cache.analysis(forHash: "h1"))
        #expect(s.bpm == full.bpm && s.key == full.key && s.durationSeconds == full.durationSeconds && s.sampleRate == full.sampleRate)
        #expect(s.energy == 6 && s.cuesMs == [1000, 4000])
        // Same as reducing the full (quantized) waveform the way the app's overview does.
        let n = AnalysisCache.Summary.overviewBins
        let expected = (0..<n).map { i in
            full.waveforms.mid[(i * full.waveforms.mid.count / n)..<((i + 1) * full.waveforms.mid.count / n)].max()!
        }
        #expect(s.overview.mid == expected)
        #expect(cache.isAnalyzed("h1") && !cache.isAnalyzed("missing"))
    }

    @Test func backfillsFromLegacyEntryAndPersistsIndex() throws {
        let writer = try AnalysisCache(root: root)
        try writer.store(sample(), cues: cues, sections: [], forHash: "legacy")
        try writer.store(sample(), cues: cues, sections: [], forHash: "foreign")
        try writer.store(sample(), cues: cues, sections: [], forHash: "old")
        try edit("legacy") { $0["policy"] = "key-tags=0;bpm-hint=0;mik=0" }
        try edit("foreign") { $0["policy"] = "key-tags=1;bpm-hint=0;mik=1" }
        try edit("old") { $0["version"] = TrackAnalysis.currentVersion - 1 }

        // A cache with no index file, as after upgrading.
        let cache = try AnalysisCache(root: root)
        #expect(cache.summary(forHash: "legacy")?.bpm == 124)
        #expect(cache.summary(forHash: "foreign") == nil && cache.analysis(forHash: "foreign") == nil)
        #expect(cache.summary(forHash: "old") == nil && cache.analysis(forHash: "old") == nil)
        try cache.save()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("analysis-index.plist").path))

        // The index answers without reading the entry.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: entry("legacy").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entry("legacy").path) }
        let reopened = try AnalysisCache(root: root)
        #expect(reopened.analysis(forHash: "legacy") == nil)
        #expect(reopened.summary(forHash: "legacy")?.bpm == 124)
        #expect(reopened.summary(forHash: "foreign") == nil)
    }

    @Test func indexFollowsRewrittenAndRemovedEntries() throws {
        let cache = try AnalysisCache(root: root)
        try cache.store(sample(bpm: 120), cues: cues, sections: [], forHash: "h")
        #expect(cache.summary(forHash: "h")?.bpm == 120)
        try cache.save()

        // Rewritten by another process.
        let other = try AnalysisCache(root: root)
        try other.store(sample(bpm: 128), cues: cues, sections: [], forHash: "h")
        #expect(cache.summary(forHash: "h")?.bpm == 128)

        try FileManager.default.removeItem(at: entry("h"))
        #expect(cache.summary(forHash: "h") == nil)
    }
}

@Suite struct ManifestTests {
    @Test func olderManifestWithoutArtworkFieldsLoads() throws {
        let json = """
        {"format":1,"deviceId":"X","createdAt":"2026-01-01T00:00:00Z","selectedPlaylistIds":[],
         "tracks":{"A":{"contentId":1,"usbPath":"/Contents/a.mp3","contentHash":"h","analysisVersion":6,"anlzFingerprint":"f"}},
         "playlists":{},"nextContentId":2,"nextPlaylistId":1,"artwork":{"abc":1},"nextImageId":2}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(Manifest.self, from: Data(json.utf8))
        let t = try #require(m.tracks["A"])
        #expect(t.anlzFingerprint == "f" && t.artworkKey == nil && t.artworkHash == nil && t.anlzInputs == nil)
    }

    @Test func artworkFieldsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let volume = Volume(testRoot: root)
        var m = Manifest()
        m.tracks["A"] = .init(contentId: 1, usbPath: "/a.mp3", contentHash: "h", analysisVersion: 6,
                              anlzInputs: "i", artworkKey: "k", artworkHash: "abc")
        try m.save(to: volume)
        let t = try #require(try Manifest.load(from: volume)?.tracks["A"])
        #expect(t.artworkKey == "k" && t.artworkHash == "abc" && t.anlzInputs == "i")
    }
}
