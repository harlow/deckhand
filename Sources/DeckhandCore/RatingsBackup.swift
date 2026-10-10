import Foundation

/// A snapshot of every star rating in the music library, so ratings survive a lost or rebuilt
/// library (Apple Music keeps them only in its own database, never in the audio files).
///
/// Saved as JSON under `~/Library/Application Support/Deckhand/Ratings/`: `ratings-latest.json`
/// plus one dated copy per day, kept for `keepDays`.
public struct RatingsBackup: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var artist: String?
        public var durationSeconds: Double?
        public var path: String?
        public var rating: Int
    }

    public var savedAt: Date
    public var entries: [Entry]

    public static let keepDays = 60

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Deckhand/Ratings", isDirectory: true)
    }

    public init(tracks: some Sequence<SourceTrack>, at date: Date = Date()) {
        savedAt = date
        entries = tracks.compactMap { t in
            guard let r = t.rating, r > 0 else { return nil }
            return Entry(id: t.id, title: t.title, artist: t.artist, durationSeconds: t.durationSeconds,
                         path: t.location?.path, rating: r)
        }
        .sorted { $0.id < $1.id }
    }

    public static func load(from url: URL) throws -> RatingsBackup {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(RatingsBackup.self, from: Data(contentsOf: url))
    }

    public static func latest(in dir: URL = directory) -> URL? {
        let url = dir.appendingPathComponent("ratings-latest.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes the backup unless it has the same ratings as the latest one. Never replaces a backup
    /// with an empty one (a library that failed to load shouldn't wipe the last good copy).
    /// Returns the dated file written, or nil when nothing changed.
    @discardableResult
    public func save(to dir: URL = directory) throws -> URL? {
        guard !entries.isEmpty else { return nil }
        if let latest = Self.latest(in: dir), let old = try? Self.load(from: latest), old.entries == entries { return nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        let data = try e.encode(self)
        let day = ISO8601DateFormatter.string(from: savedAt, timeZone: .current, formatOptions: [.withFullDate])
        let dated = dir.appendingPathComponent("ratings-\(day).json")
        try data.write(to: dated, options: .atomic)
        try data.write(to: dir.appendingPathComponent("ratings-latest.json"), options: .atomic)
        Self.prune(dir, before: savedAt.addingTimeInterval(-Double(Self.keepDays) * 86_400))
        return dated
    }

    private static func prune(_ dir: URL, before cutoff: Date) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard name.hasPrefix("ratings-"), name.hasSuffix(".json"),
                  let date = f.date(from: String(name.dropFirst(8).dropLast(5))), date < cutoff else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    public struct Change: Sendable, Equatable {
        public var trackId: String
        public var title: String
        public var from: Int
        public var to: Int
    }

    /// The ratings restoring this backup would set in `tracks`. Tracks are matched by library ID,
    /// then file path, then title + artist + length (for a rebuilt library, where IDs change). Only
    /// unrated tracks are filled in unless `overwrite` is set.
    public func changes(for tracks: [SourceTrack], overwrite: Bool = false) -> [Change] {
        let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byPath = Dictionary(tracks.compactMap { t in t.location.map { ($0.path, t) } }, uniquingKeysWith: { a, _ in a })
        func name(_ title: String, _ artist: String?) -> String {
            (title + "\u{1}" + (artist ?? "")).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let byName = Dictionary(grouping: tracks) { name($0.title, $0.artist) }

        var seen = Set<String>()
        var out: [Change] = []
        for e in entries {
            var match = byId[e.id] ?? e.path.flatMap { byPath[$0] }
            if match == nil, let candidates = byName[name(e.title, e.artist)] {
                let close = candidates.filter { c in
                    guard let a = c.durationSeconds, let b = e.durationSeconds else { return true }
                    return abs(a - b) < 2
                }
                if close.count == 1 { match = close[0] }
            }
            guard let t = match, seen.insert(t.id).inserted else { continue }
            let current = t.rating ?? 0
            guard current != e.rating, current == 0 || overwrite else { continue }
            out.append(Change(trackId: t.id, title: t.title, from: current, to: e.rating))
        }
        return out
    }
}
