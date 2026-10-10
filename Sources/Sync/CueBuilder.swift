import Analysis
import DeckhandCore
import Foundation

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

/// Turns detected cue positions into device cues.
enum CueBuilder {
    /// Bump when the cues or phrases built from the same analysis change, so drives' analysis files are checked
    /// once (and rewritten where their cues or phrases differ).
    static let version = 1

    /// Players have eight hot cue pads (A–H).
    static let hotCueSlots = 8

    static func cues(detected: CueAnalyzer.Result?, analysis: TrackAnalysis?, mode: CueMode,
                     hotStyle: HotCueStyle = .phrase, sections: [StructureAnalyzer.Section]? = nil,
                     buildLeadBars: Int = 8) -> [CuePoint] {
        guard mode != .none else { return [] }
        let positions = (detected?.cues ?? []).map { (timeMs: $0.timeMs, energy: $0.energy) }

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

    public func color(energy: Int?) -> TrackColor? {
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
