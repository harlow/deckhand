import DeckhandCore
import Foundation

/// A track as it will appear on the device, with USB-relative paths and device IDs assigned.
public struct ExportTrack: Sendable {
    public var contentId: Int
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var durationSeconds: Double
    public var bpm: Double?
    public var key: MusicalKey?
    public var color: TrackColor?
    /// 0–5 stars.
    public var rating: Int
    public var comment: String?
    /// USB-relative, e.g. "/Contents/Deckhand/AB/Track.mp3".
    public var usbPath: String
    public var fileSize: Int
    public var fileType: AudioFileType
    public var bitrateKbps: Int
    public var bitDepth: Int
    public var sampleRate: Int
    public var dateAdded: Date
    /// USB-relative path to the .DAT analysis file, if analyzed.
    public var analysisPath: String?
    /// USB-relative artwork path, if any.
    public var artworkPath: String?

    public init(contentId: Int, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil,
                durationSeconds: Double, bpm: Double? = nil, key: MusicalKey? = nil, color: TrackColor? = nil,
                rating: Int = 0, comment: String? = nil, usbPath: String, fileSize: Int, fileType: AudioFileType,
                bitrateKbps: Int, bitDepth: Int = 16, sampleRate: Int, dateAdded: Date = Date(),
                analysisPath: String? = nil, artworkPath: String? = nil) {
        self.contentId = contentId
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.key = key
        self.color = color
        self.rating = rating
        self.comment = comment
        self.usbPath = usbPath
        self.fileSize = fileSize
        self.fileType = fileType
        self.bitrateKbps = bitrateKbps
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.dateAdded = dateAdded
        self.analysisPath = analysisPath
        self.artworkPath = artworkPath
    }

    public var fileName: String { (usbPath as NSString).lastPathComponent }
}

/// A playlist or folder node. Order among siblings is `sequenceNo`.
public struct ExportPlaylist: Sendable {
    public var playlistId: Int
    public var name: String
    public var parentId: Int?
    public var isFolder: Bool
    public var sequenceNo: Int
    /// Content IDs in play order. Empty for folders.
    public var contentIds: [Int]

    public init(playlistId: Int, name: String, parentId: Int? = nil, isFolder: Bool = false, sequenceNo: Int, contentIds: [Int] = []) {
        self.playlistId = playlistId
        self.name = name
        self.parentId = parentId
        self.isFolder = isFolder
        self.sequenceNo = sequenceNo
        self.contentIds = contentIds
    }
}

public enum AudioFileType: Int, Sendable, Codable {
    case mp3 = 1
    case m4a = 4
    case flac = 5
    case wav = 11
    case aiff = 12

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3": self = .mp3
        case "m4a", "aac", "mp4": self = .m4a
        case "flac": self = .flac
        case "wav": self = .wav
        case "aif", "aiff": self = .aiff
        default: return nil
        }
    }
}
