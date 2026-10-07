import DeckhandCore
import Foundation
import Testing
@testable import OneLibrary

@Suite struct PhraseCodecTests {
    let sample = PhraseAnalysis(mood: 1, endBeat: 449, bank: 0, phrases: [
        .init(beat: 1, kind: 1), .init(beat: 33, kind: 2, k1: 1), .init(beat: 65, kind: 5, fill: 1, beatFill: 93),
        .init(beat: 193, kind: 3), .init(beat: 417, kind: 6),
    ])

    @Test func roundTrip() throws {
        for masked in [false, true] {
            let data = PhraseCodec.encode(sample, masked: masked)
            #expect(data.count == 32 + 24 * 5)
            #expect(try PhraseCodec.decode(data, masked: masked) == sample)
        }
    }

    @Test func maskingIsAnInvolution() {
        var data = PhraseCodec.encode(sample, masked: false)
        let original = data
        PhraseCodec.mask(&data, count: 5)
        #expect(data != original)
        #expect(data.prefix(18) == original.prefix(18)) // header through len_entries stays clear
        PhraseCodec.mask(&data, count: 5)
        #expect(data == original)
    }

    /// Re-encodes every phrase section in the local Rekordbox library (stored unmasked) and
    /// requires byte-identical output. Skipped when no Rekordbox library is present.
    @Test func matchesRekordboxLocalFiles() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Pioneer/rekordbox/share/PIONEER/USBANLZ")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var checked = 0
        for case let url as URL in e where url.lastPathComponent == "ANLZ0000.EXT" {
            guard let file = try? Data(contentsOf: url), let section = Self.section(file, "PSSI") else { continue }
            let decoded = try PhraseCodec.decode(section, masked: false)
            #expect(PhraseCodec.encode(decoded, masked: false) == section, "\(url.path)")
            checked += 1
        }
        if checked > 0 { print("checked \(checked) Rekordbox phrase sections") }
    }

    static func section(_ file: Data, _ tag: String) -> Data? {
        var r = BinaryReader(file)
        r.offset = 28
        while r.remaining >= 12 {
            let start = r.offset
            guard let t = try? r.ascii(4), (try? r.u32()) != nil, let len = try? r.u32(), len >= 12 else { return nil }
            if t == tag { return file.subdata(in: start..<(start + Int(len))) }
            r.offset = start + Int(len)
        }
        return nil
    }

    @Test func writtenLastInExt() throws {
        let analysis = TrackAnalysis(durationSeconds: 300, sampleRate: 44100, bpm: 120, beats: [], key: nil,
                                     waveforms: .init(peak: [0], rms: [0], low: [0], mid: [0], high: [0]))
        let ext = AnlzWriter(audioPath: "/Contents/a.mp3", analysis: analysis, totalSamples: 1, phrases: sample).build().ext
        let pssi = try #require(Self.section(ext, "PSSI"))
        #expect(ext.suffix(pssi.count) == pssi)
        #expect(try PhraseCodec.decode(pssi, masked: true) == sample)
        #expect(OneLibraryValidator.checkAnlz(ext, expectedPath: "/Contents/a.mp3") == nil)
    }

    /// Masked phrase sections from a Rekordbox 7 USB export (local fixture, not committed).
    @Test func matchesRekordboxUsbExport() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/private/golden-rats/pssi")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "pssi" {
            let raw = try Data(contentsOf: url)
            let decoded = try PhraseCodec.decode(raw, masked: true)
            #expect([1, 2, 3].contains(decoded.mood))
            #expect(PhraseCodec.encode(decoded, masked: true) == raw, "\(url.lastPathComponent)")
        }
    }
}
