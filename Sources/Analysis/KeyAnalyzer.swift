import CKeyFinder
import DeckhandCore
import Foundation

/// Key detection: an ensemble of
///  * a linear model over libKeyFinder's 72-band chromagram (C1–B6), rotation-equivariant (one weight
///    vector per mode, applied to the chroma rotated to each tonic), trained on human-labelled EDM keys
///    plus Mixed In Key labels weighted by MIK confidence (KeyModelWeights.swift, Scripts/train-key-model.py);
///  * S-KEY, a self-supervised CNN (SKey.swift) fine-tuned on human-labelled keys (Beatport EDM Key, FMAK)
///    plus confident Mixed In Key labels (Scripts/key-training), weighted by `skeyWeight` in
///    log-probability space.
public enum KeyAnalyzer {
    /// Weight of S-KEY's log-probabilities relative to the linear model's, and a log-score bonus for minor
    /// keys; tuned on the key-training validation split (Beatport EDM Key, FMAK, held-out MIK labels).
    static let skeyWeight = 3.8
    static let minorBias = 0.4

    /// Pass full-rate audio (≥ 22.05 kHz) so S-KEY can run; lower rates fall back to the linear model.
    /// `reduced` is `TrackAnalyzer.reducedRate(audio)` if the caller already has it.
    public static func analyze(_ audio: DecodedAudio, reduced: DecodedAudio? = nil) -> MusicalKey? {
        candidates(audio, reduced: reduced).first?.key
    }

    /// Chroma analysis rate. The input is decimated to just above twice the top chroma band (B6, 1976 Hz).
    static let chromaRate = 5_000

    /// libKeyFinder chromagram, row-major `hops × 72` (C1…B6), or nil for silence/failure.
    public static func chromagram(_ audio: DecodedAudio) -> (values: [Double], hops: Int)? {
        let input = audio.decimated(by: max(1, audio.sampleRate / chromaRate))
        var buf: UnsafeMutablePointer<Double>?
        var hops: Int32 = 0
        let rc = input.samples.withUnsafeBufferPointer {
            kf_chromagram_prefiltered($0.baseAddress, Int32($0.count), Int32(input.sampleRate), &buf, &hops)
        }
        guard rc == 0, let buf else { return nil }
        defer { free(buf) }
        guard hops > 0 else { return nil }
        return (Array(UnsafeBufferPointer(start: buf, count: Int(hops) * 72)), Int(hops))
    }

    /// Mean of √magnitude over all chroma frames, L2-normalized and scaled. Nil for silence.
    static func chromaProfile(_ audio: DecodedAudio) -> [Double]? {
        guard let (values, hops) = chromagram(audio) else { return nil }
        var mean = [Double](repeating: 0, count: 72)
        for h in 0..<hops {
            for b in 0..<72 { mean[b] += values[h * 72 + b].squareRoot() }
        }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return mean.map { $0 / norm * KeyModelWeights.inputScale }
    }

    /// Scores for 24 keys, indexed tonic * 2 + (minor ? 1 : 0), tonic 0 = C.
    static func scores(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 24)
        var rotated = [Double](repeating: 0, count: 72)
        for k in 0..<12 {
            for i in 0..<72 { rotated[i] = x[(i + k) % 72] }
            for m in 0..<2 {
                out[k * 2 + m] = zip(KeyModelWeights.output[m], rotated).reduce(KeyModelWeights.outputBias[m]) { $0 + $1.0 * $1.1 }
            }
        }
        return out
    }

    /// Probability of each of the 24 keys, most likely first. Empty for silence/failure.
    public static func candidates(_ audio: DecodedAudio, reduced: DecodedAudio? = nil, useSKey: Bool = true) -> [(key: MusicalKey, probability: Double)] {
        guard let x = chromaProfile(reduced ?? TrackAnalyzer.reducedRate(audio)) else { return [] }
        var s = logSoftmax(scores(x))
        if useSKey, audio.sampleRate >= SKey.sampleRate, let p = SKey.probabilities(audio) {
            for i in 0..<24 { s[i] += skeyWeight * log(max(p[i], 1e-6)) }
            for i in stride(from: 1, to: 24, by: 2) { s[i] += minorBias }
        }
        let m = s.max()!
        let e = s.map { exp($0 - m) }
        let total = e.reduce(0, +)
        return e.indices.map { (MusicalKey(tonic: $0 / 2, mode: $0 % 2 == 1 ? .minor : .major), e[$0] / total) }
            .sorted { $0.probability > $1.probability }
    }

    /// Ensemble inputs, for offline evaluation and training: the linear model's log-probabilities,
    /// S-KEY's probabilities, and the log-CQT clips S-KEY saw (each 84 × 646, row-major). Same indexing
    /// as `candidates`.
    public static func components(_ audio: DecodedAudio) -> (linear: [Double], skey: [Double]?, clips: [[Float]])? {
        guard let x = chromaProfile(TrackAnalyzer.reducedRate(audio)) else { return nil }
        let clips = audio.sampleRate >= SKey.sampleRate ? SKey.clips(audio) ?? [] : []
        return (logSoftmax(scores(x)), clips.isEmpty ? nil : SKey.probabilities(clips: clips), clips)
    }

    static func logSoftmax(_ s: [Double]) -> [Double] {
        let m = s.max()!
        let lse = m + log(s.reduce(0) { $0 + exp($1 - m) })
        return s.map { $0 - lse }
    }

    static func classify(_ x: [Double]) -> MusicalKey {
        let s = scores(x)
        let best = s.indices.max { s[$0] < s[$1] }!
        return MusicalKey(tonic: best / 2, mode: best % 2 == 1 ? .minor : .major)
    }
}
