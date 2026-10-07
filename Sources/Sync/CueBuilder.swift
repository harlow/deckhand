import DeckhandCore
import Foundation
import MusicSource

/// Which cue types to write to the device.
public enum CueMode: String, Sendable, CaseIterable {
    case memory, hot, both, none
}

/// Turns imported cue positions into device cues.
enum CueBuilder {
    /// Players have eight hot cue pads (A–H).
    static let hotCueSlots = 8
    /// Imported cues within this distance of a beat snap onto it.
    static let snapToleranceMs = 150

    static func cues(from mik: MixedInKeyLibrary.Track?, analysis: TrackAnalysis?, mode: CueMode) -> [CuePoint] {
        guard mode != .none, let mik, !mik.cues.isEmpty else { return [] }
        let beats = analysis?.beats.map(\.timeMs) ?? []

        var positions: [(timeMs: Int, energy: Int)] = []
        for cue in mik.cues {
            let raw = Int((cue.time * 1000).rounded())
            let t = snap(raw, to: beats)
            if positions.last?.timeMs != t { positions.append((t, cue.energy)) }
        }

        var out: [CuePoint] = []
        if mode == .memory || mode == .both {
            out += positions.map { CuePoint(kind: .memory, timeMs: $0.timeMs, comment: "Energy \($0.energy)") }
        }
        if mode == .hot || mode == .both {
            out += positions.prefix(hotCueSlots).enumerated().map {
                CuePoint(kind: .hot($0.offset + 1), timeMs: $0.element.timeMs, comment: "Energy \($0.element.energy)")
            }
        }
        return out
    }

    /// Nearest beat within tolerance, else the original time. `beats` is sorted.
    static func snap(_ t: Int, to beats: [Int]) -> Int {
        guard !beats.isEmpty else { return t }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [beats[lo], beats[max(0, lo - 1)]]
        let nearest = candidates.min { abs($0 - t) < abs($1 - t) }!
        return abs(nearest - t) <= snapToleranceMs ? nearest : t
    }

    /// Changes whenever the cues written for a track would change.
    static func fingerprint(_ cues: [CuePoint]) -> String {
        cues.map { c -> String in
            let kind = if case .hot(let n) = c.kind { "h\(n)" } else { "m" }
            return "\(kind)@\(c.timeMs):\(c.comment ?? "")"
        }.joined(separator: ",")
    }
}
