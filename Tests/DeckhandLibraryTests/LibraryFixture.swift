import AVFoundation
import CSQLCipher
import DeckhandCore
import Foundation
import MusicSource
@testable import DeckhandLibrary

final class LibraryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-library-test-\(UUID().uuidString)")
    var directory: URL { root.appendingPathComponent("Library") }
    var legacy: URL { root.appendingPathComponent("Legacy") }
    var a: URL { root.appendingPathComponent("A") }
    var b: URL { root.appendingPathComponent("B") }
    var xml: URL { root.appendingPathComponent("rekordbox.xml") }
    init() throws {
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func audio(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? a).appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        data.frameLength = 4410
        for i in 0..<4410 { data.floatChannelData![0][i] = Float(sin(Double(i) * 0.2)) * 0.1 }
        try output.write(from: data)
        return url
    }
    func writeM3U(_ name: String = "Friday", paths: [String] = ["One.wav"], folder: URL? = nil) throws {
        try paths.joined(separator: "\n").write(to: (folder ?? a).appendingPathComponent("\(name).m3u8"), atomically: true, encoding: .utf8)
    }
    func writeXML(track: URL, members: [Int] = [1, 1], title: String = "Imported") throws {
        let location = track.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        try """
        <DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="1">
        <TRACK TrackID="1" Name="Rekordbox Track" Artist="Fixture Artist" Location="\(location)" Rating="102">
        <TEMPO Inizio="0" Bpm="124" Metro="4/4" Battito="1"/><POSITION_MARK Name="Mix In" Type="0" Start="0.1" Num="0"/>
        </TRACK></COLLECTION><PLAYLISTS><NODE Type="0" Name="ROOT" Count="1"><NODE Type="0" Name="Weekend" Count="1">
        <NODE Type="1" Name="\(title)" KeyType="0" Entries="\(members.count)">\(members.map { "<TRACK Key=\"\($0)\"/>" }.joined())</NODE>
        </NODE></NODE></PLAYLISTS></DJ_PLAYLISTS>
        """.write(to: xml, atomically: true, encoding: .utf8)
    }
    func music(_ url: URL, id: String = "MUSIC1", members: [String]? = nil) -> SourceLibrary {
        let track = SourceTrack(id: id, title: "Music track", rating: 2, location: url)
        var library = SourceLibrary(playlists: [SourcePlaylist(id: "MUSIC_PLAYLIST", name: "Music Favorites", trackIds: members ?? [id])], tracks: [id: track])
        library.allTrackIds = [id]
        return library
    }
    func rawSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(DeckhandLibraryStore.databaseURL(in: directory).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw DeckhandLibraryError.database("Test database open failed")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DeckhandLibraryError.database(String(cString: sqlite3_errmsg(db))) }
    }
}
