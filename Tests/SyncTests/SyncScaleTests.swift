import DeckhandCore
import Foundation
import Testing
@testable import Sync

/// evaluate must stay cheap enough for the app to call on a 20k-track library off the main thread.
@Suite struct SyncScaleTests {
    @Test func evaluatesTwentyThousandTracksQuickly() throws {
        let n = 20_000
        var tracks: [String: SourceTrack] = [:]
        var facts: [String: TrackFacts] = [:]
        var ids: [String] = []
        for i in 0..<n {
            let id = String(format: "%016X", i)
            ids.append(id)
            tracks[id] = SourceTrack(id: id, title: "Title \(i)", artist: "Artist \(i % 500)", album: "Album \(i % 2000)",
                                     genre: "House", rating: i % 6, durationSeconds: 300,
                                     location: URL(fileURLWithPath: "/Music/\(i).mp3"),
                                     dateAdded: Date(timeIntervalSince1970: 1_600_000_000 + Double(i)),
                                     modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
            let hash = "a2:" + String(repeating: String(format: "%08x", i), count: 8)
            facts[id] = TrackFacts(audio: .ok(hash: hash, size: 10_000_000, modified: 1_700_000_000),
                                   analysis: AnalysisFacts(revision: "r\(i)", bpm: 124, key: MusicalKey(tonic: i % 12, mode: .minor),
                                                           energy: i % 10, durationSeconds: 300, sampleRate: 44100))
        }
        let playlists = (0..<50).map { p in
            SourcePlaylist(id: "P\(p)", name: "Playlist \(p)", trackIds: Array(ids[(p * 400)..<((p + 1) * 400)]))
        }
        var library = SourceLibrary(playlists: playlists, tracks: tracks)
        library.allTrackIds = ids
        var manifest = Manifest()
        manifest.selectedPlaylistIds = playlists.map(\.id)
        manifest.entireLibrary = true
        var profile = OutputProfile()
        profile.artwork = false

        var start = Date()
        let first = SyncStatus.evaluate(library: library, manifest: manifest, facts: facts, drive: DriveProbe(), profile: profile)
        let initial = Date().timeIntervalSince(start)
        #expect(first.summary.toCopy == n)

        // As after that sync: every file on the drive, the manifest as planned plus what the executor records.
        var probe = DriveProbe()
        probe.databaseId = "db"
        var synced = first.nextManifest
        synced.lastSyncedAt = Date()
        synced.databaseId = "db"
        synced.generation = 2
        for t in first.tracks {
            probe.addAudio(t.usbPath!)
            probe.addAnlz(forAudio: t.usbPath!)
            synced.tracks[t.id]!.anlzFingerprint = "d:x"
            synced.tracks[t.id]!.anlzInputs = Manifest.digest(SyncStatus.anlzInputs(t.facts.analysis!, key: profile.anlzKey))
        }
        start = Date()
        let clean = SyncStatus.evaluate(library: library, manifest: synced, facts: facts, drive: probe, profile: profile)
        let noop = Date().timeIntervalSince(start)
        #expect(clean.isClean, "\(clean.summary)")
        print("evaluate 20k tracks: first \(String(format: "%.3f", initial)) s, clean \(String(format: "%.3f", noop)) s")
        #expect(noop < 3, "evaluate took \(noop) s")
    }
}
