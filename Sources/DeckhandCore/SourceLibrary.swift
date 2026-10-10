import Foundation

/// A track from the source library (e.g. Apple Music), normalized.
public struct SourceTrack: Codable, Sendable, Hashable, Identifiable {
    /// Stable source identity, e.g. the Apple Music persistent ID in hex.
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    /// 0–5 stars.
    public var rating: Int?
    public var comment: String?
    public var durationSeconds: Double?
    /// Local file, if the track has one.
    public var location: URL?
    /// Why the track can't be exported even if it has a location (e.g. DRM-protected).
    public var unavailableReason: String?
    public var dateAdded: Date?
    /// Listening history from the music app (used for suggestions, never written to the drive).
    public var playCount: Int?
    public var skipCount: Int?
    public var lastPlayed: Date?
    /// When the track (tags, artwork, …) was last changed in the music app.
    public var modifiedDate: Date?

    public init(id: String, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil,
                rating: Int? = nil, comment: String? = nil, durationSeconds: Double? = nil, location: URL? = nil,
                unavailableReason: String? = nil, dateAdded: Date? = nil,
                playCount: Int? = nil, skipCount: Int? = nil, lastPlayed: Date? = nil, modifiedDate: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.rating = rating
        self.comment = comment
        self.durationSeconds = durationSeconds
        self.location = location
        self.unavailableReason = unavailableReason
        self.dateAdded = dateAdded
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.modifiedDate = modifiedDate
    }
}

/// A playlist or folder from the source library.
public struct SourcePlaylist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var isFolder: Bool
    /// Track IDs in order. May contain duplicates.
    public var trackIds: [String]

    public init(id: String, name: String, parentId: String? = nil, isFolder: Bool = false, trackIds: [String] = []) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.isFolder = isFolder
        self.trackIds = trackIds
    }
}

/// Supplies cover art for source tracks, as encoded image data (JPEG/PNG).
public protocol ArtworkProvider: Sendable {
    func artwork(forTrackId id: String) -> Data?
}

/// A snapshot of the source library: all playlists (in source order) and the tracks they reference.
public struct SourceLibrary: Codable, Sendable {
    public var playlists: [SourcePlaylist]
    public var tracks: [String: SourceTrack]
    /// Every song in the library in library order, when loaded with all songs (else nil).
    public var allTrackIds: [String]?
    /// Cover art lookup, if the source can provide it. Not persisted.
    public var artwork: (any ArtworkProvider)?

    enum CodingKeys: String, CodingKey { case playlists, tracks, allTrackIds }

    public init(playlists: [SourcePlaylist], tracks: [String: SourceTrack], artwork: (any ArtworkProvider)? = nil) {
        self.playlists = playlists
        self.tracks = tracks
        self.artwork = artwork
    }

    /// Finds playlists by exact name or ID.
    public func playlist(named nameOrId: String) -> SourcePlaylist? {
        playlists.first { $0.id == nameOrId } ?? playlists.first { $0.name == nameOrId }
            ?? playlists.first { $0.name.localizedCaseInsensitiveCompare(nameOrId) == .orderedSame }
    }

    /// The selected playlists plus their ancestor folders, so hierarchy is preserved.
    public func selection(_ ids: Set<String>) -> [SourcePlaylist] {
        var keep = Set<String>()
        let byId = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        for id in ids {
            var cur: String? = id
            while let c = cur, let p = byId[c] {
                keep.insert(c)
                cur = p.parentId
            }
        }
        return playlists.filter { keep.contains($0.id) }
    }
}
