import Analysis
import DeckhandCore
import Foundation
import MusicSource

/// Which cue types to write to the device.
public enum CueMode: String, Sendable, CaseIterable {
    case memory, hot, both, none
}

/// What the hot cue pads hold.
public enum HotCueStyle: String, Sendable, CaseIterable {
    /// Fixed roles from the song structure: A Mix In, B Drop 1, C Break, D Build, E Main Drop,
    /// F Break 2, G Last Drop, H Mix Out.
    case named
    /// The first eight phrase cues, in time order.
    case phrase
}

/// Where cue positions come from.
public enum CueSource: String, Sendable, CaseIterable {
    /// Mixed In Key's cues when it has the track, otherwise Deckhand's.
    case auto
    /// Always Deckhand's own detection.
    case deckhand
    /// Only Mixed In Key's cues; tracks it doesn't have get none.
    case mik
}

/// Turns imported cue positions into device cues.
enum CueBuilder {
    /// Players have eight hot cue pads (A–H).
    static let hotCueSlots = 8
    /// Imported cues within this distance of a beat snap onto it.
    static let snapToleranceMs = 150

    static func cues(mik: MixedInKeyLibrary.Track?, detected: CueAnalyzer.Result?, analysis: TrackAnalysis?,
                     source: CueSource, mode: CueMode, hotStyle: HotCueStyle = .phrase,
                     sections: [StructureAnalyzer.Section]? = nil, buildLeadBars: Int = 8) -> [CuePoint] {
        guard mode != .none else { return [] }
        let beats = analysis?.beats.map(\.timeMs) ?? []
        let useMIK = source == .mik || (source == .auto && !(mik?.cues.isEmpty ?? true))

        var positions: [(timeMs: Int, energy: Int)] = []
        if useMIK {
            // MIK times are on the decoded timeline; snapping onto our (player-timeline) beats absorbs the offset.
            for cue in mik?.cues ?? [] {
                let t = snap(Int((cue.time * 1000).rounded()), to: beats)
                if positions.last?.timeMs != t { positions.append((t, cue.energy)) }
            }
        } else {
            positions = (detected?.cues ?? []).map { ($0.timeMs, $0.energy) }
        }

        var out: [CuePoint] = []
        if mode == .memory || mode == .both {
            out += positions.map { CuePoint(kind: .memory, timeMs: $0.timeMs, comment: "Energy \($0.energy)") }
        }
        if (mode == .hot || mode == .both), hotStyle == .named, let analysis, let sections, !sections.isEmpty {
            out += CueAnalyzer.namedHotCues(sections: sections, analysis: analysis, leadBars: buildLeadBars).map {
                CuePoint(kind: .hot($0.slot), timeMs: $0.timeMs, comment: $0.name, rgb: $0.rgb)
            }
        } else if mode == .hot || mode == .both {
            out += positions.prefix(hotCueSlots).enumerated().map {
                CuePoint(kind: .hot($0.offset + 1), timeMs: $0.element.timeMs, comment: "Energy \($0.element.energy)",
                         rgb: color(energy: $0.element.energy))
            }
        }
        return out
    }

    /// Hot cue pad color by energy: green (≤5), orange (6), red (≥7).
    static func color(energy: Int) -> [UInt8] {
        switch energy {
        case ...5: [0x33, 0xFF, 0x00]
        case 6: [0xFF, 0x8C, 0x00]
        default: [0xE6, 0x28, 0x28]
        }
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
            return "\(kind)@\(c.timeMs):\(c.comment ?? ""):\(c.rgb ?? [])"
        }.joined(separator: ",")
    }
}

/// How track colors (the list-view color tag) are assigned.
public enum TrackColorRule: String, Sendable, CaseIterable {
    /// By detected energy: 1–3 Blue, 4–5 Green, 6 Yellow, 7 Orange, 8–10 Red.
    case energy
    case none

    func color(energy: Int?) -> TrackColor? {
        guard self == .energy, let energy else { return nil }
        switch energy {
        case ...3: return .blue
        case 4...5: return .green
        case 6: return .yellow
        case 7: return .orange
        default: return .red
        }
    }
}
