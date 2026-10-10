import DeckhandCore
import Foundation
@testable import MusicSource
import Testing

/// Decoding and normalizing Music's Apple Event replies, and laying them over iTunesLibrary's snapshot.
@Suite struct MusicLiveTests {
    static func code(_ s: String) -> FourCharCode { MusicEvents.code(s) }
    static var missing: NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: code("msng")) }

    static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let l = NSAppleEventDescriptor.list()
        for (i, d) in items.enumerated() { l.insert(d, at: i + 1) }
        return l
    }

    static func text(_ values: [String?]) -> NSAppleEventDescriptor {
        list(values.map { $0.map { NSAppleEventDescriptor(string: $0) } ?? missing })
    }

    static func ints(_ values: [Int32]) -> NSAppleEventDescriptor { list(values.map { NSAppleEventDescriptor(int32: $0) }) }

    static func kinds(_ values: [String]) -> NSAppleEventDescriptor {
        list(values.map { NSAppleEventDescriptor(enumCode: code($0)) })
    }

    /// Columns in `MusicLive.properties` order for two tracks.
    static var columns: [NSAppleEventDescriptor] {
        [text(["Song A", "Song B "]), text(["Artist", ""]), text(["", "Album"]), text(["", nil]),
         text(["House", ""]), ints([2, 0]), ints([0, 1]), ints([2019, 0]), ints([60, 100]), kinds(["kRtU", "kRtC"]),
         text(["07A - Energy 8", ""])]
    }

    @Test func decodesAndNormalizesColumns() throws {
        let ids = Self.text(["AAAA", "BBBB"])
        let tracks = try #require(MusicLive.decode(ids: ids, columns: Self.columns, idsAfter: ids))
        #expect(tracks["AAAA"] == LiveTrack(title: "Song A", artist: "Artist", album: "", albumArtist: nil, genre: "House",
                                            trackNumber: 2, discNumber: nil, year: 2019, rating: 3, comment: "07A - Energy 8"))
        // Empty strings are nil (album keeps "", as iTunesLibrary reports it), zeros are nil, a computed rating is 0.
        #expect(tracks["BBBB"] == LiveTrack(title: "Song B ", artist: nil, album: "Album", albumArtist: nil, genre: nil,
                                            trackNumber: nil, discNumber: 1, year: nil, rating: 0, comment: nil))
    }

    @Test func missingValuesReadAsNil() {
        #expect(MusicLive.isMissing(Self.missing))
        #expect(MusicLive.string(Self.missing) == nil)
        #expect(MusicLive.int(Self.missing) == nil)
        #expect(MusicLive.string(NSAppleEventDescriptor(string: "")) == "")
        #expect(MusicLive.list(.null()).isEmpty)
    }

    @Test func columnsThatDontLineUpAreRejected() {
        let ids = Self.text(["AAAA", "BBBB"])
        // The library changed between the first and last ID column.
        #expect(MusicLive.decode(ids: ids, columns: Self.columns, idsAfter: Self.text(["AAAA", "CCCC"])) == nil)
        // A column with a different count.
        var short = Self.columns
        short[3] = Self.text([nil])
        #expect(MusicLive.decode(ids: ids, columns: short, idsAfter: ids) == nil)
    }

    @Test func readRetriesOnceWhenTheLibraryChangesMidRead() throws {
        var idReads = 0
        let tracks = try MusicLive.read { property in
            guard property == "pPIS" else {
                return Self.columns[MusicLive.properties.firstIndex(of: property)!]
            }
            idReads += 1
            // First pass: a track appears between the first and last ID column.
            return idReads == 2 ? Self.text(["AAAA", "CCCC"]) : Self.text(["AAAA", "BBBB"])
        }
        #expect(idReads == 4)
        #expect(Set(tracks.keys) == ["AAAA", "BBBB"])

        var reads = 0
        #expect(throws: MusicEvents.Failure(MusicEvents.Failure.changedDuringRead)) {
            try MusicLive.read { property in
                guard property == "pPIS" else { return Self.columns[MusicLive.properties.firstIndex(of: property)!] }
                reads += 1
                return reads % 2 == 0 ? Self.text(["AAAA", "CCCC"]) : Self.text(["AAAA", "BBBB"])
            }
        }
    }

    @Test func errorsAreReported() {
        #expect(MusicEvents.Failure(-1743).description.contains("Automation"))
        #expect(MusicEvents.Failure(-1712).description.contains("in time"))
        #expect(MusicEvents.Failure(-1728).description.contains("couldn't find"))
        #expect(MusicEvents.Failure(-600).isNotRunning)
        #expect(!MusicEvents.Failure(-1743).isNotRunning)
    }

    // MARK: Overlay

    static func snapshotTrack(_ id: String) -> SourceTrack {
        SourceTrack(id: id, title: "Song", artist: nil, album: "", albumArtist: nil, genre: nil, trackNumber: 3, discNumber: nil,
                    year: 2020, rating: 0, comment: nil, durationSeconds: 300, location: URL(fileURLWithPath: "/m/\(id).mp3"),
                    dateAdded: Date(timeIntervalSince1970: 1000), modifiedDate: Date(timeIntervalSince1970: 2000))
    }

    @Test func overlayIsANoOpWhenMusicAgrees() {
        var lib = SourceLibrary(playlists: [], tracks: ["A": Self.snapshotTrack("A")])
        // Music's form of the same values: "" where the snapshot has nil, rating 0 where it has 0.
        let live = ["A": LiveTrack(title: "Song", artist: nil, album: "", albumArtist: nil, genre: nil, trackNumber: 3, year: 2020,
                                   rating: 0, comment: nil)]
        let before = lib
        #expect(MusicLive.overlay(live, onto: &lib).isEmpty)
        #expect(lib.tracks == before.tracks)
    }

    @Test func overlayTakesMusicsValuesButNeverDatesOrLocations() {
        var lib = SourceLibrary(playlists: [], tracks: ["A": Self.snapshotTrack("A"), "B": Self.snapshotTrack("B")])
        // A record the snapshot has stale: Music back-filled genre and comment from the file's tags, and a rating was set.
        let live = ["A": LiveTrack(title: "Song", artist: nil, album: "", genre: "Other", trackNumber: 3, year: 2020, rating: 3,
                                   comment: "07A - Energy 8"),
                    "Z": LiveTrack(title: "Only in Music", rating: 5)]
        #expect(MusicLive.overlay(live, onto: &lib) == ["A"])
        let a = lib.tracks["A"]!
        #expect(a.genre == "Other")
        #expect(a.comment == "07A - Energy 8")
        #expect(a.rating == 3)
        #expect(a.location == URL(fileURLWithPath: "/m/A.mp3"))
        #expect(a.dateAdded == Date(timeIntervalSince1970: 1000))
        #expect(a.modifiedDate == Date(timeIntervalSince1970: 2000))
        // The snapshot decides membership.
        #expect(lib.tracks["Z"] == nil)
        #expect(lib.tracks["B"] == Self.snapshotTrack("B"))
    }

    @Test func overlayClearsWhatMusicCleared() {
        var t = Self.snapshotTrack("A")
        t.rating = 4
        t.comment = "old"
        t.genre = "House"
        var lib = SourceLibrary(playlists: [], tracks: ["A": t])
        MusicLive.overlay(["A": LiveTrack(title: "Song", album: "", trackNumber: 3, year: 2020, rating: 0)], onto: &lib)
        #expect(lib.tracks["A"]?.rating == nil)
        #expect(lib.tracks["A"]?.comment == nil)
        #expect(lib.tracks["A"]?.genre == nil)
    }
}
