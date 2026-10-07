import DeckhandCore
import Foundation

/// Writes Pioneer ANLZ analysis files (.DAT, .EXT, .2EX).
///
/// Section order and header values mirror files written by Rekordbox 7.
/// See docs/formats.md for field notes.
public struct AnlzWriter {
    public struct Options: Sendable {
        /// Write the extended beat grid (PQT2). Its per-beat payload is not fully
        /// understood; Rekordbox omits it for some files.
        public var includeExtendedBeatGrid = false
        /// XOR-mask the phrase section the way Rekordbox 6+ USB exports do.
        public var maskPhrases = true

        public init() {}
    }

    public struct Files {
        public var dat: Data
        public var ext: Data
        public var twoEx: Data
    }

    /// USB-relative audio path, e.g. "/Contents/Deckhand/AB/x.mp3".
    let audioPath: String
    let analysis: TrackAnalysis
    /// Total decoded sample frames in the audio file.
    let totalSamples: UInt64
    let options: Options
    let cues: [CuePoint]
    let phrases: PhraseAnalysis?

    public init(audioPath: String, analysis: TrackAnalysis, totalSamples: UInt64, cues: [CuePoint] = [],
                phrases: PhraseAnalysis? = nil, options: Options = .init()) {
        self.phrases = phrases
        self.cues = cues.sorted { $0.timeMs < $1.timeMs }
        self.audioPath = audioPath
        self.analysis = analysis
        self.totalSamples = totalSamples
        self.options = options
    }

    public func build() -> Files {
        let wf = WaveformEncoder(analysis.waveforms)

        let dat = file([
            ppth(),
            pvbr(),
            pqtz(),
            pwav(wf.monoPreview(count: 400)),
            pwv2(wf.tinyPreview(count: 100)),
            pcob(hot: true, list: legacyHotCues(1...3)),
            pcob(hot: false, list: cueList(hot: false)),
        ])

        var extSections = [
            ppth(),
            pwv3(wf.monoDetail()),
            pcob(hot: true, list: legacyHotCues(4...8)),
            pcob(hot: false, list: []),
            pco2(hotCues: true),
            pco2(hotCues: false),
        ]
        if options.includeExtendedBeatGrid { extSections.append(pqt2()) }
        extSections.append(pwv5(wf.colorDetail()))
        extSections.append(pwv4(wf.colorPreview(count: 1200)))
        if let phrases, !phrases.phrases.isEmpty {
            extSections.append(PhraseCodec.encode(phrases, masked: options.maskPhrases))
        }
        let ext = file(extSections)

        let twoEx = file([
            ppth(),
            pwv7(wf.threeBand(frames: nil)),
            pwv6(wf.threeBand(frames: 1200)),
            pwvc(wf.threeBandScale()),
        ])

        return Files(dat: dat, ext: ext, twoEx: twoEx)
    }

    // MARK: - File container

    private func file(_ sections: [Data]) -> Data {
        let bodyLength = sections.reduce(0) { $0 + $1.count }
        var w = BinaryWriter()
        w.ascii("PMAI")
        w.u32(28)
        w.u32(UInt32(28 + bodyLength))
        w.u32(1)
        w.u32(0x10000)
        w.u32(0x10000)
        w.u32(0)
        var out = w.data
        for s in sections { out.append(s) }
        return out
    }

    /// Writes a section: tag, header length, total length, then header fields and body.
    private func section(_ tag: String, header: (inout BinaryWriter) -> Void, body: (inout BinaryWriter) -> Void = { _ in }) -> Data {
        var h = BinaryWriter()
        header(&h)
        var b = BinaryWriter()
        body(&b)
        var w = BinaryWriter()
        w.ascii(tag)
        w.u32(UInt32(12 + h.count))
        w.u32(UInt32(12 + h.count + b.count))
        w.bytes(h.data)
        w.bytes(b.data)
        return w.data
    }

    // MARK: - Sections

    private func ppth() -> Data {
        // UTF-16BE including a null terminator; players reject the file without it.
        let byteLength = (audioPath.utf16.count + 1) * 2
        return section("PPTH", header: { $0.u32(UInt32(byteLength)) }, body: {
            $0.utf16BE(audioPath)
            $0.u16(0)
        })
    }

    private func pvbr() -> Data {
        // 400-entry seek index; Rekordbox leaves it zeroed for CBR and lossless files.
        section("PVBR", header: { $0.u32(0) }, body: {
            $0.zeros(400 * 4)
            $0.u32(UInt32(truncatingIfNeeded: totalSamples))
        })
    }

    private func pqtz() -> Data {
        let beats = analysis.beats
        return section("PQTZ", header: {
            $0.u32(0)
            $0.u32(0x80000)
            $0.u32(UInt32(beats.count))
        }, body: { w in
            for beat in beats {
                w.u16(UInt16(beat.barPosition))
                w.u16(UInt16((beat.bpm * 100).rounded()))
                w.u32(UInt32(max(0, beat.timeMs)))
            }
        })
    }

    private func pqt2() -> Data {
        let beats = analysis.beats
        guard let first = beats.first, let last = beats.last else {
            return section("PQT2", header: { $0.zeros(44) })
        }
        return section("PQT2", header: { w in
            w.u32(0)
            w.u32(0x0100_0002)
            w.u32(0)
            for b in [first, last] {
                w.u16(UInt16(b.barPosition))
                w.u16(UInt16((b.bpm * 100).rounded()))
                w.u32(UInt32(b.timeMs))
            }
            w.u32(UInt32(beats.count))
            w.u32(0)
            w.u32(0)
            w.u32(0)
        }, body: { w in
            w.zeros(beats.count * 2)
        })
    }

    private func pwav(_ entries: [UInt8]) -> Data {
        section("PWAV", header: { $0.u32(UInt32(entries.count)); $0.u32(0x10000) }, body: { $0.bytes(entries) })
    }

    private func pwv2(_ entries: [UInt8]) -> Data {
        section("PWV2", header: { $0.u32(UInt32(entries.count)); $0.u32(0x10000) }, body: { $0.bytes(entries) })
    }

    private func cueList(hot: Bool) -> [CuePoint] {
        cues.filter { if case .hot = $0.kind { hot } else { !hot } }
    }

    private func hotIndex(_ c: CuePoint) -> UInt32 {
        if case .hot(let n) = c.kind { UInt32(n) } else { 0 }
    }

    /// Hot cues in the given slots, highest slot first (Rekordbox's order).
    private func legacyHotCues(_ slots: ClosedRange<UInt32>) -> [CuePoint] {
        cueList(hot: true).filter { slots.contains(hotIndex($0)) }.sorted { hotIndex($0) > hotIndex($1) }
    }

    /// Legacy cue list (PCOB with PCPT entries). Rekordbox puts hot cues A–C and memory cues in
    /// the .DAT, hot cues D–H in the .EXT.
    private func pcob(hot: Bool, list: [CuePoint]) -> Data {
        section("PCOB", header: {
            $0.u32(hot ? 1 : 0)
            $0.u16(0)
            $0.u16(UInt16(list.count))
            $0.u32(hot || list.isEmpty ? 0xFFFF_FFFF : 0)
        }, body: { w in
            for c in list {
                w.ascii("PCPT")
                w.u32(0x1C)
                w.u32(0x38)
                w.u32(hotIndex(c))
                w.u32(0) // status
                w.u32(0x10000)
                w.u16(0xFFFF)
                w.u16(0xFFFF)
                w.u8(1) // single cue, not a loop
                w.u8(0)
                w.u16(1000)
                w.u32(UInt32(max(0, c.timeMs)))
                w.u32(0xFFFF_FFFF) // loop end
                w.zeros(16)
            }
        })
    }

    /// Extended cue list (PCO2 with PCP2 entries): every hot or memory cue, with comment and color.
    private func pco2(hotCues: Bool) -> Data {
        var list = cueList(hot: hotCues)
        if hotCues { list.sort { hotIndex($0) > hotIndex($1) } }
        return section("PCO2", header: {
            $0.u32(hotCues ? 1 : 0)
            $0.u16(UInt16(list.count))
            $0.u16(0)
        }, body: { w in
            for c in list {
                var comment = BinaryWriter()
                if let text = c.comment, !text.isEmpty {
                    comment.utf16BE(text)
                    comment.u16(0)
                }
                // Layout as written by Rekordbox 7: 48 fixed bytes + comment + 40 trailing zero bytes.
                let length = 48 + comment.count + 40
                let start = w.count
                w.ascii("PCP2")
                w.u32(0x10)
                w.u32(UInt32(length))
                w.u32(hotIndex(c))
                w.u8(1) // single cue, not a loop
                w.u8(0)
                w.u16(1000)
                w.u32(UInt32(max(0, c.timeMs)))
                w.u32(0xFFFF_FFFF) // loop end
                w.u8(0) // color table index
                w.u8(1)
                w.zeros(6)
                w.u16(0) // loop numerator
                w.u16(0) // loop denominator
                w.u32(UInt32(comment.count))
                w.bytes(comment.data)
                let (r, g, b) = c.color ?? (0, 0, 0)
                w.u8(0)
                w.u8(r)
                w.u8(g)
                w.u8(b)
                w.zeros(length - (w.count - start))
            }
        })
    }

    private func pwv3(_ entries: [UInt8]) -> Data {
        section("PWV3", header: {
            $0.u32(1)
            $0.u32(UInt32(entries.count))
            $0.u32(0x0096_0000)
        }, body: { $0.bytes(entries) })
    }

    private func pwv5(_ entries: [UInt16]) -> Data {
        section("PWV5", header: {
            $0.u32(2)
            $0.u32(UInt32(entries.count))
            $0.u32(0x0096_0305)
        }, body: { w in entries.forEach { w.u16($0) } })
    }

    private func pwv4(_ entries: [UInt8]) -> Data {
        section("PWV4", header: {
            $0.u32(6)
            $0.u32(UInt32(entries.count / 6))
            $0.u32(0)
        }, body: { $0.bytes(entries) })
    }

    private func pwv7(_ entries: [UInt8]) -> Data {
        section("PWV7", header: {
            $0.u32(3)
            $0.u32(UInt32(entries.count / 3))
            $0.u32(0x0096_0000)
        }, body: { $0.bytes(entries) })
    }

    private func pwv6(_ entries: [UInt8]) -> Data {
        section("PWV6", header: {
            $0.u32(3)
            $0.u32(UInt32(entries.count / 3))
        }, body: { $0.bytes(entries) })
    }

    private func pwvc(_ scale: (UInt16, UInt16, UInt16)) -> Data {
        section("PWVC", header: { $0.u16(0) }, body: {
            $0.u16(scale.0)
            $0.u16(scale.1)
            $0.u16(scale.2)
        })
    }
}
