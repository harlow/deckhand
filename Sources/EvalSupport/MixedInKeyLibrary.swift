import CSQLCipher
import DeckhandCore
import Foundation

/// Read-only access to analysis stored by Mixed In Key 11 (`Collection11.mikdb`, a Core Data SQLite store).
///
/// Evaluation tooling only: MIK's keys, grids, and cues are the answer key that Deckhand's own analysis
/// is scored and trained against (deckhand-eval, deckhand-cue-eval, Scripts/). Sync never reads it.
///
/// The format is undocumented and may change between MIK versions; every read is defensive and
/// failures just mean "no MIK data".
public final class MixedInKeyLibrary: @unchecked Sendable {
    public struct Track: Sendable, Equatable {
        public var tempo: Double?
        public var key: MusicalKey?
        public var keyConfidence: Double?
        public var energy: Int?
        /// Seconds on MIK's timeline.
        public var beatTimes: [Double]
        /// (seconds, energy level) on MIK's timeline.
        public var cues: [(time: Double, energy: Int)]

        public init(tempo: Double?, key: MusicalKey?, keyConfidence: Double?, energy: Int?, beatTimes: [Double],
                    cues: [(time: Double, energy: Int)]) {
            self.tempo = tempo
            self.key = key
            self.keyConfidence = keyConfidence
            self.energy = energy
            self.beatTimes = beatTimes
            self.cues = cues
        }

        public static func == (a: Track, b: Track) -> Bool {
            a.tempo == b.tempo && a.key == b.key && a.energy == b.energy && a.beatTimes == b.beatTimes
                && a.cues.map(\.time) == b.cues.map(\.time)
        }
    }

    /// Keyed by standardized file path.
    public let tracks: [String: Track]

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mixedinkey/Collection11.mikdb")
    }

    /// Returns nil if MIK isn't installed or its database can't be read.
    public static func load(from url: URL = defaultURL()) -> MixedInKeyLibrary? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var cues: [Int64: [(Double, Int)]] = [:]
        query(db, "SELECT ZSONG, ZTIME, ZENERGYLEVEL FROM ZCUEPOINT ORDER BY ZTIME") { s in
            cues[sqlite3_column_int64(s, 0), default: []].append((sqlite3_column_double(s, 1), Int(sqlite3_column_int(s, 2))))
        }
        var confidence: [Int64: Double] = [:]
        query(db, "SELECT ZSONG, MAX(ZCONFIDENCE) FROM ZKEYSEGMENT GROUP BY ZSONG") { s in
            confidence[sqlite3_column_int64(s, 0)] = sqlite3_column_double(s, 1)
        }

        var tracks: [String: Track] = [:]
        query(db, "SELECT Z_PK, ZTEMPO, ZKEY, ZENERGY, ZBEATS, ZBOOKMARKDATA FROM ZSONG") { s in
            let pk = sqlite3_column_int64(s, 0)
            guard let bookmark = blob(s, 5), let path = resolve(bookmark) else { return }
            let tempo = sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_double(s, 1)
            let key = text(s, 2).flatMap { MusicalKey(parsing: $0) }
            let energy = sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_double(s, 3).rounded())
            let beats = blob(s, 4).map(beatTimes) ?? []
            tracks[path] = Track(tempo: tempo, key: key, keyConfidence: confidence[pk], energy: energy,
                                 beatTimes: beats, cues: (cues[pk] ?? []).map { (time: $0.0, energy: $0.1) })
        }
        return tracks.isEmpty ? nil : MixedInKeyLibrary(tracks: tracks)
    }

    init(tracks: [String: Track]) {
        self.tracks = tracks
    }

    public func track(for file: URL) -> Track? {
        tracks[file.standardizedFileURL.path]
    }

    // MARK: - Decoding

    private static func resolve(_ bookmark: Data) -> String? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              bookmarkDataIsStale: &stale) {
            return url.standardizedFileURL.path
        }
        return URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    }

    /// `ZBEATS` is an NSKeyedArchiver archive of MIK's `MIKBeats` class; decode it into a local stand-in.
    static func beatTimes(_ data: Data) -> [Double] {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return [] }
        u.requiresSecureCoding = false
        u.setClass(MIKBeats.self, forClassName: "MIKBeats")
        defer { u.finishDecoding() }
        return (u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? MIKBeats)?.beatTimes ?? []
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { row(s) }
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static func blob(_ s: OpaquePointer?, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
}

/// Stand-in for Mixed In Key's archived beat grid.
@objc(DeckhandMIKBeats)
final class MIKBeats: NSObject, NSCoding {
    let beatTimes: [Double]

    init?(coder: NSCoder) {
        beatTimes = (coder.decodeObject(forKey: "MIKBeats_beatTimes") as? [NSNumber])?.map(\.doubleValue) ?? []
    }

    func encode(with coder: NSCoder) {}
}
