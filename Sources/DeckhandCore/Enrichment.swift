/// A cue point on the player's timeline.
public struct CuePoint: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case memory
        /// Hot cue slot, 1 = A … 8 = H.
        case hot(Int)
    }

    public var kind: Kind
    public var timeMs: Int
    public var comment: String?
    /// Pad color for hot cues (RGB); nil uses the player's default.
    public var rgb: [UInt8]?

    public init(kind: Kind, timeMs: Int, comment: String? = nil, rgb: [UInt8]? = nil) {
        self.kind = kind
        self.timeMs = timeMs
        self.comment = comment
        self.rgb = rgb
    }

    public var color: (UInt8, UInt8, UInt8)? {
        guard let rgb, rgb.count == 3 else { return nil }
        return (rgb[0], rgb[1], rgb[2])
    }
}

/// Curated / imported DJ metadata that isn't derived from Deckhand's own audio analysis.
public struct TrackEnrichment: Codable, Sendable, Equatable {
    public var cues: [CuePoint]
    /// Energy level 1–10 (Mixed In Key scale).
    public var energy: Int?

    public init(cues: [CuePoint] = [], energy: Int? = nil) {
        self.cues = cues
        self.energy = energy
    }
}
