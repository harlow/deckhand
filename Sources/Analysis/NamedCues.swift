import DeckhandCore
import Foundation

extension CueAnalyzer {
    /// A hot cue with a DJ-meaningful role, placed from the song structure.
    public struct NamedCue: Sendable, Equatable {
        /// Hot cue slot, 1 = A … 8 = H.
        public var slot: Int
        /// Shown on the deck as the cue comment, e.g. "Drop".
        public var name: String
        public var timeMs: Int
        /// Pad color (RGB).
        public var rgb: [UInt8]
        /// For evaluation: the section kind this cue is meant to mark, and how far ahead of it it sits.
        public var expectedKind: StructureAnalyzer.Kind?
        public var leadMs: Int

        public init(slot: Int, name: String, timeMs: Int, rgb: [UInt8], expectedKind: StructureAnalyzer.Kind? = nil, leadMs: Int = 0) {
            self.slot = slot
            self.name = name
            self.timeMs = timeMs
            self.rgb = rgb
            self.expectedKind = expectedKind
            self.leadMs = leadMs
        }
    }

    /// Pad roles. Each letter always means the same thing, so muscle memory carries across tracks;
    /// a slot stays empty when the track has no such moment. In a typical EDM arrangement the
    /// letters also run in time order.
    public enum Role: Int, CaseIterable, Sendable {
        /// A: first downbeat — where to start the track.
        case mixIn = 1
        /// B: first drop.
        case firstDrop
        /// C: first breakdown after the first drop.
        case breakdown
        /// D: `leadBars` (default 8, Rekordbox's most common build-up length) before the main drop.
        case build
        /// E: main drop — the first drop after the breakdown.
        case mainDrop
        /// F: a later breakdown.
        case lastBreak
        /// G: the final drop.
        case lastDrop
        /// H: where to mix out — outro start (Deckhand's outro tends to begin a phrase before Rekordbox's
        /// short 8-bar outro), else 32 bars before the end.
        case mixOut

        public var name: String {
            switch self {
            case .mixIn: "Mix In"
            case .firstDrop: "Drop 1"
            case .breakdown: "Break"
            case .build: "Build"
            case .mainDrop: "Main Drop"
            case .lastBreak: "Break 2"
            case .lastDrop: "Last Drop"
            case .mixOut: "Mix Out"
            }
        }

        public var rgb: [UInt8] {
            switch self {
            case .mixIn: [0x00, 0xE0, 0x5A]                  // green
            case .firstDrop: [0xFF, 0x8C, 0x00]              // orange
            case .breakdown, .lastBreak: [0x30, 0x5A, 0xFF]  // blue
            case .build: [0xFF, 0xD2, 0x00]                  // yellow
            case .mainDrop, .lastDrop: [0xE6, 0x28, 0x28]    // red
            case .mixOut: [0xA0, 0x40, 0xFF]                 // purple
            }
        }
    }

    /// Named hot cues from the song structure. Cues closer than `minGapBars` to an earlier slot's cue
    /// are dropped (the earlier role wins).
    public static func namedHotCues(sections: [StructureAnalyzer.Section], analysis: TrackAnalysis,
                                    leadBars: Int = 8, minGapBars: Int = 8) -> [NamedCue] {
        let beats = analysis.beats
        guard !sections.isEmpty, beats.count > 64 else { return [] }
        let beatMs = Double(beats.last!.timeMs - beats.first!.timeMs) / Double(beats.count - 1)
        let barMs = Int((4 * beatMs).rounded())
        func ms(beat i: Int) -> Int { beats[max(0, min(beats.count - 1, i))].timeMs }
        func starts(_ k: StructureAnalyzer.Kind) -> [StructureAnalyzer.Section] { sections.filter { $0.kind == k } }

        var picks: [(Role, Int, StructureAnalyzer.Kind?, Int)] = []   // role, time, expected kind, lead
        let firstDownbeat = beats.firstIndex { $0.barPosition == 1 } ?? 0
        picks.append((.mixIn, ms(beat: firstDownbeat), .intro, 0))

        let drops = starts(.drop), breaks = starts(.breakdown)
        let firstDrop = drops.first
        if let d = firstDrop { picks.append((.firstDrop, d.startMs, .drop, 0)) }

        let breakdown = breaks.first { $0.startMs > (firstDrop?.startMs ?? 0) } ?? breaks.first
        if let b = breakdown { picks.append((.breakdown, b.startMs, .breakdown, 0)) }

        // Main drop: the first drop after the breakdown; without a breakdown, the first drop.
        let main = breakdown.flatMap { b in drops.first { $0.startMs > b.startMs } } ?? (breakdown == nil ? firstDrop : nil)
        if let main {
            // A fixed lead before the drop: predictable on the pads, and it rides on the main-drop
            // estimate (the most reliable section start). Kept clear of the breakdown cue.
            let leadBeat = main.startBeat - 4 * leadBars
            if leadBeat > 0, ms(beat: leadBeat) >= (breakdown?.startMs ?? 0) + 4 * barMs {
                picks.append((.build, ms(beat: leadBeat), .drop, main.startMs - ms(beat: leadBeat)))
            }
            if main != firstDrop { picks.append((.mainDrop, main.startMs, .drop, 0)) }
        }

        if let lb = breaks.last, lb != breakdown, lb.startMs > (main?.startMs ?? .max) {
            picks.append((.lastBreak, lb.startMs, .breakdown, 0))
        }
        if let ld = drops.last, ld != main, ld != firstDrop, ld.startMs > (main?.startMs ?? firstDrop?.startMs ?? 0) {
            picks.append((.lastDrop, ld.startMs, .drop, 0))
        }

        if let outro = starts(.outro).first {
            picks.append((.mixOut, outro.startMs, .outro, 0))
        } else {
            let i = beats.count - 1 - 128
            if i > firstDownbeat {
                let aligned = firstDownbeat + ((i - firstDownbeat) / 16) * 16   // on a 4-bar phrase line
                picks.append((.mixOut, ms(beat: aligned), nil, 0))
            }
        }

        var out: [NamedCue] = []
        // Half a bar of slack absorbs tempo rounding; Build is defined relative to Main Drop, so that
        // pair never conflicts (otherwise an exact 8-bar lead could knock out the main drop).
        let minGap = minGapBars * barMs - barMs / 2
        for (role, t, kind, lead) in picks.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
            let conflict = out.contains { c in
                let pair: Set<Int> = [c.slot, role.rawValue]
                return abs(c.timeMs - t) < minGap && pair != [Role.build.rawValue, Role.mainDrop.rawValue]
            }
            if conflict { continue }
            out.append(NamedCue(slot: role.rawValue, name: role.name, timeMs: t, rgb: role.rgb, expectedKind: kind, leadMs: lead))
        }
        return out
    }
}
