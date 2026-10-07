import DeckhandCore
import Foundation
import Testing
@testable import OneLibrary

/// Cue entries must match Rekordbox 7's byte layout (reference bytes from a Rekordbox USB export).
@Suite struct AnlzCueTests {
    static func hex(_ s: String) -> Data {
        let digits = s.filter(\.isHexDigit)
        var out = Data()
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            out.append(UInt8(digits[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// All sections with `tag`, in file order.
    static func sections(_ file: Data, _ tag: String) -> [Data] {
        var out: [Data] = []
        var r = BinaryReader(file)
        r.offset = 28
        while r.remaining > 0 {
            let start = r.offset
            let t = try! r.ascii(4)
            _ = try! r.u32()
            let length = Int(try! r.u32())
            if t == tag { out.append(file.subdata(in: start..<(start + length))) }
            r.offset = start + length
        }
        return out
    }

    func files(_ cues: [CuePoint]) -> AnlzWriter.Files {
        let analysis = TrackAnalysis(durationSeconds: 300, sampleRate: 44100, bpm: 120, beats: [], key: nil,
                                     waveforms: .init(peak: [0], rms: [0], low: [0], mid: [0], high: [0]))
        return AnlzWriter(audioPath: "/Contents/a.mp3", analysis: analysis, totalSamples: 1, cues: cues).build()
    }

    @Test func hotCueMatchesRekordbox() {
        let cue = CuePoint(kind: .hot(4), timeMs: 0x2DD2A, comment: "CUE(Auto)", rgb: [0x4D, 0x00, 0xFF])
        let f = files([cue])

        let pco2 = Self.sections(f.ext, "PCO2")[0]
        let expectedEntry = Self.hex("""
            50435032 00000010 0000006c 00000004 010003e8 0002dd2a ffffffff 00010000 00000000 00000000 00000014
            00430055 00450028 00410075 0074006f 00290000 004d00ff
            """) + Data(count: 40)
        #expect(pco2.prefix(20) == Self.hex("50434f32 00000014 00000080 00000001 00010000"))
        #expect(pco2.dropFirst(20) == expectedEntry)

        // Hot cue D goes in the .EXT legacy list, not the .DAT one.
        let extPcob = Self.sections(f.ext, "PCOB")[0]
        #expect(extPcob == Self.hex("""
            50434f42 00000018 00000050 00000001 00000001 ffffffff
            50435054 0000001c 00000038 00000004 00000000 00010000 ffffffff 010003e8 0002dd2a ffffffff
            00000000 00000000 00000000 00000000
            """))
        #expect(Self.sections(f.dat, "PCOB")[0] == Self.hex("50434f42 00000018 00000018 00000001 00000000 ffffffff"))
    }

    @Test func memoryCueMatchesRekordbox() {
        let f = files([CuePoint(kind: .memory, timeMs: 0)])
        #expect(Self.sections(f.dat, "PCOB")[1] == Self.hex("""
            50434f42 00000018 00000050 00000000 00000001 00000000
            50435054 0000001c 00000038 00000000 00000000 00010000 ffffffff 010003e8 00000000 ffffffff
            00000000 00000000 00000000 00000000
            """))
        let pco2 = Self.sections(f.ext, "PCO2")[1]
        #expect(pco2.dropFirst(20) == Self.hex("""
            50435032 00000010 00000058 00000000 010003e8 00000000 ffffffff 00010000 00000000 00000000 00000000 00000000
            """) + Data(count: 40))
    }
}
