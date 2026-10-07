import Foundation

/// Minimal big-endian byte buffer used for Pioneer binary formats.
struct BinaryWriter {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v >> 8))
        data.append(UInt8(v & 0xFF))
    }

    mutating func u32(_ v: UInt32) {
        data.append(UInt8(v >> 24))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(v >> 32))
        u32(UInt32(v & 0xFFFF_FFFF))
    }

    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

    mutating func bytes<S: Sequence>(_ b: S) where S.Element == UInt8 { data.append(contentsOf: b) }

    mutating func zeros(_ n: Int) { data.append(contentsOf: repeatElement(0, count: n)) }

    mutating func utf16BE(_ s: String) {
        for unit in s.utf16 { u16(unit) }
    }

    /// Overwrites a big-endian u32 at `offset`.
    mutating func patchU32(at offset: Int, _ v: UInt32) {
        data[offset] = UInt8(v >> 24)
        data[offset + 1] = UInt8((v >> 16) & 0xFF)
        data[offset + 2] = UInt8((v >> 8) & 0xFF)
        data[offset + 3] = UInt8(v & 0xFF)
    }
}

/// Minimal big-endian reader, used by validation and tests.
struct BinaryReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw BinaryError.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try u8()) << 8 | UInt16(try u8())
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try u16()) << 16 | UInt32(try u16())
    }

    mutating func ascii(_ n: Int) throws -> String {
        guard remaining >= n else { throw BinaryError.truncated }
        defer { offset += n }
        let start = data.startIndex + offset
        return String(decoding: data[start..<start + n], as: UTF8.self)
    }

    mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw BinaryError.truncated }
        offset += n
    }
}

enum BinaryError: Error {
    case truncated
}
