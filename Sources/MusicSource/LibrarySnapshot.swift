import DeckhandCore
import Foundation

/// The app passes the same normalized snapshot to the CLI that it uses for browsing and sync status.
public enum LibrarySnapshot {
    public static func load(at url: URL) throws -> SourceLibrary {
        var lib = try JSONDecoder().decode(SourceLibrary.self, from: Data(contentsOf: url))
        guard lib.sourceID != nil, lib.allTrackIds != nil else {
            throw LibrarySourceError.unavailable("The source snapshot needs a connection ID and all track IDs.")
        }
        let ids = Set(lib.playlists.map(\.id))
        guard ids.count == lib.playlists.count, lib.tracks.allSatisfy({ $0.key == $0.value.id }),
              lib.allTrackIds!.allSatisfy({ lib.tracks[$0] != nil }) else {
            throw LibrarySourceError.unavailable("The library snapshot contains duplicate or inconsistent IDs.")
        }
        let byID = Dictionary(uniqueKeysWithValues: lib.playlists.map { ($0.id, $0) })
        for p in lib.playlists {
            var ancestors = Set<String>([p.id])
            var parent = p.parentId
            while let id = parent {
                guard ancestors.insert(id).inserted, let folder = byID[id], folder.isFolder else {
                    throw LibrarySourceError.unavailable("The library snapshot contains an invalid playlist hierarchy.")
                }
                parent = folder.parentId
            }
        }
        lib.artwork = FileArtwork(tracks: lib.tracks)
        return lib
    }
}
