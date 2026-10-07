import DeckhandCore
import Foundation

/// Writes `PIONEER/rekordbox/exportLibrary.db` (SQLCipher-encrypted SQLite).
public enum OneLibraryDatabase {
    /// Public key used by Rekordbox and compatible players for exportLibrary.db.
    static let key = "r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls"
    static let dbVersion = "1000"

    public enum KeyFormat: String, Sendable, CaseIterable {
        /// "Am", "F#m", "C"
        case classic
        /// "8A", "11A", "8B"
        case alphanumeric
    }

    public struct Contents: Sendable {
        public var tracks: [ExportTrack]
        public var playlists: [ExportPlaylist]
        public var keyFormat: KeyFormat

        public init(tracks: [ExportTrack], playlists: [ExportPlaylist], keyFormat: KeyFormat = .classic) {
            self.tracks = tracks
            self.playlists = playlists
            self.keyFormat = keyFormat
        }
    }

    /// Data the player writes into the database (history, play counts), carried across rebuilds.
    struct PlayerData {
        var history: [[String: SQLiteDatabase.Value]] = []
        var historyContent: [[String: SQLiteDatabase.Value]] = []
        var playCounts: [Int64: Int64] = [:]

        init() {}

        init(from path: URL) throws {
            let db = try OneLibraryDatabase.open(path)
            history = try db.query("SELECT * FROM history")
            historyContent = try db.query("SELECT * FROM history_content")
            for row in try db.query("SELECT content_id, djPlayCount FROM content WHERE djPlayCount > 0") {
                if let id = row["content_id"]?.int, let n = row["djPlayCount"]?.int { playCounts[id] = n }
            }
        }
    }

    /// Writes a complete new database at `path`. The file must not already exist.
    /// If `previous` is an existing exportLibrary.db, player-written history and play counts
    /// are carried over for content IDs that still exist.
    public static func write(_ contents: Contents, to path: URL, previous: URL? = nil) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            throw OneLibraryError.database("Refusing to overwrite existing file \(path.path)")
        }
        let playerData = try previous.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            .map { try PlayerData(from: $0) } ?? PlayerData()
        // Scoped so the connection closes (checkpointing the WAL) before the file is moved.
        do {
            let db = try SQLiteDatabase(path: path.path, key: key)
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("BEGIN")
            for statement in OneLibrarySchema.createStatements { try db.execute(statement) }
            try Writer(db: db, contents: contents, playerData: playerData).writeAll()
            try db.execute("COMMIT")
        }
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path.path + suffix) {
            throw OneLibraryError.database("Database journal \(suffix) was not checkpointed")
        }
    }

    /// Opens an existing database for reading, e.g. for validation or diffing.
    static func open(_ path: URL) throws -> SQLiteDatabase {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw OneLibraryError.database("No database at \(path.path)")
        }
        let db = try SQLiteDatabase(path: path.path, key: key)
        _ = try db.query("SELECT count(*) FROM sqlite_master")
        return db
    }

    private struct Writer {
        let db: SQLiteDatabase
        let contents: Contents
        let playerData: PlayerData

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        func writeAll() throws {
            let lookups = try writeLookups()
            for track in contents.tracks { try writeContent(track, lookups) }
            try writePlaylists()
            try writeMenus()
            try writePlayerData()
            try db.insert("property", [
                ("deviceName", .text("")),
                ("dbVersion", .text(dbVersion)),
                ("numberOfContents", .int(Int64(contents.tracks.count))),
                ("createdDate", .text(Self.dateFormatter.string(from: Date()))),
                ("backGroundColorType", .int(0)),
                ("myTagMasterDBID", .int(0)),
            ])
        }

        struct Lookups {
            var artists: [String: Int] = [:]
            var albums: [String: Int] = [:]
            var genres: [String: Int] = [:]
            var keys: [String: Int] = [:]
            var images: [String: Int] = [:]
        }

        /// Assigns 1-based IDs to distinct names in first-seen order.
        private func ids(_ names: [String?]) -> [String: Int] {
            var out: [String: Int] = [:]
            for case let name? in names where !name.isEmpty && out[name] == nil {
                out[name] = out.count + 1
            }
            return out
        }

        private func writeLookups() throws -> Lookups {
            let tracks = contents.tracks
            var l = Lookups()
            l.artists = ids(tracks.flatMap { [$0.artist, $0.albumArtist] })
            l.albums = ids(tracks.map(\.album))
            l.genres = ids(tracks.map(\.genre))
            l.keys = ids(tracks.map { $0.key.map(keyName) })
            l.images = ids(tracks.map(\.artworkPath))

            for (name, id) in l.artists.sorted(by: { $0.value < $1.value }) {
                try db.insert("artist", [("artist_id", .int(Int64(id))), ("name", .text(name)), ("nameForSearch", .text(""))])
            }
            for (name, id) in l.images.sorted(by: { $0.value < $1.value }) {
                try db.insert("image", [("image_id", .int(Int64(id))), ("path", .text(name))])
            }
            for (name, id) in l.albums.sorted(by: { $0.value < $1.value }) {
                let first = tracks.first { $0.album == name }
                let artist = (first?.albumArtist ?? first?.artist).flatMap { l.artists[$0] }
                let image = first?.artworkPath.flatMap { l.images[$0] }
                try db.insert("album", [
                    ("album_id", .int(Int64(id))), ("name", .text(name)),
                    ("artist_id", .int(Int64(artist ?? 0))),
                    ("image_id", .int(Int64(image ?? 0))),
                    ("isComplation", .int(0)), ("nameForSearch", .text("")),
                ])
            }
            for (name, id) in l.genres.sorted(by: { $0.value < $1.value }) {
                try db.insert("genre", [("genre_id", .int(Int64(id))), ("name", .text(name))])
            }
            for (name, id) in l.keys.sorted(by: { $0.value < $1.value }) {
                try db.insert("key", [("key_id", .int(Int64(id))), ("name", .text(name))])
            }
            for color in TrackColor.allCases {
                try db.insert("color", [("color_id", .int(Int64(color.rawValue))), ("name", .text(color.name))])
            }
            return l
        }

        private func writeContent(_ t: ExportTrack, _ l: Lookups) throws {
            // Rekordbox writes 0, not NULL, for absent references.
            func ref(_ id: Int?) -> SQLiteDatabase.Value { .int(Int64(id ?? 0)) }
            func text(_ s: String?) -> SQLiteDatabase.Value { s.map { .text($0) } ?? .null }
            let added = Self.dateFormatter.string(from: t.dateAdded)
            try db.insert("content", [
                ("content_id", .int(Int64(t.contentId))),
                ("title", .text(t.title)),
                ("titleForSearch", .text("")),
                ("subtitle", .text("")),
                ("bpmx100", .int(Int64(((t.bpm ?? 0) * 100).rounded()))),
                ("length", .int(Int64(t.durationSeconds.rounded()))),
                ("trackNo", .int(Int64(t.trackNumber ?? 0))),
                ("discNo", .int(Int64(t.discNumber ?? 0))),
                ("artist_id_artist", ref(t.artist.flatMap { l.artists[$0] })),
                ("artist_id_remixer", .int(0)),
                ("artist_id_originalArtist", .int(0)),
                ("artist_id_composer", .int(0)),
                ("artist_id_lyricist", .int(0)),
                ("album_id", ref(t.album.flatMap { l.albums[$0] })),
                ("genre_id", ref(t.genre.flatMap { l.genres[$0] })),
                ("label_id", .int(0)),
                ("key_id", ref(t.key.flatMap { l.keys[keyName($0)] })),
                ("color_id", ref(t.color?.rawValue)),
                ("image_id", ref(t.artworkPath.flatMap { l.images[$0] })),
                ("djComment", .text(t.comment ?? "")),
                ("rating", .int(Int64(t.rating))),
                ("releaseYear", .int(Int64(t.year ?? 0))),
                ("releaseDate", .text("")),
                ("dateCreated", .text(added)),
                ("dateAdded", .text(added)),
                ("path", .text(t.usbPath)),
                ("fileName", .text(t.fileName)),
                ("fileSize", .int(Int64(t.fileSize))),
                ("fileType", .int(Int64(t.fileType.rawValue))),
                ("bitrate", .int(Int64(t.bitrateKbps))),
                ("bitDepth", .int(Int64(t.bitDepth))),
                ("samplingRate", .int(Int64(t.sampleRate))),
                ("isrc", .text("")),
                ("djPlayCount", .int(playerData.playCounts[Int64(t.contentId)] ?? 0)),
                ("isHotCueAutoLoadOn", .int(1)),
                ("isKuvoDeliverStatusOn", .int(0)),
                ("kuvoDeliveryComment", .text("")),
                ("masterDbId", .int(0)),
                ("masterContentId", .int(0)),
                ("analysisDataFilePath", text(t.analysisPath)),
                ("analysedBits", .int(t.analysisPath == nil ? 0 : 41)),
                ("contentLink", .int(0)),
                ("hasModified", .int(0)),
                ("cueUpdateCount", .int(0)),
                ("analysisDataUpdateCount", .int(1)),
                ("informationUpdateCount", .int(1)),
            ])
        }

        private func writePlaylists() throws {
            for p in contents.playlists {
                try db.insert("playlist", [
                    ("playlist_id", .int(Int64(p.playlistId))),
                    ("sequenceNo", .int(Int64(p.sequenceNo))),
                    ("name", .text(p.name)),
                    ("image_id", .int(0)),
                    ("attribute", .int(p.isFolder ? 1 : 0)),
                    ("playlist_id_parent", .int(Int64(p.parentId ?? 0))),
                ])
                for (i, contentId) in p.contentIds.enumerated() {
                    try db.insert("playlist_content", [
                        ("playlist_id", .int(Int64(p.playlistId))),
                        ("content_id", .int(Int64(contentId))),
                        ("sequenceNo", .int(Int64(i + 1))),
                    ])
                }
            }
        }

        private func writeMenus() throws {
            for item in OneLibraryMenus.menuItems {
                try db.insert("menuItem", [("menuItem_id", .int(Int64(item.id))), ("kind", .int(Int64(item.kind))), ("name", .text(item.name))])
            }
            for c in OneLibraryMenus.categories {
                try db.insert("category", [
                    ("category_id", .int(Int64(c.id))), ("menuItem_id", .int(Int64(c.menuItemId))),
                    ("sequenceNo", .int(Int64(c.sequenceNo))), ("isVisible", .int(c.isVisible ? 1 : 0)),
                ])
            }
            for s in OneLibraryMenus.sorts {
                try db.insert("sort", [
                    ("sort_id", .int(Int64(s.id))), ("menuItem_id", .int(Int64(s.menuItemId))),
                    ("sequenceNo", .int(Int64(s.sequenceNo))), ("isVisible", .int(s.isVisible ? 1 : 0)),
                    ("isSelectedAsSubColumn", .int(s.isSelectedAsSubColumn ? 1 : 0)),
                ])
            }
        }

        private func keyName(_ k: MusicalKey) -> String {
            contents.keyFormat == .classic ? k.classic : k.alphanumeric
        }

        private func writePlayerData() throws {
            let kept = Set(contents.tracks.map { Int64($0.contentId) })
            for row in playerData.history {
                try db.insert("history", row.map { ($0.key, $0.value) })
            }
            for row in playerData.historyContent {
                guard let id = row["content_id"]?.int, kept.contains(id) else { continue }
                try db.insert("history_content", row.map { ($0.key, $0.value) })
            }
        }
    }
}
