import CryptoKit
import Foundation

/// Deckhand's record of what it wrote to a drive, stored at `/.deckhand/manifest.json`.
/// Not read by DJ players. Written last on every sync.
public struct Manifest: Codable, Sendable {
    public static let currentFormat = 1
    static let directory = ".deckhand"
    static let fileName = "manifest.json"

    public struct Track: Codable, Sendable, Equatable {
        public var contentId: Int
        public var usbPath: String
        public var contentHash: String
        public var analysisVersion: Int
        /// Inputs the ANLZ files were last written from (cues, writer options); a change forces a rewrite.
        public var anlzFingerprint: String?
        /// Cache entry, settings and build `anlzFingerprint` was computed from; while unchanged the
        /// fingerprint is too, so checking it needs no decoding.
        public var anlzInputs: String? = nil
        /// The track's database fields (title, rating, …) when last written; a change rewrites the database.
        public var metadataFingerprint: String?
        /// Artwork hash, valid while `artworkKey` (audio file and track modification) is unchanged.
        public var artworkKey: String? = nil
        public var artworkHash: String? = nil
    }

    public struct Playlist: Codable, Sendable, Equatable {
        public var playlistId: Int
        public var name: String
        public var parentPlaylistId: Int?
        public var sequenceNo: Int
        public var contentIds: [Int]
    }

    public var format = Manifest.currentFormat
    public var deviceId = UUID().uuidString
    public var createdAt = Date()
    public var lastSyncedAt: Date?
    /// Source playlist IDs the user selected for this drive.
    public var selectedPlaylistIds: [String] = []
    /// Sync every song and every playlist (selection follows the library). Optional for older manifests.
    public var entireLibrary: Bool?
    /// Keyed by source track ID.
    public var tracks: [String: Track] = [:]
    /// Keyed by source playlist ID.
    public var playlists: [String: Playlist] = [:]
    public var nextContentId = 1
    public var nextPlaylistId = 1
    /// Output settings chosen for this drive (cue source, hot cue style, key format, …).
    public var settings: [String: String]?
    /// Artwork content hash → image ID. Optional so older manifests still decode.
    public var artwork: [String: Int]?
    public var nextImageId: Int?

    /// Incremented on every save; picks the newer of the two manifest files. Optional for older manifests.
    public var generation: Int?

    public init() {}

    static func url(on volume: Volume) -> URL {
        volume.url.appendingPathComponent(directory).appendingPathComponent(fileName)
    }

    /// The manifest is saved alternately to two files, overwriting the older one in place: on FAT sticks creating
    /// and renaming files costs ~0.5 s each, and a write cut short leaves the other copy intact.
    static func urls(root: URL) -> [URL] {
        let dir = root.appendingPathComponent(directory)
        return [dir.appendingPathComponent(fileName), dir.appendingPathComponent("manifest-b.json")]
    }

    public static func load(from volume: Volume) throws -> Manifest? { try load(root: volume.url) }

    static func load(root: URL) throws -> Manifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var firstError: Error?
        var newest: Manifest?
        for u in urls(root: root) where FileManager.default.fileExists(atPath: u.path) {
            do {
                let m = try decoder.decode(Manifest.self, from: Data(contentsOf: u))
                if (m.generation ?? 0) >= (newest?.generation ?? -1) { newest = m }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let newest { return newest }
        if let firstError { throw firstError }
        return nil
    }

    public func save(to volume: Volume) throws { try save(root: volume.url) }

    func save(root: URL) throws {
        var m = self
        m.generation = (generation ?? 0) + 1
        let target = Self.urls(root: root)[m.generation! % 2 == 1 ? 0 : 1]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileOps.write(try encoder.encode(m), to: target)
    }
}

extension Manifest {
    /// Fingerprints are stored as short digests (full ones run to kilobytes per track). Older manifests hold the
    /// full strings, which still match.
    public static func digest(_ fingerprint: String) -> String {
        "d:" + SHA256.hash(data: Data(fingerprint.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ stored: String?, _ fingerprint: String) -> Bool {
        stored == fingerprint || stored == digest(fingerprint)
    }
}
