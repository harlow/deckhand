import AVFoundation
import DeckhandCore
import Foundation
import Testing
@testable import MusicSource

private final class SourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-source-test-\(UUID().uuidString)")
    var music: URL { root.appendingPathComponent("Music") }
    var storage: URL { root.appendingPathComponent("Libraries") }
    var xml: URL { root.appendingPathComponent("rekordbox.xml") }
    init() throws { try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func audio(_ name: String) throws -> URL {
        let url = music.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        try file.write(from: buffer)
        return url
    }

    func writeXML(order: [Int] = [2, 1, 2], playlistName: String = "Warmup &amp; Friends") throws {
        let location = music.appendingPathComponent("One.wav").absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        let members = order.map { "<TRACK Key=\"\($0)\"/>" }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="2">
            <TRACK TrackID="1" Name="One &amp; Only" Artist="Test Artist" Location="\(location)" Rating="204" TotalTime="10">
              <TEMPO Inizio="0" Bpm="124" Metro="4/4" Battito="1"/>
              <POSITION_MARK Name="Mix In" Type="0" Start="1.5" Num="0"/>
            </TRACK>
            <TRACK TrackID="2" Name="Two" Location="file://localhost/missing/Two.wav" Rating="51"/>
          </COLLECTION>
          <PLAYLISTS><NODE Type="0" Name="ROOT" Count="1">
            <NODE Type="0" Name="Friday" Count="1">
              <NODE Type="1" Name="\(playlistName)" Entries="\(order.count)" KeyType="0">\(members)</NODE>
            </NODE>
          </NODE></PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: xml, atomically: true, encoding: .utf8)
    }
}

@Suite struct LibrarySourcesTests {
    @Test func concurrentPlaylistAddsKeepBothEdits() async throws {
        let f = try SourceFixture()
        _ = try f.audio("One.wav")
        _ = try f.audio("Two.wav")
        let store = try LocalLibraryStore(connection: SourceConnection(kind: .folder, location: f.music), directory: f.storage)
        let first = try await store.load()
        let ids = try #require(first.allTrackIds)
        let created = try await store.createPlaylist(named: "Both")
        let playlistID = try #require(created.playlists.first?.id)
        async let one = store.add(trackIDs: [ids[0]], to: playlistID)
        async let two = store.add(trackIDs: [ids[1]], to: playlistID)
        _ = try await (one, two)
        let refreshed = try await store.load()
        #expect(Set(refreshed.playlists[0].trackIds) == Set(ids))
        await #expect(throws: (any Error).self) { try await store.createPlaylist(named: "Both") }
        _ = try await store.remove(trackIDs: [ids[0]], from: playlistID)
        let reopened = try LocalLibraryStore(connection: await store.connection, directory: f.storage)
        let saved = try await reopened.load()
        #expect(saved.playlists[0].trackIds == [ids[1]])
    }

    @Test func folderPersistsPlaylistRatingAndIdentityAfterRename() async throws {
        let f = try SourceFixture()
        let original = try f.audio("One.wav")
        let connection = SourceConnection(kind: .folder, location: f.music)
        let store = try LocalLibraryStore(connection: connection, directory: f.storage)
        let first = try await store.load()
        let id = try #require(first.allTrackIds?.first)
        #expect(first.tracks[id]?.title == "One")
        #expect((first.tracks[id]?.durationSeconds ?? 0) > 0)
        let created = try await store.createPlaylist(named: "Friday")
        var p = try #require(created.playlists.first)
        p.trackIds = [id]
        _ = try await store.updatePlaylist(p)
        _ = try await store.setRating(5, ids: [id])
        let renamed = f.music.appendingPathComponent("Renamed.wav")
        try FileManager.default.moveItem(at: original, to: renamed)
        let reopened = try LocalLibraryStore(connection: connection, directory: f.storage)
        let lib = try await reopened.load()
        #expect(lib.allTrackIds == [id])
        #expect(lib.tracks[id]?.location?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        #expect(lib.tracks[id]?.rating == 5)
        #expect(lib.playlists.first?.trackIds == [id])
        _ = try await reopened.setRating(0, ids: [id])
        let cleared = try await reopened.load()
        #expect(cleared.tracks[id]?.rating == nil)
    }

    @Test func emptyFolderSucceedsAndOfflineFolderThrows() async throws {
        let f = try SourceFixture()
        let store = try LocalLibraryStore(connection: SourceConnection(kind: .folder, location: f.music), directory: f.storage)
        let empty = try await store.load()
        #expect(empty.tracks.isEmpty && empty.allTrackIds == [])
        _ = try await store.createPlaylist(named: "Empty is valid")
        try FileManager.default.moveItem(at: f.music, to: f.root.appendingPathComponent("Disconnected"))
        await #expect(throws: (any Error).self) { try await store.load() }
    }

    @Test func folderReadsM3UOrderAndSkipsNonAudioFiles() async throws {
        let f = try SourceFixture()
        _ = try f.audio("One.wav")
        _ = try f.audio("Two.wav")
        try "#EXTM3U\nTwo.wav\nOne.wav\nTwo.wav\n".write(to: f.music.appendingPathComponent("Friday.m3u8"), atomically: true, encoding: .utf8)
        try "notes".write(to: f.music.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let read = try await FolderSource(connection: SourceConnection(kind: .folder, location: f.music)).load(files: [:])
        #expect(read.library.tracks.count == 2)
        let p = try #require(read.library.playlists.first)
        #expect(p.trackIds.compactMap { read.library.tracks[$0]?.title } == ["Two", "One", "Two"])
    }

    @Test func rekordboxPreservesHierarchyOrderMetadataAndLocalEdits() async throws {
        let f = try SourceFixture()
        try f.writeXML()
        let connection = SourceConnection(kind: .rekordbox, location: f.xml)
        let store = try LocalLibraryStore(connection: connection, directory: f.storage)
        let first = try await store.load()
        #expect(first.playlists.map(\.name) == ["Friday", "Warmup & Friends"])
        #expect(first.playlists[1].parentId == first.playlists[0].id)
        #expect(first.playlists[1].trackIds == [connection.trackID("2"), connection.trackID("1"), connection.trackID("2")])
        #expect(first.tracks[connection.trackID("1")]?.rating == 4)
        #expect(first.tracks[connection.trackID("1")]?.title == "One & Only")
        var p = first.playlists[1]
        p.trackIds = [connection.trackID("1")]
        _ = try await store.updatePlaylist(p)
        _ = try await store.setRating(5, ids: [connection.trackID("1")])
        try f.writeXML(order: [2])
        let reopened = try LocalLibraryStore(connection: connection, directory: f.storage)
        let refreshed = try await reopened.load()
        #expect(refreshed.playlists[1].trackIds == [connection.trackID("1")])
        #expect(refreshed.tracks[connection.trackID("1")]?.rating == 5)
    }

    @Test func untouchedRekordboxPlaylistRefreshes() async throws {
        let f = try SourceFixture()
        try f.writeXML()
        let store = try LocalLibraryStore(connection: SourceConnection(kind: .rekordbox, location: f.xml), directory: f.storage)
        _ = try await store.load()
        try f.writeXML(order: [1])
        let refreshed = try await store.load()
        #expect(refreshed.playlists[1].trackIds.count == 1)
    }

    @Test func xmlExportRoundTripKeepsCuesAndOriginalFile() async throws {
        let f = try SourceFixture()
        try f.writeXML()
        let before = try Data(contentsOf: f.xml)
        let connection = SourceConnection(kind: .rekordbox, location: f.xml)
        var library = try await RekordboxSource(connection: connection).load(files: [:]).library
        library.tracks[connection.trackID("1")]?.rating = 5
        library.playlists[1].trackIds = [connection.trackID("1"), connection.trackID("2")]
        library.playlists.append(SourcePlaylist(id: "local", name: "New in Deckhand", trackIds: [connection.trackID("1")]))
        let exported = f.root.appendingPathComponent("Deckhand.xml")
        try RekordboxSource.export(library, original: f.xml, to: exported)
        #expect(try Data(contentsOf: f.xml) == before)
        let text = try String(contentsOf: exported, encoding: .utf8)
        #expect(text.contains("POSITION_MARK") && text.contains("TEMPO"))
        #expect(text.contains("file://localhost/"))
        let imported = try await RekordboxSource(connection: SourceConnection(kind: .rekordbox, location: exported)).load(files: [:]).library
        #expect(imported.playlists.map(\.name) == ["Friday", "Warmup & Friends", "New in Deckhand"])
        #expect(imported.playlists[1].trackIds.compactMap { imported.tracks[$0]?.title } == ["One & Only", "Two"])
        #expect(imported.tracks.values.first { $0.title == "One & Only" }?.rating == 5)
        #expect(throws: (any Error).self) { try RekordboxSource.export(library, original: f.xml, to: f.xml) }
    }

    @Test func invalidXMLAndDuplicateTrackIDsAreRejected() async throws {
        let f = try SourceFixture()
        try "<not-rekordbox/>".write(to: f.xml, atomically: true, encoding: .utf8)
        let adapter = RekordboxSource(connection: SourceConnection(kind: .rekordbox, location: f.xml))
        await #expect(throws: (any Error).self) { try await adapter.load(files: [:]) }
        try f.writeXML()
        let duplicate = try String(contentsOf: f.xml, encoding: .utf8).replacingOccurrences(of: "TrackID=\"2\"", with: "TrackID=\"1\"")
        try duplicate.write(to: f.xml, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await adapter.load(files: [:]) }
    }
}
