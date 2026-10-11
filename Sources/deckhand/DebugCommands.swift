import Analysis
import ArgumentParser
import CSQLCipher
import DeckhandCore
import Foundation
import MusicSource
import OneLibrary
import Sync

struct DebugCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Developer tools.",
        shouldDisplay: false,
        subcommands: [WriteAnlz.self, AnalyzeTiming.self, HashCommand.self, MusicLiveCommand.self, RuntimeCheck.self]
    )
}

/// Checks the shipped model and database engine without accessing a user's library or Music.
struct RuntimeCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "runtime-check")
    func run() throws {
        let model = try AnalysisRuntime.verifyModel()
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK else {
            throw ValidationError("Couldn't initialize the bundled database engine")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA cipher_version", -1, &statement, nil) == SQLITE_OK else {
            throw ValidationError("Couldn't check the bundled SQLCipher version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw ValidationError("The bundled database engine isn't SQLCipher")
        }
        print("SQLCipher: \(String(cString: value))")
        print("Analysis model: \(model.path)")
        print("Runtime check passed")
    }
}

/// Writes ANLZ files for one audio file, for comparison against Rekordbox output.
struct WriteAnlz: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "anlz")

    @Argument(help: "Audio file.") var audio: String
    @Argument(help: "Output directory.") var out: String
    @Option(help: "USB-relative path to embed.") var usbPath = "/Contents/test.mp3"
    @Option(help: "JSON beat grid to use instead of detection: [[bar,timeMs,bpm],...]") var beats: String?

    func run() throws {
        let url = URL(fileURLWithPath: audio)
        let decoded = try AudioDecoder.decodeMono(url)
        let waveforms = WaveformAnalyzer.analyze(decoded)
        var grid: [TrackAnalysis.Beat] = []
        if let beats {
            let raw = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: beats)))
            grid = raw.map { .init(barPosition: Int($0[0]), timeMs: Int($0[1]), bpm: $0[2]) }
        }
        let analysis = TrackAnalysis(durationSeconds: decoded.durationSeconds, sampleRate: decoded.sampleRate,
                                     bpm: grid.first?.bpm ?? 0, beats: grid, key: nil, waveforms: waveforms)
        let files = AnlzWriter(audioPath: usbPath, analysis: analysis, totalSamples: UInt64(decoded.frameCount)).build()
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try files.dat.write(to: dir.appendingPathComponent("ANLZ0000.DAT"))
        try files.ext.write(to: dir.appendingPathComponent("ANLZ0000.EXT"))
        try files.twoEx.write(to: dir.appendingPathComponent("ANLZ0000.2EX"))
        try JSONEncoder().encode(waveforms).write(to: dir.appendingPathComponent("waveforms.json"))
        print("frames \(waveforms.frameCount) samples \(decoded.frameCount) sr \(decoded.sampleRate)")
    }
}

/// Times each analysis stage for one file.
struct AnalyzeTiming: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "analyze")

    @Argument var audio: String

    func run() throws {
        func time<T>(_ label: String, _ f: () throws -> T) rethrows -> T {
            let start = Date()
            let r = try f()
            print(String(format: "%-10@ %.2fs", label as NSString, Date().timeIntervalSince(start)))
            return r
        }
        let decoded = try time("decode") { try AudioDecoder.decodeMono(URL(fileURLWithPath: audio)) }
        _ = time("waveform") { WaveformAnalyzer.analyze(decoded) }
        let a = time("total") { TrackAnalyzer.analyze(decoded) }
        print("duration \(Int(decoded.durationSeconds))s  bpm \(a.bpm)  key \(a.key?.classic ?? "-")")
    }
}

/// Prints the audio-only content hash Deckhand uses to identify tracks.
struct HashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hash")

    @Argument var files: [String]

    func run() throws {
        let cache = try AnalysisCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-hash-\(UUID().uuidString)"))
        for f in files {
            print("\(try cache.contentHash(of: URL(fileURLWithPath: f)).prefix(19))  \((f as NSString).lastPathComponent)")
        }
    }
}

/// Reads Music live (read-only) and lists where iTunesLibrary's snapshot differs from it, field by field.
struct MusicLiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "music-live")

    @Option(help: "Tracks to list per field.") var limit = 5
    @Option(help: "Also read one track's rating by persistent ID, as the app reads a rating back after setting it.")
    var track: String?

    func run() throws {
        if let track { print("rating of \(track): \(try MusicEvents.rating(trackId: track))") }
        let snapshot = try AppleMusicLibrary.load(allSongs: true)
        print("access: \(MusicEvents.access(ask: false))")
        let start = Date()
        let live = try MusicLive.read()
        print("read \(live.count) file tracks live in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        var overlaid = snapshot
        let changed = MusicLive.overlay(live, onto: &overlaid)
        print("\(changed.count) of \(snapshot.tracks.count) snapshot tracks differ from Music")
        let fields: [(String, (SourceTrack) -> String)] = [
            ("title", { $0.title }), ("artist", { $0.artist ?? "nil" }), ("album", { $0.album ?? "nil" }),
            ("albumArtist", { $0.albumArtist ?? "nil" }), ("genre", { $0.genre ?? "nil" }),
            ("trackNumber", { "\($0.trackNumber ?? 0)" }), ("discNumber", { "\($0.discNumber ?? 0)" }), ("year", { "\($0.year ?? 0)" }),
            ("rating", { "\($0.rating ?? 0)" }), ("comment", { $0.comment ?? "nil" }),
        ]
        for (name, value) in fields {
            let diffs = changed.sorted().compactMap { id -> String? in
                let a = value(snapshot.tracks[id]!), b = value(overlaid.tracks[id]!)
                return a == b ? nil : "  \(id) \(snapshot.tracks[id]!.title.prefix(40)): \(a.debugDescription) -> \(b.debugDescription)"
            }
            guard !diffs.isEmpty else { continue }
            print("\(name): \(diffs.count)")
            diffs.prefix(limit).forEach { print($0) }
        }
    }
}
