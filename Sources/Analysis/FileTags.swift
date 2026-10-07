import AudioToolbox
import DeckhandCore
import Foundation

/// Tag values that can steer or replace analysis.
public struct AnalysisHints: Sendable, Equatable {
    public var bpm: Double?
    public var key: MusicalKey?

    public init(bpm: Double? = nil, key: MusicalKey? = nil) {
        self.bpm = bpm
        self.key = key
    }

    public static let none = AnalysisHints()
}

/// DJ-relevant tags read from an audio file (ID3, MP4, AIFF).
public struct FileTags: Sendable, Equatable {
    public var bpm: Double?
    public var key: MusicalKey?
    /// Mixed In Key energy level (1–10), parsed from the comment.
    public var energy: Int?

    public init(bpm: Double? = nil, key: MusicalKey? = nil, energy: Int? = nil) {
        self.bpm = bpm
        self.key = key
        self.energy = energy
    }
}

public enum FileTagReader {
    public static func read(_ url: URL) -> FileTags {
        guard let info = infoDictionary(url) else { return FileTags() }
        let comment = info["comments"] as? String ?? ""
        var tags = FileTags()
        tags.bpm = (info["tempo"] as? String).flatMap(parseBPM) ?? (info["tempo"] as? NSNumber)?.doubleValue
        tags.key = (info["key signature"] as? String).flatMap(parseKey) ?? keyFromComment(comment)
        tags.energy = energyFromComment(comment)
        return tags
    }

    static func parseBPM(_ s: String) -> Double? {
        guard let v = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v >= 40, v <= 300 else { return nil }
        return v
    }

    static func parseKey(_ s: String) -> MusicalKey? {
        let t = s.trimmingCharacters(in: .whitespaces)
        // Camelot with a leading zero ("03A") and Open Key ("6m"/"6d") are both common.
        if let m = t.wholeMatch(of: /0?(\d{1,2})([ABab])/), let n = Int(m.1) {
            return MusicalKey(parsing: "\(n)\(m.2.uppercased())")
        }
        if let m = t.wholeMatch(of: /(\d{1,2})([mdMD])/), let n = Int(m.1), (1...12).contains(n) {
            // Open Key: 1d = C major (8B), 1m = A minor (8A).
            let camelot = (n + 6) % 12 + 1
            return MusicalKey(parsing: "\(camelot)\(m.2.lowercased() == "m" ? "A" : "B")")
        }
        return MusicalKey(parsing: t)
    }

    /// Mixed In Key writes e.g. "12A - Energy 6" or "8A" at the start of the comment.
    static func keyFromComment(_ comment: String) -> MusicalKey? {
        guard let m = comment.prefixMatch(of: /\s*(0?\d{1,2}[AB])\b/) else { return nil }
        return parseKey(String(m.1))
    }

    static func energyFromComment(_ comment: String) -> Int? {
        guard let m = comment.firstMatch(of: /[Ee]nergy\s+(\d{1,2})/) else { return nil }
        return Int(m.1)
    }

    private static func infoDictionary(_ url: URL) -> [String: Any]? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let d = dict?.takeRetainedValue() as? [String: Any] else { return nil }
        return d
    }
}
