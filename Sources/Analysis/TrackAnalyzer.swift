import DeckhandCore
import Foundation

/// Optional inputs that steer or replace analysis. Sync always analyzes with `.none`; the eval tools use
/// hints to test the tempo search against reference BPMs, or to skip key detection when it isn't scored.
public struct AnalysisHints: Sendable, Equatable {
    public var bpm: Double?
    public var key: MusicalKey?

    public init(bpm: Double? = nil, key: MusicalKey? = nil) {
        self.bpm = bpm
        self.key = key
    }

    public static let none = AnalysisHints()
}

public enum TrackAnalyzer {
    public static func analyze(url: URL) throws -> TrackAnalysis {
        try analyze(url: url, hints: .none)
    }

    public static func analyze(url: URL, hints: AnalysisHints) throws -> TrackAnalysis {
        let audio = try AudioDecoder.decodeMono(url)
        return analyze(audio, hints: hints)
    }

    /// All times in the result are on the DJ player's timeline, which includes encoder delay
    /// frames that the decoder trims (about 25–51 ms for MP3; see `AudioDecoder.mp3TimelineOffset`).
    /// A hinted BPM steers the tempo search; a hinted key replaces key detection.
    public static func analyze(_ audio: DecodedAudio, hints: AnalysisHints = .none) -> TrackAnalysis {
        let waveforms = WaveformAnalyzer.analyze(audio)
        let reduced = reducedRate(audio)
        let grid = BeatAnalyzer.analyze(reduced, lowBand: waveforms.low, bpmHint: hints.bpm)?
            .shifted(by: audio.timelineOffsetSeconds)
        let key = hints.key ?? KeyAnalyzer.analyze(audio)
        let duration = audio.durationSeconds + audio.timelineOffsetSeconds
        return TrackAnalysis(
            durationSeconds: duration,
            sampleRate: audio.sampleRate,
            bpm: grid?.bpm ?? 0,
            beats: grid?.beats(duration: duration) ?? [],
            key: key,
            waveforms: padded(waveforms, seconds: audio.timelineOffsetSeconds)
        )
    }

    /// Beat and key analysis run at ~11 kHz: same accuracy on the evaluation set, several times faster.
    public static func reducedRate(_ audio: DecodedAudio) -> DecodedAudio {
        audio.decimated(by: max(1, audio.sampleRate / 11_025))
    }

    /// Prepends silent frames so waveforms line up with the player timeline.
    static func padded(_ w: TrackAnalysis.Waveforms, seconds: Double) -> TrackAnalysis.Waveforms {
        let n = Int((seconds * Double(TrackAnalysis.Waveforms.framesPerSecond)).rounded())
        guard n > 0 else { return w }
        let zeros = [Float](repeating: 0, count: n)
        return .init(peak: zeros + w.peak, rms: zeros + w.rms, low: zeros + w.low, mid: zeros + w.mid, high: zeros + w.high)
    }
}
