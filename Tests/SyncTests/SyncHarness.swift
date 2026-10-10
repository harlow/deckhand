import Analysis
import CoreGraphics
import DeckhandCore
import Foundation
import ImageIO
import OneLibrary
import Testing
import UniformTypeIdentifiers
@testable import Sync

/// Cover art that tests can change.
final class TestArtwork: ArtworkProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: Data] = [:]

    subscript(id: String) -> Data? {
        get { lock.withLock { images[id] } }
        set { lock.withLock { images[id] = newValue } }
    }

    func artwork(forTrackId id: String) -> Data? { self[id] }

    static func png(_ shade: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.3, blue: 1 - shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// A source library, analysis cache and drive (a temporary directory) for end-to-end sync tests.
final class SyncHarness {
    let root: URL
    let music: URL
    let drive: URL
    let cache: AnalysisCache
    var volume: Volume
    var library = SourceLibrary(playlists: [], tracks: [:])
    var settings = OutputSettings()
    var analyzeMissing = false
    let art = TestArtwork()
    var useArtwork = false
    private var modified = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-sync-\(UUID().uuidString)")
        music = root.appendingPathComponent("music")
        drive = root.appendingPathComponent("DRIVE")
        for d in [music, drive] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        cache = try AnalysisCache(root: root.appendingPathComponent("cache"))
        volume = Volume(testRoot: drive)
        try Manifest().save(to: volume)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: Library

    func file(_ id: String, ext: String = "mp3") -> URL { music.appendingPathComponent("\(id).\(ext)") }

    /// An MP3-ish file: an ID3 tag (ignored by the audio hash) and a payload derived from `audio`.
    func writeAudio(_ url: URL, audio: String, tag: String = "") throws {
        let body = Array("TIT2".utf8) + [0, 0, 0, UInt8(tag.utf8.count + 1), 0, 0, 0] + Array(tag.utf8)
        let n = body.count
        var bytes = Array("ID3".utf8) + [4, 0, 0, 0, 0, UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + body
        let unit = Array("audio:\(audio);".utf8)
        for i in 0..<(2000 + audio.count * 37) { bytes.append(unit[i % unit.count]) }
        try Data(bytes).write(to: url)
    }

    @discardableResult
    func addTrack(_ id: String, title: String? = nil, artist: String? = "Artist", audio: String? = nil, ext: String = "mp3",
                  rating: Int? = nil) throws -> SourceTrack {
        let url = file(id, ext: ext)
        try writeAudio(url, audio: audio ?? id)
        let t = SourceTrack(id: id, title: title ?? "Song \(id)", artist: artist, genre: "House", rating: rating,
                            durationSeconds: 200, location: url, dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
                            modifiedDate: modified, fileSize: FileOps.size(url))
        library.tracks[id] = t
        return t
    }

    /// Edits a track as Music would: changes it and bumps its modification date.
    func edit(_ id: String, _ change: (inout SourceTrack) -> Void) {
        modified = modified.addingTimeInterval(60)
        change(&library.tracks[id]!)
        library.tracks[id]!.modifiedDate = modified
    }

    func setPlaylist(_ id: String, _ name: String? = nil, parent: String? = nil, folder: Bool = false, _ tracks: [String] = []) {
        let p = SourcePlaylist(id: id, name: name ?? id, parentId: parent, isFolder: folder, trackIds: tracks)
        if let i = library.playlists.firstIndex(where: { $0.id == id }) { library.playlists[i] = p } else { library.playlists.append(p) }
    }

    func hash(_ id: String) throws -> String { try cache.contentHash(of: library.tracks[id]!.location!) }

    /// Stores a synthetic analysis for the track's current audio, as `deckhand analyze` would.
    func analyze(_ id: String, bpm: Double? = nil) throws {
        let h = try hash(id)
        let seed = id.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let bpm = bpm ?? 120 + Double(seed % 8)
        let n = 3000
        let wave = (0..<n).map { Float(($0 * 37 + id.count * 11) % 101) / 100 }
        let beats = (0..<300).map { TrackAnalysis.Beat(barPosition: $0 % 4 + 1, timeMs: 100 + $0 * 500, bpm: bpm) }
        let a = TrackAnalysis(durationSeconds: 20, sampleRate: 44100, bpm: bpm, beats: beats,
                              key: MusicalKey(tonic: seed % 12, mode: .minor),
                              waveforms: .init(peak: wave, rms: wave, low: wave, mid: wave.reversed(), high: wave))
        let cues = CueAnalyzer.Result(cues: [.init(timeMs: 1000, energy: 5), .init(timeMs: 8000, energy: 7)], energy: 6)
        let sections = [StructureAnalyzer.Section(kind: .intro, startBeat: 0, startMs: 100, endMs: 32_100, energy: 0.3),
                        StructureAnalyzer.Section(kind: .drop, startBeat: 64, startMs: 32_100, endMs: 80_100, energy: 0.9),
                        StructureAnalyzer.Section(kind: .outro, startBeat: 160, startMs: 80_100, endMs: 150_100, energy: 0.4)]
        try cache.store(a, cues: cues, sections: sections, forHash: h)
    }

    // MARK: Drive

    func manifest() throws -> Manifest { try #require(try Manifest.load(from: volume)) }

    /// Changes the drive's selection the way the app does.
    func select(_ ids: [String], entireLibrary: Bool? = nil) throws {
        try Manifest.edit(on: volume) { m in
            m.selectedPlaylistIds = ids
            if let entireLibrary { m.entireLibrary = entireLibrary }
        }
    }

    var profile: OutputProfile {
        var p = OutputProfile(settings: settings)
        p.analyzeMissing = analyzeMissing
        p.artwork = useArtwork
        return p
    }

    var planner: SyncPlanner {
        var lib = library
        lib.artwork = useArtwork ? art : nil
        return SyncPlanner(library: lib, cache: cache)
    }

    func evaluate(selection: Selection? = nil, adoptable: [String: String] = [:]) throws -> ChangeSet {
        planner.plan(volume: volume, manifest: try manifest(), profile: profile, selection: selection, adoptable: adoptable)
    }

    func executor() -> SyncExecutor {
        var e = SyncExecutor(cache: cache)
        e.artwork = useArtwork ? art : nil
        return e
    }

    struct Run {
        var before: ChangeSet
        var result: SyncResult
        var after: ChangeSet
    }

    /// Plans, executes and re-evaluates; checks that the executor did what was planned, that nothing is left to do,
    /// and that the drive's library is valid.
    @discardableResult
    func sync(selection: Selection? = nil, adoptable: [String: String] = [:],
              sourceLocation: SourceLocation = #_sourceLocation) throws -> Run {
        let before = try evaluate(selection: selection, adoptable: adoptable)
        let result = try executor().execute(before, on: volume)
        let after = try planner.verify(volume: volume, profile: profile)
        checkPrediction(before, result, sourceLocation: sourceLocation)
        #expect(after.isClean, "still pending after sync: \(describe(after))", sourceLocation: sourceLocation)
        if FileManager.default.fileExists(atPath: dbURL.path) { #expect(try validate() == [], sourceLocation: sourceLocation) }
        return Run(before: before, result: result, after: after)
    }

    /// What the executor did matches the plan.
    func checkPrediction(_ c: ChangeSet, _ r: SyncResult, sourceLocation: SourceLocation = #_sourceLocation) {
        func ids(_ change: ChangeSet.TrackChange) -> Set<String> { Set(c.tracks.filter { $0.changes.contains(change) }.map(\.id)) }
        let copying = Set(c.tracks.filter(\.copies).map(\.id))
        #expect(Set(r.copied).isSubset(of: copying.union(ids(.adopt))), sourceLocation: sourceLocation)
        #expect(copying.isSubset(of: Set(r.copied)), "planned copies not made", sourceLocation: sourceLocation)
        #expect(Set(r.adopted).isSubset(of: ids(.adopt)), sourceLocation: sourceLocation)
        #expect(Set(r.analyzed + r.analysisFailed) == ids(.analyze), sourceLocation: sourceLocation)
        #expect(Set(r.anlzChecked) == ids(.analysisFiles).union(Set(r.analyzed)), sourceLocation: sourceLocation)
        #expect(Set(r.anlzWritten).isSubset(of: Set(r.anlzChecked)), sourceLocation: sourceLocation)
        #expect(Set(r.artworkChecked) == ids(.artworkCheck), sourceLocation: sourceLocation)
        #expect(Set(r.removed) == Set(c.removedTracks.filter(\.deletesFiles).map(\.record.usbPath)), sourceLocation: sourceLocation)
        // A database write is predicted exactly, except that analysis can fail and art can turn out unchanged.
        if r.wroteDatabase {
            #expect(c.needsDatabaseWrite || !ids(.artworkCheck).isEmpty, sourceLocation: sourceLocation)
        } else if ids(.analyze).isEmpty {
            #expect(!c.needsDatabaseWrite, sourceLocation: sourceLocation)
        }
        if c.isClean { #expect(r.manifest == nil && !r.wroteDatabase && r.anlzWritten.isEmpty, sourceLocation: sourceLocation) }
    }

    func describe(_ c: ChangeSet) -> String {
        let tracks = c.tracks.filter { !$0.changes.isEmpty }.map { "\($0.id):\($0.changes.sorted().map(\.rawValue))" }
        let playlists = c.playlists.filter { $0.status != .clean }.map { "\($0.source.id):\($0.status)" }
        return "tracks \(tracks) removed \(c.removedTracks.map { "\($0.id):\($0.reason)" }) playlists \(playlists) "
            + "removedPlaylists \(c.removedPlaylists.map(\.name)) drive \(c.drive)"
    }

    var dbURL: URL { volume.url(forUsbPath: DriveProbe.databasePath) }

    func validate() throws -> [String] { try OneLibraryValidator.validate(database: dbURL, volumeRoot: drive) }

    func database() throws -> DeviceLibrary { try DeviceLibrary.read(database: dbURL) }

    func exists(_ usbPath: String) -> Bool { FileManager.default.fileExists(atPath: volume.url(forUsbPath: usbPath).path) }

    func anlz(_ usbPath: String, _ ext: String = "DAT") -> URL {
        volume.url(forUsbPath: AnlzPath.directory(forAudioPath: usbPath) + "/ANLZ0000.\(ext)")
    }

    /// Modification dates of every file on the drive, to tell what a sync rewrote.
    func snapshot() -> [String: Date] {
        var out: [String: Date] = [:]
        let e = FileManager.default.enumerator(at: drive, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[String(u.path.dropFirst(drive.path.count))] = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return out
    }
}
