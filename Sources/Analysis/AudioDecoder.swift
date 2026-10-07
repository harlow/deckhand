import AudioToolbox
import AVFoundation
import Foundation

/// Decoded mono PCM for analysis.
public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    /// Sample frames in the source file (per channel).
    public let frameCount: Int
    public let channelCount: Int
    /// How far the DJ player's timeline runs ahead of the decoded samples, in frames.
    /// Core Audio trims MP3 encoder/decoder delay that Pioneer players keep (see `mp3TimelineOffset`).
    public var timelineOffsetFrames: Int = 0

    public var durationSeconds: Double { Double(frameCount) / Double(sampleRate) }
    public var timelineOffsetSeconds: Double { Double(timelineOffsetFrames) / Double(sampleRate) }
}

public enum AudioDecoderError: Error, CustomStringConvertible {
    case cannotOpen(URL, underlying: Error)
    case readFailed(URL, underlying: Error)

    public var description: String {
        switch self {
        case .cannotOpen(let url, let e): return "Cannot open audio file \(url.path): \(e.localizedDescription)"
        case .readFailed(let url, let e): return "Failed reading audio file \(url.path): \(e.localizedDescription)"
        }
    }
}

public enum AudioDecoder {
    /// Decodes a file (MP3, AAC/M4A, ALAC, WAV, AIFF, FLAC) to mono Float32 at its native rate.
    public static func decodeMono(_ url: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioDecoderError.cannotOpen(url, underlying: error)
        }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = Int(file.length)
        var mono = [Float]()
        mono.reserveCapacity(total)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioDecoderError.readFailed(url, underlying: CocoaError(.fileReadUnknown))
        }
        let scale = 1 / Float(channels)
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                // Some files have a damaged frame near the end; keep what decoded if it's most of the track.
                if mono.count > total / 2 { break }
                throw AudioDecoderError.readFailed(url, underlying: error)
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<channels { s += data[c][i] }
                    mono.append(s * scale)
                }
            }
        }

        var audio = DecodedAudio(samples: mono, sampleRate: Int(format.sampleRate), frameCount: mono.count, channelCount: channels)
        if file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEGLayer3 {
            audio.timelineOffsetFrames = mp3TimelineOffset(url)
        }
        return audio
    }

    /// Offset between Core Audio's MP3 decode and the Pioneer/Rekordbox timeline, in frames.
    ///
    /// Core Audio trims the encoder delay (from the LAME/Info header, 576 if absent) plus the
    /// 529-frame decoder delay; Rekordbox keeps both. Rekordbox also decodes a LAME-written
    /// Info/Xing header frame as 1152 frames of audio (but not one written by FFmpeg).
    /// Verified against Rekordbox 7 beat grids for tracks that start on a beat.
    static func mp3TimelineOffset(_ url: URL) -> Int {
        let decoderDelay = 529
        var encoderDelay = 576
        var fileID: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID {
            defer { AudioFileClose(fileID) }
            var info = AudioFilePacketTableInfo(mNumberValidFrames: 0, mPrimingFrames: 0, mRemainderFrames: 0)
            var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
            if AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo, &size, &info) == noErr, info.mPrimingFrames > 0 {
                encoderDelay = Int(info.mPrimingFrames)
            }
        }
        let headerFrame = mp3EncoderTag(url)?.hasPrefix("LAME") == true ? 1152 : 0
        return encoderDelay + decoderDelay + headerFrame
    }

    /// Encoder string from the Xing/Info header in the first MP3 frame (e.g. "LAME3.99r", "Lavc57.10").
    static func mp3EncoderTag(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 10), head.count == 10 else { return nil }
        var offset = 0
        if head.starts(with: Array("ID3".utf8)) {
            // Syncsafe size; plus 10-byte header (and 10-byte footer if flagged).
            let size = (Int(head[6]) << 21) | (Int(head[7]) << 14) | (Int(head[8]) << 7) | Int(head[9])
            offset = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
        }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.read(upToCount: 8192) else { return nil }
        let b = [UInt8](data)
        guard let sync = (0..<max(0, b.count - 4)).first(where: { b[$0] == 0xFF && b[$0 + 1] & 0xE0 == 0xE0 }) else { return nil }
        let frame = b[sync..<min(b.count, sync + 400)]
        let tag = frame.indices.first { i in
            i + 4 <= frame.endIndex && (Array(frame[i..<i + 4]) == Array("Xing".utf8) || Array(frame[i..<i + 4]) == Array("Info".utf8))
        }
        guard let tag, tag + 8 <= frame.endIndex else { return nil }
        let flags = UInt32(frame[tag + 4]) << 24 | UInt32(frame[tag + 5]) << 16 | UInt32(frame[tag + 6]) << 8 | UInt32(frame[tag + 7])
        var q = tag + 8
        if flags & 1 != 0 { q += 4 }
        if flags & 2 != 0 { q += 4 }
        if flags & 4 != 0 { q += 100 }
        if flags & 8 != 0 { q += 4 }
        guard q + 9 <= frame.endIndex else { return nil }
        return String(decoding: frame[q..<q + 9], as: UTF8.self)
    }
}
