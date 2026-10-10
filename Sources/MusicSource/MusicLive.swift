import DeckhandCore
import Foundation

/// A track's database fields as Music reports them right now, normalized like iTunesLibrary's: empty artist, album
/// artist, genre and comment are nil, zero track/disc/year are nil, and a computed rating is 0.
public struct LiveTrack: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    /// 0–5 stars.
    public var rating: Int
    public var comment: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil, rating: Int = 0,
                comment: String? = nil) {
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
    }
}

/// iTunesLibrary reads a copy of the library that Music's agent updates in batches: it can trail edits by seconds,
/// and some records stay stale indefinitely (Music back-fills comments and genres from file tags without pushing
/// them). Every field the drive's database takes from Music is therefore read live and laid over the snapshot.
/// Dates and file locations always come from the snapshot: Music's Apple Events report some dates an hour off, and
/// locations in a different Unicode normalization and case than the analysis cache keys on.
public enum MusicLive {
    public enum Status: Sendable, Equatable {
        case live
        /// Music isn't running, so nothing is waiting to reach the snapshot: it's current.
        case notRunning
        /// Music is running but couldn't be read (access refused, timed out): the snapshot may be stale.
        case unavailable(MusicEvents.Failure)

        public var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
    }

    /// Property codes read, in `LiveTrack` order: name, artist, album, album artist, genre, track number, disc number,
    /// year, rating, rating kind, comment.
    static let properties = ["pnam", "pArt", "pAlb", "pAlA", "pGen", "pTrN", "pDsN", "pYr ", "pRte", "pRtk", "pCmt"]

    /// Every file track's fields by persistent ID (one event per property, ~250 ms for 2,000 tracks). The ID column
    /// is read first and last; if the library changed in between, the read is retried once.
    public static func read(prompt: Bool = true) throws -> [String: LiveTrack] {
        try read { try MusicEvents.column($0, prompt: prompt) }
    }

    /// `read`, with the column source injectable for tests.
    static func read(column: (String) throws -> NSAppleEventDescriptor) throws -> [String: LiveTrack] {
        var attempt = 0
        while true {
            let first = try column("pPIS")
            let columns = try properties.map { try column($0) }
            let last = try column("pPIS")
            if let tracks = decode(ids: first, columns: columns, idsAfter: last) { return tracks }
            attempt += 1
            if attempt == 2 { throw MusicEvents.Failure(MusicEvents.Failure.changedDuringRead) }
        }
    }

    /// Nil when the columns don't line up (the library changed between events).
    static func decode(ids: NSAppleEventDescriptor, columns: [NSAppleEventDescriptor], idsAfter: NSAppleEventDescriptor)
        -> [String: LiveTrack]? {
        let idList = list(ids).map(string)
        let lists = columns.map(list)
        guard lists.count == properties.count, list(idsAfter).map(string) == idList,
              lists.allSatisfy({ $0.count == idList.count }) else { return nil }
        var out: [String: LiveTrack] = [:]
        out.reserveCapacity(idList.count)
        for (i, id) in idList.enumerated() {
            guard let id else { continue }
            func text(_ c: Int) -> String? { string(lists[c][i]) }
            func nonEmpty(_ c: Int) -> String? { text(c).flatMap { $0.isEmpty ? nil : $0 } }
            func number(_ c: Int) -> Int? { int(lists[c][i]).flatMap { $0 > 0 ? $0 : nil } }
            out[id] = LiveTrack(title: text(0), artist: nonEmpty(1), album: text(2), albumArtist: nonEmpty(3), genre: nonEmpty(4),
                                trackNumber: number(5), discNumber: number(6), year: number(7),
                                rating: stars(rating: lists[8][i], kind: lists[9][i]), comment: nonEmpty(10))
        }
        return out
    }

    /// Lays live fields over the snapshot's tracks (tracks only Music knows about yet are left out: the snapshot
    /// decides membership). A field that's equal after normalization keeps the snapshot's form, so the same library
    /// fingerprints the same whether or not Music could be read. Returns the IDs that changed.
    @discardableResult
    public static func overlay(_ live: [String: LiveTrack], onto lib: inout SourceLibrary) -> [String] {
        func norm(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
        var changed: [String] = []
        for (id, l) in live {
            guard var t = lib.tracks[id] else { continue }
            let before = t
            if let title = l.title, title != t.title { t.title = title }
            if norm(l.artist) != norm(t.artist) { t.artist = l.artist }
            if norm(l.album) != norm(t.album) { t.album = l.album }
            if norm(l.albumArtist) != norm(t.albumArtist) { t.albumArtist = l.albumArtist }
            if norm(l.genre) != norm(t.genre) { t.genre = l.genre }
            if norm(l.comment) != norm(t.comment) { t.comment = l.comment }
            if l.trackNumber != t.trackNumber.flatMap({ $0 > 0 ? $0 : nil }) { t.trackNumber = l.trackNumber }
            if l.discNumber != t.discNumber.flatMap({ $0 > 0 ? $0 : nil }) { t.discNumber = l.discNumber }
            if l.year != t.year.flatMap({ $0 > 0 ? $0 : nil }) { t.year = l.year }
            if l.rating != (t.rating ?? 0) { t.rating = l.rating == 0 ? nil : l.rating }
            if t != before {
                lib.tracks[id] = t
                changed.append(id)
            }
        }
        return changed
    }

    // MARK: Values

    static func list(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.descriptorType == MusicEvents.code("list") else { return d.descriptorType == MusicEvents.code("null") ? [] : [d] }
        return d.numberOfItems == 0 ? [] : (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    /// `missing value` arrives as the type code 'msng'.
    static func isMissing(_ d: NSAppleEventDescriptor) -> Bool {
        let type = d.descriptorType
        return (type == MusicEvents.code("type") && d.typeCodeValue == MusicEvents.code("msng"))
            || type == MusicEvents.code("msng") || type == MusicEvents.code("null")
    }

    static func string(_ d: NSAppleEventDescriptor) -> String? { isMissing(d) ? nil : d.stringValue }

    static func int(_ d: NSAppleEventDescriptor) -> Int? { isMissing(d) ? nil : Int(d.int32Value) }

    /// Stars the user set: Music's 0–100 rating ÷ 20, or 0 for a rating it computed from the album's.
    static func stars(rating: NSAppleEventDescriptor, kind: NSAppleEventDescriptor) -> Int {
        if kind.enumCodeValue == MusicEvents.code("kRtC") { return 0 }
        return max(0, min(5, (int(rating) ?? 0) / 20))
    }
}
