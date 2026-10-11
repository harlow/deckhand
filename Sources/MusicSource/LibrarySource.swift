import AVFoundation
import CryptoKit
import DeckhandCore
import Foundation

/// A connection is stable even when its library snapshot changes. Music retains its original track IDs.
public struct SourceConnection: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case music, rekordbox, folder }
    public var id: String
    public var kind: Kind
    public var location: URL?

    public init(kind: Kind, location: URL? = nil, id: String = UUID().uuidString) {
        self.kind = kind
        self.location = location?.standardizedFileURL
        self.id = kind == .music ? "apple-music" : id
    }

    public var name: String {
        switch kind {
        case .music: "Apple Music / iTunes"
        case .rekordbox: "Rekordbox"
        case .folder: "Folder on Computer"
        }
    }

    public var detail: String {
        location?.path ?? "Your Music library · edits save in Deckhand"
    }

    public var snapshotSourceID: String? { kind == .music ? nil : id }
    public func trackID(_ externalID: String) -> String { "\(id):track:\(externalID)" }
    public func playlistID(_ path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(id):playlist:\(hash)"
    }
}

public struct IndexedAudioFile: Codable, Sendable {
    var identity: String
    var track: SourceTrack
}

public struct SourceRead: Sendable {
    public var library: SourceLibrary
    public var files: [String: IndexedAudioFile]
    /// Exact bytes parsed by an XML import, so cached cues cannot come from a later file revision.
    public var originalXML: Data? = nil
}

public protocol LibrarySourceAdapter: Sendable {
    var connection: SourceConnection { get }
    func load(files: [String: IndexedAudioFile]) async throws -> SourceRead
}

public enum LibrarySourceError: Error, LocalizedError {
    case unavailable(String), invalidXML(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidXML(let message): message
        }
    }
}

public struct FolderSource: LibrarySourceAdapter {
    public let connection: SourceConnection
    public init(connection: SourceConnection) { self.connection = connection }

    public func load(files: [String: IndexedAudioFile]) async throws -> SourceRead {
        guard let root = connection.location else { throw LibrarySourceError.unavailable("Choose a music folder.") }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values.isDirectory == true, values.isReadable != false else {
            throw LibrarySourceError.unavailable("The music folder isn't available. Reconnect its disk or choose another folder.")
        }
        var (urls, playlistFiles) = try Self.discover(root)
        urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let byIdentity = Dictionary(grouping: files.values, by: \.identity)
        var index = files
        var oldPaths = Dictionary(files.map { ($0.value.track.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        var tracks: [String: SourceTrack] = [:]
        var all: [String] = []
        var used = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            let identity = "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? "")"
            let previous = files[url.path] ?? byIdentity[identity]?.first(where: { !used.contains($0.track.id) })
            let size = (a[.size] as? NSNumber)?.int64Value
            let modified = a[.modificationDate] as? Date
            var track: SourceTrack
            if let old = previous, old.identity == identity, old.track.fileSize == size, old.track.modifiedDate == modified {
                track = old.track
            } else {
                track = await Self.metadata(url, id: previous?.track.id ?? connection.trackID(UUID().uuidString))
                track.dateAdded = previous?.track.dateAdded ?? (a[.creationDate] as? Date) ?? Date()
                track.fileSize = size
                track.modifiedDate = modified
            }
            track.location = url
            track.unavailableReason = nil
            used.insert(track.id)
            // Remove an old path for this same file after a move.
            if let path = oldPaths.removeValue(forKey: track.id), path != url.path { index[path] = nil }
            index[url.path] = IndexedAudioFile(identity: identity, track: track)
            tracks[track.id] = track
            all.append(track.id)
        }
        // Missing files stay identifiable so a transient deletion doesn't erase local playlist membership.
        for old in index.values where tracks[old.track.id] == nil {
            var t = old.track
            t.unavailableReason = "File is missing from the music folder"
            tracks[t.id] = t
            all.append(t.id)
        }
        let byPath = Dictionary(tracks.values.compactMap { t in t.location.map { ($0.standardizedFileURL.path, t.id) } },
                                uniquingKeysWith: { first, _ in first })
        let playlists = try playlistFiles.sorted(by: { $0.path < $1.path }).map { url in
            let content = try String(contentsOf: url, encoding: .utf8)
            let ids = content.components(separatedBy: .newlines).compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
                let location = value.hasPrefix("file:") ? URL(string: value)
                    : URL(fileURLWithPath: value, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                return location.flatMap { byPath[$0.standardizedFileURL.path] }
            }
            let relative = String(url.path.dropFirst(root.path.count))
            return SourcePlaylist(id: connection.playlistID(relative), name: url.deletingPathExtension().lastPathComponent, trackIds: ids)
        }
        var library = SourceLibrary(playlists: playlists, tracks: tracks)
        library.sourceID = connection.id
        library.allTrackIds = all
        library.artwork = FileArtwork(tracks: tracks)
        return SourceRead(library: library, files: index)
    }

    private static func discover(_ root: URL) throws -> ([URL], [URL]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    scanError = error; return false
                }) else { throw LibrarySourceError.unavailable("Couldn't read \(root.path).") }
        var audio: [URL] = [], playlists: [URL] = []
        for case let url as URL in enumerator {
            let v = try url.resourceValues(forKeys: keys)
            guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            if ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac"].contains(ext) { audio.append(url) }
            else if ["m3u", "m3u8"].contains(ext) { playlists.append(url) }
        }
        if let scanError { throw scanError }
        return (audio, playlists)
    }

    private static func metadata(_ url: URL, id: String) async -> SourceTrack {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var title: String?, artist: String?, album: String?
        for item in metadata {
            let value = try? await item.load(.stringValue)
            switch item.commonKey {
            case .commonKeyTitle: title = value
            case .commonKeyArtist: artist = value
            case .commonKeyAlbumName: album = value
            default: break
            }
        }
        let duration = (try? await asset.load(.duration))?.seconds
        let fullMetadata = (try? await asset.load(.metadata)) ?? []
        var genre: String?
        for item in fullMetadata where item.identifier == .iTunesMetadataUserGenre || item.identifier == .id3MetadataContentType {
            genre = try? await item.load(.stringValue)
        }
        return SourceTrack(id: id, title: title?.isEmpty == false ? title! : url.deletingPathExtension().lastPathComponent,
                           artist: artist, album: album, genre: genre, durationSeconds: duration?.isFinite == true ? duration : nil, location: url)
    }
}

/// File artwork is independent of the source application. Asset metadata reads run on sync/background queues.
public struct FileArtwork: ArtworkProvider {
    private let locations: [String: URL]
    public init(tracks: [String: SourceTrack]) { locations = tracks.compactMapValues(\.location) }
    public func artwork(forTrackId id: String) -> Data? {
        guard let url = locations[id] else { return nil }
        let asset = AVURLAsset(url: url)
        // Synchronous API is required by ArtworkProvider, always called off the main thread.
        return AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork,
                                             keySpace: .common).first?.dataValue
    }
}
