/// Rekordbox-style phrase analysis ("song structure"), shown by players as colored phrase bars.
public struct PhraseAnalysis: Codable, Sendable, Equatable {
    /// 1 = high (EDM: Intro/Up/Down/Chorus/Outro), 2 = mid, 3 = low.
    public var mood: Int
    /// Beat number (1-based) where the last phrase ends.
    public var endBeat: Int
    /// Color bank 0–7 (0 = default).
    public var bank: Int
    /// Two header bytes of unknown meaning; Rekordbox writes every 0/1 combination, most often 1, 1.
    public var flags: [UInt8]
    public var phrases: [Phrase]

    public init(mood: Int, endBeat: Int, bank: Int = 0, flags: [UInt8] = [1, 1], phrases: [Phrase]) {
        self.mood = mood
        self.endBeat = endBeat
        self.bank = bank
        self.flags = flags
        self.phrases = phrases
    }

    public struct Phrase: Codable, Sendable, Equatable {
        /// Beat number (1-based) where the phrase starts.
        public var beat: Int
        /// Mood-specific kind; for high mood 1 Intro, 2 Up, 3 Down, 5 Chorus, 6 Outro.
        public var kind: Int
        /// High-mood variant flags (select e.g. Intro 1/2, Up 1/2/3, Chorus 1/2).
        public var k1 = 0, k2 = 0, k3 = 0
        public var b = 0
        public var beat2 = 0, beat3 = 0, beat4 = 0
        /// Fill-in flag and the beat where the fill starts.
        public var fill = 0
        public var beatFill = 0

        public init(beat: Int, kind: Int, k1: Int = 0, k2: Int = 0, k3: Int = 0, b: Int = 0,
                    beat2: Int = 0, beat3: Int = 0, beat4: Int = 0, fill: Int = 0, beatFill: Int = 0) {
            self.beat = beat
            self.kind = kind
            self.k1 = k1
            self.k2 = k2
            self.k3 = k3
            self.b = b
            self.beat2 = beat2
            self.beat3 = beat3
            self.beat4 = beat4
            self.fill = fill
            self.beatFill = beatFill
        }
    }
}
