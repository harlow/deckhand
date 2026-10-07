/// A canonical musical key. Display formats (classic, Camelot/alphanumeric) are derived.
public struct MusicalKey: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case major, minor }

    /// Pitch class of the tonic, 0 = C ... 11 = B.
    public let tonic: Int
    public let mode: Mode

    public init(tonic: Int, mode: Mode) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.mode = mode
    }

    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// Classic notation, e.g. "Am", "C", "F#m", "Bb", using conventional key-signature spelling.
    public var classic: String {
        switch mode {
        case .major: return Self.majorSpelling[tonic]
        case .minor: return Self.minorSpelling[tonic] + "m"
        }
    }

    private static let majorSpelling = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let minorSpelling = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]

    /// Long name, e.g. "A minor".
    public var longName: String {
        "\(Self.sharpNames[tonic]) \(mode.rawValue)"
    }

    /// Camelot wheel number (1–12). A = minor, B = major.
    public var camelotNumber: Int {
        // Circle of fifths position relative to C major = 8B / A minor = 8A.
        let relativeMajor = mode == .major ? tonic : (tonic + 3) % 12
        // Each step up a fifth (+7 semitones) is +1 on the wheel.
        var steps = 0
        var pc = 0
        while pc != relativeMajor {
            pc = (pc + 7) % 12
            steps += 1
        }
        return ((8 - 1 + steps) % 12) + 1
    }

    /// Alphanumeric (Camelot-style) notation, e.g. "8A".
    public var alphanumeric: String {
        "\(camelotNumber)\(mode == .minor ? "A" : "B")"
    }

    /// Parses classic notation such as "Am", "F#m", "Bb", "Dbm", or "8A".
    public init?(parsing text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let last = t.last, (last == "A" || last == "B"), let n = Int(t.dropLast()), (1...12).contains(n) {
            let mode: Mode = last == "A" ? .minor : .major
            // Invert camelotNumber: steps of fifths from C major.
            let steps = ((n - 8) % 12 + 12) % 12
            let relMajor = (steps * 7) % 12
            self.init(tonic: mode == .major ? relMajor : (relMajor + 9) % 12, mode: mode)
            return
        }
        var s = Substring(t.replacingOccurrences(of: " ", with: ""))
        var isMinor = false
        for (suffix, minor) in [("minor", true), ("major", false), ("min", true), ("maj", false), ("m", true)]
        where s.lowercased().hasSuffix(suffix) && s.count > suffix.count {
            s = s.dropLast(suffix.count)
            isMinor = minor
            break
        }
        guard let letter = s.first else { return nil }
        let base: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pc = base[Character(letter.uppercased())] else { return nil }
        for acc in s.dropFirst() {
            switch acc {
            case "#", "♯": pc += 1
            case "b", "♭": pc -= 1
            default: return nil
            }
        }
        self.init(tonic: pc, mode: isMinor ? .minor : .major)
    }
}

import Foundation
