import Analysis
import ArgumentParser
import DeckhandCore
import Foundation
import OneLibrary

struct DebugCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Developer tools.",
        shouldDisplay: false,
        subcommands: [WriteAnlz.self, AnalyzeTiming.self]
    )
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
