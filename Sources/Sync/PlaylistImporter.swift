import DeckhandCore
import Foundation
import OneLibrary

/// Matches a drive's existing playlists (e.g. from a Rekordbox export) to Apple Music tracks,
/// so they can be recreated in Apple Music.
public struct PlaylistImporter {
    public enum Method: String, Sendable { case identicalFile, metadata, audioHash, sameRecording }

    public struct PlaylistPlan: Sendable {
        public var source: DeviceLibrary.Playlist
        /// Apple Music track IDs in playlist order (unmatched entries omitted).
        public var trackIds: [String]
        public var unmatched: [DeviceLibrary.Track]
        /// An Apple Music playlist with this name already exists.
        public var existsInAppleMusic: Bool
    }

    public struct Plan: Sendable {
        public var playlists: [PlaylistPlan]
        public var methods: [Method: Int]
        /// Drive tracks with no Apple Music match (all tracks when `includeAllTracks`, else playlist members).
        public var missing: [DeviceLibrary.Track]
        /// Drive content ID → Apple Music track ID.
        public var matches: [Int: String]
    }

    let volume: Volume
    let device: DeviceLibrary
    let songs: [SourceTrack]
    let cache: AnalysisCache

    public init(volume: Volume, device: DeviceLibrary, songs: [SourceTrack], cache: AnalysisCache) {
        self.volume = volume
        self.device = device
        self.songs = songs
        self.cache = cache
    }

    /// `existingNames`: Apple Music playlist names. `only`: restrict to these playlist names.
    /// `includeAllTracks`: also match tracks that aren't in any selected playlist, so `missing`
    /// covers the whole drive.
    public func plan(existingNames: Set<String>, only: Set<String>? = nil, includeAllTracks: Bool = false,
                     progress: (Int, Int) -> Void = { _, _ in }) throws -> Plan {
        let wanted = device.playlists.filter { only == nil || only!.contains($0.name) }
        let needed = includeAllTracks ? Set(device.tracks.keys) : Set(wanted.flatMap(\.contentIds))
        var match: [Int: String] = [:]
        var methods: [Method: Int] = [:]

        let local = songs.filter { $0.location != nil }
        var bySizeTitle: [String: [SourceTrack]] = [:]
        var byMeta: [String: [SourceTrack]] = [:]
        var byRecording: [String: [SourceTrack]] = [:]
        for s in local {
            let size = FileOps.size(s.location!)
            bySizeTitle["\(size)|\(Self.norm(s.title))", default: []].append(s)
            byMeta["\(Self.norm(s.title))|\(Self.norm(s.artist ?? ""))", default: []].append(s)
            byRecording[Self.recordingKey(title: s.title, artist: s.artist ?? ""), default: []].append(s)
        }
        var hashIndex: [String: String]?

        for (i, id) in needed.sorted().enumerated() {
            progress(i + 1, needed.count)
            guard let t = device.tracks[id] else { continue }
            if let s = bySizeTitle["\(t.fileSize)|\(Self.norm(t.title))"]?.first {
                match[id] = s.id; methods[.identicalFile, default: 0] += 1
                continue
            }
            let candidates = (byMeta["\(Self.norm(t.title))|\(Self.norm(t.artist))"] ?? [])
                .filter { abs(($0.durationSeconds ?? 0) - Double(t.durationSeconds)) <= 2 }
            if candidates.count == 1 {
                match[id] = candidates[0].id; methods[.metadata, default: 0] += 1
                continue
            }
            // Ambiguous or renamed: compare audio content.
            let file = volume.url(forUsbPath: t.usbPath)
            guard FileManager.default.fileExists(atPath: file.path), let h = try? cache.contentHash(of: file) else { continue }
            if hashIndex == nil {
                hashIndex = [:]
                for s in local { if let sh = try? cache.contentHash(of: s.location!) { hashIndex![sh] = s.id } }
                try? cache.saveFingerprints()
            }
            if let sid = hashIndex![h] {
                match[id] = sid; methods[.audioHash, default: 0] += 1
                continue
            }
            // A different file of the same recording (another download/encode): same title, same
            // artists in any order, near-identical length.
            let same = (byRecording[Self.recordingKey(title: t.title, artist: t.artist)] ?? [])
                .filter { abs(($0.durationSeconds ?? 0) - Double(t.durationSeconds)) <= 3 }
            if same.count == 1 { match[id] = same[0].id; methods[.sameRecording, default: 0] += 1 }
        }

        let plans = wanted.map { p in
            PlaylistPlan(source: p, trackIds: p.contentIds.compactMap { match[$0] },
                         unmatched: p.contentIds.filter { match[$0] == nil }.compactMap { device.tracks[$0] },
                         existsInAppleMusic: existingNames.contains(p.name))
        }
        let missing = needed.sorted().filter { match[$0] == nil }.compactMap { device.tracks[$0] }
        return Plan(playlists: plans, methods: methods, missing: missing, matches: match)
    }

    static func recordingKey(title: String, artist: String) -> String {
        let artists = artist.components(separatedBy: CharacterSet(charactersIn: ",&;/"))
            .flatMap { $0.components(separatedBy: " feat. ") }
            .map(norm).filter { !$0.isEmpty }.sorted()
        return norm(title) + "|" + artists.joined(separator: "+")
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Playlist plans after adding `added` (drive content ID → new Apple Music track ID).
    public static func resolve(_ plan: Plan, added: [Int: String]) -> [PlaylistPlan] {
        let matches = plan.matches.merging(added) { a, _ in a }
        return plan.playlists.map { p in
            var p = p
            p.trackIds = p.source.contentIds.compactMap { matches[$0] }
            p.unmatched = p.unmatched.filter { matches[$0.contentId] == nil }
            return p
        }
    }
}
