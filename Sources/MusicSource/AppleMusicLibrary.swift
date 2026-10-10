import DeckhandCore
import Foundation
import iTunesLibrary

public enum MusicSourceError: Error, CustomStringConvertible {
    case cannotOpenLibrary(Error)

    public var description: String {
        switch self {
        case .cannotOpenLibrary(let e):
            return "Could not read the Apple Music library: \(e.localizedDescription)\n"
                + "Make sure Music.app has a library and this terminal has Media & Apple Music access "
                + "(System Settings → Privacy & Security → Media & Apple Music)."
        }
    }
}

/// Reads playlists and tracks from the local Apple Music library via iTunesLibrary.framework.
/// Read-only; does not launch or script Music.app.
public enum AppleMusicLibrary {
    /// `allSongs`: also include songs that aren't in any user playlist (see `SourceLibrary.allTrackIds`).
    public static func load(allSongs: Bool = false) throws -> SourceLibrary {
        let lib: ITLibrary
        do {
            lib = try ITLibrary(apiVersion: "1.1")
        } catch {
            throw MusicSourceError.cannotOpenLibrary(error)
        }

        var playlists: [SourcePlaylist] = []
        var tracks: [String: SourceTrack] = [:]
        var items: [String: ITLibMediaItem] = [:]

        for p in lib.allPlaylists where isUserPlaylist(p) {
            let isFolder = p.kind == .folder
            var ids: [String] = []
            if !isFolder {
                for item in p.items where item.mediaKind == .kindSong {
                    let t = track(item)
                    tracks[t.id] = t
                    items[t.id] = item
                    ids.append(t.id)
                }
            }
            playlists.append(SourcePlaylist(
                id: hex(p.persistentID),
                name: p.name,
                parentId: p.parentID.map(hex),
                isFolder: isFolder,
                trackIds: ids
            ))
        }
        var all: [String]?
        if allSongs {
            all = []
            for item in lib.allMediaItems where item.mediaKind == .kindSong {
                let t = tracks[hex(item.persistentID)] ?? track(item)
                tracks[t.id] = t
                items[t.id] = item
                all!.append(t.id)
            }
        }
        var library = SourceLibrary(playlists: playlists, tracks: tracks, artwork: AppleMusicArtwork(library: lib, items: items))
        library.allTrackIds = all
        return library
    }

    /// Every song in the library (not only those in user playlists).
    public static func allSongs() throws -> [SourceTrack] {
        let lib: ITLibrary
        do {
            lib = try ITLibrary(apiVersion: "1.1")
        } catch {
            throw MusicSourceError.cannotOpenLibrary(error)
        }
        return lib.allMediaItems.filter { $0.mediaKind == .kindSong }.map(track)
    }

    /// Excludes the master library and built-in playlists (Music, Movies, Purchased, ...).
    private static func isUserPlaylist(_ p: ITLibPlaylist) -> Bool {
        !p.isMaster && p.distinguishedKind == .kindNone && p.isVisible && p.kind != .genius && p.kind != .geniusMix
    }

    private static func track(_ item: ITLibMediaItem) -> SourceTrack {
        var reason: String?
        if item.isDRMProtected {
            reason = "Protected (DRM) track; no exportable local file"
        } else if item.location == nil {
            reason = item.isCloud ? "Apple Music / iCloud track with no downloaded local file" : "Track has no local file"
        }
        let rating = item.isRatingComputed ? nil : item.rating / 20
        return SourceTrack(
            id: hex(item.persistentID),
            title: item.title,
            artist: item.artist?.name,
            album: item.album.title,
            albumArtist: item.album.albumArtist,
            genre: item.genre.isEmpty ? nil : item.genre,
            trackNumber: item.trackNumber > 0 ? item.trackNumber : nil,
            discNumber: item.album.discNumber > 0 ? item.album.discNumber : nil,
            year: item.year > 0 ? item.year : nil,
            rating: rating,
            comment: item.comments,
            durationSeconds: item.totalTime > 0 ? Double(item.totalTime) / 1000 : nil,
            location: reason == nil ? item.location : nil,
            unavailableReason: reason,
            dateAdded: item.addedDate,
            playCount: item.playCount,
            skipCount: item.skipCount,
            lastPlayed: item.lastPlayedDate,
            modifiedDate: item.modifiedDate,
            fileSize: item.fileSize > 0 ? Int64(item.fileSize) : nil
        )
    }

    private static func hex(_ n: NSNumber) -> String {
        let s = String(n.uint64Value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }
}

/// Artwork from Apple Music, including art it downloaded that isn't embedded in the file.
final class AppleMusicArtwork: ArtworkProvider, @unchecked Sendable {
    // ITLibrary objects aren't documented as thread-safe; serialize access.
    private let lock = NSLock()
    private let library: ITLibrary
    private let items: [String: ITLibMediaItem]

    init(library: ITLibrary, items: [String: ITLibMediaItem]) {
        self.library = library
        self.items = items
    }

    func artwork(forTrackId id: String) -> Data? {
        lock.withLock {
            guard let item = items[id], item.hasArtworkAvailable, let art = item.artwork else { return nil }
            return art.imageData
        }
    }
}
