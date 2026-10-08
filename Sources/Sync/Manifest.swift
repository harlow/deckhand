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

    public init() {}

    static func url(on volume: Volume) -> URL {
        volume.url.appendingPathComponent(directory).appendingPathComponent(fileName)
    }

    public static func load(from volume: Volume) throws -> Manifest? {
        let u = url(on: volume)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: u))
    }

    public func save(to volume: Volume) throws {
        let u = Self.url(on: volume)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileOps.writeAtomically(try encoder.encode(self), to: u)
    }
}
