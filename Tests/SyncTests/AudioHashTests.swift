import Foundation
import Testing
@testable import Sync

@Suite struct AudioHashTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiohash-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { Array(be32(v).reversed()) }
    let audio: [UInt8] = Array(repeating: 0xAB, count: 300) + [1, 2, 3]

    func id3(_ text: String) -> [UInt8] {
        let body = Array("TIT2".utf8) + be32(text.utf8.count + 1) + [0, 0, 0] + Array(text.utf8)
        let n = body.count
        let syncsafe: [UInt8] = [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]
        return Array("ID3".utf8) + [4, 0, 0] + syncsafe + body
    }

    @Test func mp3IgnoresTags() throws {
        let a = try write("a.mp3", id3("Old title") + audio)
        let b = try write("b.mp3", id3("A much longer new title") + audio + Array("TAG".utf8) + Array(repeating: 0, count: 125))
        let c = try write("c.mp3", id3("Old title") + audio.dropLast() + [9])
        #expect(try AudioHash.hash(a) == AudioHash.hash(b))
        #expect(try AudioHash.hash(a) != AudioHash.hash(c))
    }

    /// MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo: 417-byte frames; Xing/Info tag at offset 36.
    func infoFrame(replayGain: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 417)
        f[0] = 0xFF; f[1] = 0xFB; f[2] = 0x90; f[3] = 0x00
        f.replaceSubrange(36..<40, with: Array("Info".utf8))
        f[160] = replayGain
        return f
    }

    @Test func mp3IgnoresLameHeaderFrame() throws {
        let a = try write("x.mp3", id3("t") + infoFrame(replayGain: 1) + audio)
        let b = try write("y.mp3", id3("t") + infoFrame(replayGain: 9) + audio)
        let c = try write("z.mp3", id3("t") + infoFrame(replayGain: 1) + audio.dropLast() + [0])
        #expect(try AudioHash.hash(a) == AudioHash.hash(b))
        #expect(try AudioHash.hash(a) != AudioHash.hash(c))
    }

    @Test func m4aHashesOnlyMdat() throws {
        func atom(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(payload.count + 8) + Array(type.utf8) + payload }
        let a = try write("a.m4a", atom("ftyp", Array("M4A ".utf8)) + atom("moov", [1, 2, 3]) + atom("mdat", audio))
        let b = try write("b.m4a", atom("ftyp", Array("M4A ".utf8)) + atom("moov", Array(repeating: 7, count: 50)) + atom("mdat", audio))
        #expect(try AudioHash.hash(a) == AudioHash.hash(b))
    }

    @Test func wavHashesOnlyData() throws {
        func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            Array(id.utf8) + le32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
        }
        func riff(_ chunks: [UInt8]) -> [UInt8] { Array("RIFF".utf8) + le32(chunks.count + 4) + Array("WAVE".utf8) + chunks }
        let a = try write("a.wav", riff(chunk("fmt ", Array(repeating: 1, count: 16)) + chunk("data", audio)))
        let b = try write("b.wav", riff(chunk("fmt ", Array(repeating: 1, count: 16)) + chunk("LIST", [1, 2, 3]) + chunk("data", audio)))
        #expect(try AudioHash.hash(a) == AudioHash.hash(b))
    }

    @Test func flacSkipsMetadata() throws {
        func block(_ type: UInt8, last: Bool, _ payload: [UInt8]) -> [UInt8] {
            [type | (last ? 0x80 : 0), UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)] + payload
        }
        let streamInfo = block(0, last: false, Array(repeating: 2, count: 34))
        let a = try write("a.flac", Array("fLaC".utf8) + streamInfo + block(4, last: true, [1, 2]) + audio)
        let b = try write("b.flac", Array("fLaC".utf8) + streamInfo + block(4, last: true, Array(repeating: 5, count: 90)) + audio)
        #expect(try AudioHash.hash(a) == AudioHash.hash(b))
    }

    @Test func unknownFormatHashesWholeFile() throws {
        let a = try write("a.ogg", audio)
        let b = try write("b.ogg", audio + [0])
        #expect(try AudioHash.hash(a) != AudioHash.hash(b))
        #expect(try AudioHash.hash(a).hasPrefix(AudioHash.scheme))
    }
}
