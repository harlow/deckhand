import Foundation

/// Read-only view of an existing exportLibrary.db (e.g. one written by Rekordbox).
public struct DeviceLibrary: Sendable {
    public struct Track: Sendable {
        public var contentId: Int
        public var title: String
        public var artist: String
        public var durationSeconds: Int
        public var usbPath: String
        public var fileSize: Int
    }

    public struct Playlist: Sendable {
        public var playlistId: Int
        public var name: String
        public var parentId: Int?
        public var isFolder: Bool
        public var sequenceNo: Int
        /// Content IDs in play order.
        public var contentIds: [Int]
    }

    public var tracks: [Int: Track]
    /// Ordered parents-first, siblings by sequenceNo.
    public var playlists: [Playlist]

    public static func read(database: URL) throws -> DeviceLibrary {
        let db = try OneLibraryDatabase.open(database)
        var tracks: [Int: Track] = [:]
        let sql = """
            SELECT c.content_id, c.title, a.name AS artist, c.length, c.path, c.fileSize
            FROM content c LEFT JOIN artist a ON a.artist_id = c.artist_id_artist
            """
        for r in try db.query(sql) {
            guard let id = r["content_id"]?.int, let path = r["path"]?.string else { continue }
            tracks[Int(id)] = Track(contentId: Int(id), title: r["title"]?.string ?? "", artist: r["artist"]?.string ?? "",
                                    durationSeconds: Int(r["length"]?.int ?? 0), usbPath: path,
                                    fileSize: Int(r["fileSize"]?.int ?? 0))
        }
        var members: [Int: [Int]] = [:]
        for r in try db.query("SELECT playlist_id, content_id FROM playlist_content ORDER BY playlist_id, sequenceNo") {
            if let p = r["playlist_id"]?.int, let c = r["content_id"]?.int { members[Int(p), default: []].append(Int(c)) }
        }
        var playlists: [Playlist] = []
        for r in try db.query("SELECT playlist_id, name, attribute, playlist_id_parent, sequenceNo FROM playlist") {
            guard let id = r["playlist_id"]?.int else { continue }
            let parent = r["playlist_id_parent"]?.int ?? 0
            playlists.append(Playlist(playlistId: Int(id), name: r["name"]?.string ?? "", parentId: parent == 0 ? nil : Int(parent),
                                      isFolder: r["attribute"]?.int == 1, sequenceNo: Int(r["sequenceNo"]?.int ?? 0),
                                      contentIds: members[Int(id)] ?? []))
        }
        return DeviceLibrary(tracks: tracks, playlists: orderedTree(playlists))
    }

    private static func orderedTree(_ all: [Playlist]) -> [Playlist] {
        var out: [Playlist] = []
        func visit(_ parent: Int?) {
            for p in all.filter({ $0.parentId == parent }).sorted(by: { $0.sequenceNo < $1.sequenceNo }) {
                out.append(p)
                visit(p.playlistId)
            }
        }
        visit(nil)
        return out
    }
}
