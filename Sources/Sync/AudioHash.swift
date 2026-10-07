import CryptoKit
import Foundation

/// Hashes only the audio payload of a file, so metadata edits (tags, artwork, ratings written by
/// Apple Music or taggers) don't make a track look new. Falls back to the whole file for formats
/// it can't parse.
enum AudioHash {
    /// Prefix identifying the scheme, so hashes from different schemes never compare equal.
    static let scheme = "a2:"

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = UInt64(FileOps.size(url))
        let ranges = (try? audioRanges(handle, size: size, ext: url.pathExtension.lowercased())) ?? [0..<size]
        var hasher = SHA256()
        for range in ranges where !range.isEmpty {
            try handle.seek(toOffset: range.lowerBound)
            var remaining = range.count
            while remaining > 0, let chunk = try handle.read(upToCount: Int(min(UInt64(4 << 20), UInt64(remaining)))), !chunk.isEmpty {
                hasher.update(data: chunk)
                remaining -= chunk.count
            }
        }
        return scheme + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func audioRanges(_ h: FileHandle, size: UInt64, ext: String) throws -> [Range<UInt64>] {
        switch ext {
        case "mp3": return try mp3(h, size: size)
        case "m4a", "mp4", "aac", "alac": return try chunks(h, size: size, headerSize: 8, bigEndian: true, sizeIncludesHeader: true,
                                                            want: ["mdat"], container: [])
        case "wav": return try chunks(h, size: size, headerSize: 8, bigEndian: false, sizeIncludesHeader: false,
                                      want: ["data"], container: ["RIFF"])
        case "aif", "aiff": return try chunks(h, size: size, headerSize: 8, bigEndian: true, sizeIncludesHeader: false,
                                              want: ["SSND"], container: ["FORM"])
        case "flac": return try flac(h, size: size)
        default: return [0..<size]
        }
    }

    private static func read(_ h: FileHandle, at offset: UInt64, _ count: Int) throws -> [UInt8] {
        try h.seek(toOffset: offset)
        return Array(try h.read(upToCount: count) ?? Data())
    }

    /// Skips a leading ID3v2 tag (and footer) and trailing ID3v1 / APEv2 tags.
    private static func mp3(_ h: FileHandle, size: UInt64) throws -> [Range<UInt64>] {
        var start: UInt64 = 0
        let head = try read(h, at: 0, 10)
        if head.count == 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { // "ID3"
            let syncsafe = head[6..<10].reduce(UInt64(0)) { $0 << 7 | UInt64($1 & 0x7F) }
            start = 10 + syncsafe + (head[5] & 0x10 != 0 ? 10 : 0)
        }
        start += try xingFrameLength(h, at: start)
        var end = size
        if end >= 128, try read(h, at: end - 128, 3) == Array("TAG".utf8) { end -= 128 }
        if end >= 32, try read(h, at: end - 32, 8) == Array("APETAGEX".utf8) {
            let footer = try read(h, at: end - 32, 32)
            let tagSize = UInt64(footer[12]) | UInt64(footer[13]) << 8 | UInt64(footer[14]) << 16 | UInt64(footer[15]) << 24
            let hasHeader = footer[23] & 0x80 != 0
            end -= tagSize + (hasHeader ? 32 : 0)
        }
        return start < end ? [start..<end] : [0..<size]
    }

    /// Length of a leading Xing/Info (LAME) metadata frame, or 0. It carries no audio, and taggers
    /// rewrite its ReplayGain fields.
    private static func xingFrameLength(_ h: FileHandle, at offset: UInt64) throws -> UInt64 {
        let f = try read(h, at: offset, 48)
        guard f.count == 48, f[0] == 0xFF, f[1] & 0xE0 == 0xE0 else { return 0 }
        let version = (f[1] >> 3) & 0x3 // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
        let layer = (f[1] >> 1) & 0x3 // 1 = Layer III
        let bitrateIndex = Int(f[2] >> 4), rateIndex = Int((f[2] >> 2) & 0x3), padding = UInt64((f[2] >> 1) & 0x1)
        guard layer == 1, version != 1, (1...14).contains(bitrateIndex), rateIndex < 3 else { return 0 }
        let mpeg1 = version == 3
        let bitrates = mpeg1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let baseRates = [44100, 48000, 32000]
        let sampleRate = baseRates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let mono = (f[3] >> 6) == 3
        let sideInfo = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        let tag = Array(f[(4 + sideInfo)..<(8 + sideInfo)])
        guard tag == Array("Xing".utf8) || tag == Array("Info".utf8) else { return 0 }
        return UInt64((mpeg1 ? 144 : 72) * bitrates[bitrateIndex] * 1000 / sampleRate) + padding
    }

    /// Walks a chunked container (MP4 atoms, RIFF, IFF) and returns the payload of the wanted chunks.
    private static func chunks(_ h: FileHandle, size: UInt64, headerSize: UInt64, bigEndian: Bool,
                               sizeIncludesHeader: Bool, want: Set<String>, container: Set<String>) throws -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        var offset: UInt64 = 0
        while offset + headerSize <= size {
            let b = try read(h, at: offset, 8)
            guard b.count == 8 else { break }
            let id = String(decoding: (bigEndian && sizeIncludesHeader ? b[4..<8] : b[0..<4]), as: UTF8.self)
            let raw = bigEndian && sizeIncludesHeader ? Array(b[0..<4]) : Array(b[4..<8])
            var length = bigEndian
                ? raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                : raw.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var header = headerSize
            if sizeIncludesHeader && length == 1 { // 64-bit atom size
                let ext = try read(h, at: offset + 8, 8)
                length = ext.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header = 16
            } else if sizeIncludesHeader && length == 0 {
                length = size - offset
            }
            if container.contains(id) {
                offset += headerSize + 4 // RIFF/FORM header + form type; descend
                continue
            }
            let payloadStart = offset + header
            let payloadLength = sizeIncludesHeader ? length - header : length
            guard payloadLength <= size - payloadStart else { break }
            if want.contains(id) { out.append(payloadStart..<(payloadStart + payloadLength)) }
            offset = payloadStart + payloadLength + (!bigEndian || !sizeIncludesHeader ? payloadLength & 1 : 0)
        }
        return out.isEmpty ? [0..<size] : out
    }

    /// Skips the "fLaC" marker and metadata blocks (tags, pictures); hashes the frames.
    private static func flac(_ h: FileHandle, size: UInt64) throws -> [Range<UInt64>] {
        guard try read(h, at: 0, 4) == Array("fLaC".utf8) else { return [0..<size] }
        var offset: UInt64 = 4
        while offset + 4 <= size {
            let b = try read(h, at: offset, 4)
            let length = UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
            offset += 4 + length
            if b[0] & 0x80 != 0 { break } // last metadata block
        }
        return offset < size ? [offset..<size] : [0..<size]
    }
}
