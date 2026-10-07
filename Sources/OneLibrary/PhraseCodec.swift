import DeckhandCore
import Foundation

/// Encodes/decodes the PSSI (song structure) ANLZ section.
///
/// Layout: 32-byte header (len_entry_bytes = 24, len_entries u16, mood u16, 6 unknown bytes,
/// end_beat u16, 2 flag bytes, bank u8, 1 unknown byte) then 24-byte phrase entries.
/// Rekordbox 6+ USB exports XOR-mask every byte after len_entries; see `mask`.
enum PhraseCodec {
    private static let maskKey: [UInt8] = [
        0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2, 0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1,
    ]
    /// Offset of the first masked byte within the section (just after len_entries).
    static let maskStart = 18

    /// Encodes a complete PSSI section (tag through last entry).
    static func encode(_ p: PhraseAnalysis, masked: Bool) -> Data {
        var w = BinaryWriter()
        w.ascii("PSSI")
        w.u32(32)
        w.u32(UInt32(32 + 24 * p.phrases.count))
        w.u32(24)
        w.u16(UInt16(p.phrases.count))
        w.u16(UInt16(p.mood))
        w.zeros(6)
        w.u16(UInt16(p.endBeat))
        w.u8(p.flags.count > 0 ? p.flags[0] : 0)
        w.u8(p.flags.count > 1 ? p.flags[1] : 0)
        w.u8(UInt8(p.bank))
        w.zeros(1)
        for (i, e) in p.phrases.enumerated() {
            w.u16(UInt16(i + 1))
            w.u16(UInt16(e.beat))
            w.u16(UInt16(e.kind))
            w.u8(0)
            w.u8(UInt8(e.k1))
            w.u8(0)
            w.u8(UInt8(e.k2))
            w.u8(0)
            w.u8(UInt8(e.b))
            w.u16(UInt16(e.beat2))
            w.u16(UInt16(e.beat3))
            w.u16(UInt16(e.beat4))
            w.u8(0)
            w.u8(UInt8(e.k3))
            w.u8(0)
            w.u8(UInt8(e.fill))
            w.u16(UInt16(e.beatFill))
        }
        var data = w.data
        if masked { mask(&data, count: p.phrases.count) }
        return data
    }

    /// Decodes a PSSI section. Unknown bytes are dropped, so re-encoding canonicalizes them to zero.
    static func decode(_ section: Data, masked: Bool) throws -> PhraseAnalysis {
        var data = section
        var r = BinaryReader(data)
        guard try r.ascii(4) == "PSSI" else { throw BinaryError.truncated }
        r.offset = 16
        let count = Int(try r.u16())
        if masked { mask(&data, count: count) }
        r = BinaryReader(data, offset: 18)
        let mood = Int(try r.u16())
        try r.skip(6)
        let endBeat = Int(try r.u16())
        let flags = [try r.u8(), try r.u8()]
        let bank = Int(try r.u8())
        try r.skip(1)
        var phrases: [PhraseAnalysis.Phrase] = []
        for _ in 0..<count {
            _ = try r.u16()
            let beat = Int(try r.u16()), kind = Int(try r.u16())
            _ = try r.u8(); let k1 = Int(try r.u8())
            _ = try r.u8(); let k2 = Int(try r.u8())
            _ = try r.u8(); let b = Int(try r.u8())
            let beat2 = Int(try r.u16()), beat3 = Int(try r.u16()), beat4 = Int(try r.u16())
            _ = try r.u8(); let k3 = Int(try r.u8())
            _ = try r.u8(); let fill = Int(try r.u8())
            let beatFill = Int(try r.u16())
            phrases.append(.init(beat: beat, kind: kind, k1: k1, k2: k2, k3: k3, b: b,
                                 beat2: beat2, beat3: beat3, beat4: beat4, fill: fill, beatFill: beatFill))
        }
        return PhraseAnalysis(mood: mood, endBeat: endBeat, bank: bank, flags: flags, phrases: phrases)
    }

    /// XOR-masks (or unmasks — it's an involution) bytes after len_entries.
    static func mask(_ data: inout Data, count: Int) {
        let base = data.startIndex
        for i in maskStart..<data.count {
            let k = maskKey[(i - maskStart) % maskKey.count] &+ UInt8(truncatingIfNeeded: count)
            data[base + i] ^= k
        }
    }
}
