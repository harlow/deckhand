/// Format-independent analysis output for one audio file.
/// Exporters translate this into device-specific files (e.g. Pioneer ANLZ).
/// Where an analysis value came from.
public enum ValueSource: String, Codable, Sendable {
    case analysis
    case fileTag
    /// Measured from audio, with a file tag choosing the tempo octave and search range.
    case analysisWithTagHint
}

public struct TrackAnalysis: Codable, Sendable, Equatable {
    /// Bump when any analysis algorithm changes output, to invalidate cached results.
    public static let currentVersion = 5

    public var version: Int
    public var durationSeconds: Double
    public var sampleRate: Int
    /// Average BPM (e.g. 124.37).
    public var bpm: Double
    public var beats: [Beat]
    public var key: MusicalKey?
    public var waveforms: Waveforms
    public var bpmSource: ValueSource
    public var keySource: ValueSource

    public init(version: Int = TrackAnalysis.currentVersion, durationSeconds: Double, sampleRate: Int,
                bpm: Double, beats: [Beat], key: MusicalKey?, waveforms: Waveforms,
                bpmSource: ValueSource = .analysis, keySource: ValueSource = .analysis) {
        self.version = version
        self.bpmSource = bpmSource
        self.keySource = keySource
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.bpm = bpm
        self.beats = beats
        self.key = key
        self.waveforms = waveforms
    }

    public struct Beat: Codable, Sendable, Equatable {
        /// Position within the bar, 1–4.
        public var barPosition: Int
        /// Time of the beat in milliseconds from the start of the audio.
        public var timeMs: Int
        /// Local tempo at this beat, BPM.
        public var bpm: Double

        public init(barPosition: Int, timeMs: Int, bpm: Double) {
            self.barPosition = barPosition
            self.timeMs = timeMs
            self.bpm = bpm
        }
    }

    /// Waveform envelopes at 150 frames/second (the Pioneer "half-frame" rate).
    public struct Waveforms: Codable, Sendable, Equatable {
        public static let framesPerSecond = 150

        /// Per-frame peak amplitude, 0...1, full band.
        public var peak: [Float]
        /// Per-frame RMS amplitude, 0...1, full band.
        public var rms: [Float]
        /// Per-frame band energy, 0...1.
        public var low: [Float]
        public var mid: [Float]
        public var high: [Float]

        public init(peak: [Float], rms: [Float], low: [Float], mid: [Float], high: [Float]) {
            self.peak = peak
            self.rms = rms
            self.low = low
            self.mid = mid
            self.high = high
        }

        public var frameCount: Int { peak.count }
    }
}
