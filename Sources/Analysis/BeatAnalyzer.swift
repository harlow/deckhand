import CQMDSP
import DeckhandCore
import Foundation

public struct BeatGrid: Sendable, Equatable {
    public var bpm: Double
    /// Time of the first grid beat in seconds (>= 0).
    public var firstBeat: Double
    /// Bar position (1–4) of `firstBeat`.
    public var firstBarPosition: Int

    public var period: Double { 60 / bpm }

    /// The same grid with all beats moved later by `seconds`, re-anchored to the earliest beat >= 0.
    public func shifted(by seconds: Double) -> BeatGrid {
        guard bpm > 0 else { return self }
        var first = firstBeat + seconds
        var position = firstBarPosition
        while first >= period { first -= period; position = (position + 2) % 4 + 1 }
        while first < 0 { first += period; position = position % 4 + 1 }
        return BeatGrid(bpm: bpm, firstBeat: first, firstBarPosition: position)
    }

    /// Beats from `firstBeat` until `duration`.
    public func beats(duration: Double) -> [TrackAnalysis.Beat] {
        guard bpm > 0, duration > firstBeat else { return [] }
        let count = Int(((duration - firstBeat) / period).rounded(.down)) + 1
        return (0..<count).map { i in
            let t = firstBeat + Double(i) * period
            return .init(barPosition: (firstBarPosition - 1 + i) % 4 + 1, timeMs: Int((t * 1000).rounded()), bpm: bpm)
        }
    }
}

public enum BeatAnalyzer {
    public static let tempoRange = 87.5..<175.0
    /// Prefer an integer BPM whose comb score is at least this fraction of the best score.
    static let integerPreference = 0.97

    public struct OnsetFunction: Sendable {
        public var values: [Double]
        public var stepSeconds: Double
    }

    public static func onsetFunction(_ audio: DecodedAudio) -> OnsetFunction? {
        var out: UnsafeMutablePointer<Double>?
        var count: Int32 = 0
        var step = 0.0
        let status = audio.samples.withUnsafeBufferPointer {
            qm_onset_function($0.baseAddress, Int32($0.count), Int32(audio.sampleRate), &out, &count, &step)
        }
        defer { qm_free(out) }
        guard status == 0, let out, count > 0 else { return nil }
        return OnsetFunction(values: Array(UnsafeBufferPointer(start: out, count: Int(count))), stepSeconds: step)
    }

    /// Beat times (seconds) from qm-dsp's tempo tracker; tempo may vary.
    public static func trackBeats(_ onsets: OnsetFunction, sampleRate: Int) -> [Double] {
        var out: UnsafeMutablePointer<Double>?
        var count: Int32 = 0
        let status = onsets.values.withUnsafeBufferPointer {
            qm_beats_from_onsets($0.baseAddress, Int32($0.count), Int32(sampleRate), onsets.stepSeconds, &out, &count)
        }
        defer { qm_free(out) }
        guard status == 0, let out else { return [] }
        return Array(UnsafeBufferPointer(start: out, count: Int(count)))
    }

    /// Fits a constant-tempo grid. `lowBand` is a 150 fps low-frequency envelope used to pick downbeats.
    /// `bpmHint` (e.g. from a file tag, possibly half- or double-time) selects the tempo octave
    /// and limits the search to within `hintTolerance` of it.
    public static func analyze(_ audio: DecodedAudio, lowBand: [Float], bpmHint: Double? = nil) -> BeatGrid? {
        guard let onsets = onsetFunction(audio) else { return nil }
        guard var grid = fitGrid(beats: trackBeats(onsets, sampleRate: audio.sampleRate), onsets: onsets, lowBand: lowBand, bpmHint: bpmHint) else { return nil }
        if let kickPhase = kickPhase(audio, period: grid.period, anchor: grid.firstBeat) {
            grid.firstBeat = kickPhase
            if grid.firstBeat >= grid.period { grid.firstBeat -= grid.period }
            if grid.firstBeat < 0 { grid.firstBeat += grid.period }
            grid.firstBarPosition = downbeatPosition(firstBeat: grid.firstBeat, period: grid.period, lowBand: lowBand)
        }
        return grid
    }

    /// Phase (seconds, within one period) of the beat transient. The low band picks which
    /// half of the beat holds the kick; the full-band attack within that window sets the exact time.
    /// Returns nil when no clear periodic low-frequency attack exists.
    static func kickPhase(_ audio: DecodedAudio, period: Double, anchor: Double? = nil) -> Double? {
        let hop = max(1, audio.sampleRate / 1000)
        let stepSeconds = Double(hop) / Double(audio.sampleRate)
        var lowpass = Biquad.lowpass(cutoff: 120, sampleRate: Double(audio.sampleRate))
        var low = [Double](), full = [Double]()
        low.reserveCapacity(audio.samples.count / hop + 1)
        full.reserveCapacity(audio.samples.count / hop + 1)
        audio.samples.withUnsafeBufferPointer { x in
            var i = 0
            while i < x.count {
                let end = min(x.count, i + hop)
                var el: Float = 0, ef: Float = 0
                for j in i..<end {
                    let y = lowpass.process(x[j])
                    el += y * y
                    ef += x[j] * x[j]
                }
                low.append(Double(el))
                full.append(Double(ef))
                i = end
            }
        }
        guard low.count > 2000 else { return nil }

        let bpm = 60 / period
        let lowFold = foldedProfile(bpm: bpm, onsets: OnsetFunction(values: flux(low, radius: 6), stepSeconds: stepSeconds), binsPerFrame: 1, smoothingFrames: 2)
        guard var lowPeak = lowFold.indices.max(by: { lowFold[$0] < lowFold[$1] }) else { return nil }
        if let anchor {
            // Strongest low-band attack near the onset-comb beat or its offbeat.
            let m = lowFold.count
            let a = Int((anchor / stepSeconds).rounded())
            let reach = m / 8
            var best = a
            for center in [a, a + m / 2] {
                for o in -reach...reach where lowFold[((center + o) % m + m) % m] > lowFold[((best % m) + m) % m] { best = center + o }
            }
            lowPeak = ((best % m) + m) % m
        }
        let baseline = lowFold.sorted()[lowFold.count / 2]
        guard lowFold[lowPeak] > 1.5 * max(baseline, 1e-12) else { return nil }

        // Start of the full-band attack: walk back from its energy peak near the low-band attack
        // to where the rise begins.
        let energy = foldedProfile(bpm: bpm, onsets: OnsetFunction(values: smooth(full, radius: 1), stepSeconds: stepSeconds), binsPerFrame: 1, smoothingFrames: 0)
        let n = energy.count
        func at(_ i: Int) -> Double { energy[((i % n) + n) % n] }
        var peak = lowPeak
        for o in -transientSearchMs...30 where at(lowPeak + o) > at(peak) { peak = lowPeak + o }
        let floor = (peak - 80...peak).map(at).min() ?? 0
        let threshold = floor + attackStartFraction * (at(peak) - floor)
        var start = peak
        while start > peak - 80, at(start - 1) > threshold { start -= 1 }
        let best = ((start % n) + n) % n
        return Double(best) * stepSeconds
    }

    static let transientSearchMs = 40
    static let attackStartFraction = 0.1

    static func smooth(_ envelope: [Double], radius: Int) -> [Double] {
        let n = envelope.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + envelope[i] }
        return (0..<n).map { i in
            let lo = max(0, i - radius), hi = min(n, i + radius + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }

    /// Positive change of an envelope smoothed by a centered moving average of ±`radius` samples.
    static func flux(_ envelope: [Double], radius: Int) -> [Double] {
        let n = envelope.count
        let smoothed = smooth(envelope, radius: radius)
        var out = [Double](repeating: 0, count: n)
        for i in 1..<n { out[i] = max(0, smoothed[i] - smoothed[i - 1]) }
        return out
    }

    /// Mean onset value at each phase bin of one beat period, circularly smoothed.
    static func foldedProfile(bpm: Double, onsets: OnsetFunction, binsPerFrame: Double, smoothingFrames: Int) -> [Double] {
        let periodFrames = 60 / bpm / onsets.stepSeconds
        let binCount = Int((periodFrames * binsPerFrame).rounded(.up))
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Double](repeating: 0, count: binCount)
        onsets.values.withUnsafeBufferPointer { df in
            for i in 0..<df.count {
                let ph = Double(i).truncatingRemainder(dividingBy: periodFrames)
                let bin = min(binCount - 1, Int(ph * binsPerFrame))
                sums[bin] += df[i]
                counts[bin] += 1
            }
        }
        let means = zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
        let radius = Int(binsPerFrame) * smoothingFrames
        return (0..<binCount).map { b in
            var acc = 0.0, wsum = 0.0
            for o in -radius...radius {
                let w = Double(radius + 1 - abs(o))
                acc += w * means[((b + o) % binCount + binCount) % binCount]
                wsum += w
            }
            return acc / wsum
        }
    }

    static let hintTolerance = 0.02

    public static func fitGrid(beats: [Double], onsets: OnsetFunction? = nil, lowBand: [Float] = [], bpmHint: Double? = nil) -> BeatGrid? {
        guard beats.count >= 8 else { return nil }

        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }
        guard var period = median(intervals) else { return nil }

        // Robust least-squares fit of t = phase + period * k.
        var phase = beats[0]
        var inliers = beats
        for _ in 0..<4 {
            let ks = inliers.map { (($0 - phase) / period).rounded() }
            guard let fit = linearFit(x: ks, y: inliers) else { break }
            (phase, period) = (fit.intercept, fit.slope)
            let kept = beats.filter { t in
                let k = ((t - phase) / period).rounded()
                return abs(t - (phase + k * period)) < 0.08 * period
            }
            if kept.count < 8 { break }
            inliers = kept
        }

        var bpm = 60 / period
        var octave = 1.0
        while bpm < tempoRange.lowerBound { bpm *= 2; octave *= 2 }
        while bpm >= tempoRange.upperBound { bpm /= 2; octave /= 2 }

        var span = 1.5
        if let hint = bpmHint, hint > 0 {
            // The hint's octave closest to the detected tempo.
            let detected = 60 / period
            let target = [hint / 2, hint, hint * 2].min { abs(log($0 / detected)) < abs(log($1 / detected)) }!
            octave = pow(2, (log2(target / detected)).rounded())
            bpm = target
            span = target * hintTolerance
        }

        if let onsets, let refined = refine(bpm: bpm, onsets: onsets, span: span) {
            bpm = refined.bpm
            period = 60 / bpm
            phase = refined.phase
            if octave < 1 {
                phase = bestPhase(candidates: [phase, phase + period / 2], period: period, lowBand: lowBand)
            }
        } else {
            bpm = snap(bpm)
            period = 60 / bpm
            let base = 60 / (bpm / octave)
            phase = circularMeanPhase(inliers, period: min(base, period))
            if octave < 1 {
                phase = bestPhase(candidates: [phase, phase + base], period: period, lowBand: lowBand)
            }
        }

        var first = phase.truncatingRemainder(dividingBy: period)
        if first < 0 { first += period }

        let barPosition = downbeatPosition(firstBeat: first, period: period, lowBand: lowBand)
        return BeatGrid(bpm: bpm, firstBeat: first, firstBarPosition: barPosition)
    }

    /// Searches near `bpm` for the constant tempo and phase that best align with onsets across the whole track.
    static func refine(bpm estimate: Double, onsets: OnsetFunction, span: Double = 1.5) -> (bpm: Double, phase: Double)? {
        guard onsets.values.count > 100 else { return nil }
        var best = (bpm: 0.0, score: -Double.infinity, phase: 0.0)
        var scores = [Int: (score: Double, phase: Double)]()
        let lo = Int(((estimate - span) * 100).rounded()), hi = Int(((estimate + span) * 100).rounded())
        for centi in stride(from: lo, through: hi, by: 2) {
            let candidate = Double(centi) / 100
            let (score, phase) = comb(bpm: candidate, onsets: onsets)
            scores[centi] = (score, phase)
            if score > best.score { best = (candidate, score, phase) }
        }
        // Fine pass at 0.01 around the coarse best.
        let center = Int((best.bpm * 100).rounded())
        for centi in (center - 2)...(center + 2) where scores[centi] == nil {
            let candidate = Double(centi) / 100
            let (score, phase) = comb(bpm: candidate, onsets: onsets)
            scores[centi] = (score, phase)
            if score > best.score { best = (candidate, score, phase) }
        }

        let whole = best.bpm.rounded()
        if abs(whole - best.bpm) <= 0.6 {
            let (score, phase) = scores[Int(whole * 100)] ?? comb(bpm: whole, onsets: onsets)
            if score >= best.score * integerPreference { return (whole, phase) }
        }
        return (best.bpm, best.phase)
    }

    /// Folds the onset function at the beat period; returns the peak (smoothed) mean onset and its phase in seconds.
    static func comb(bpm: Double, onsets: OnsetFunction, binsPerFrame: Double = 4, smoothingFrames: Int = 1) -> (score: Double, phase: Double) {
        let profile = foldedProfile(bpm: bpm, onsets: onsets, binsPerFrame: binsPerFrame, smoothingFrames: smoothingFrames)
        let best = profile.indices.max { profile[$0] < profile[$1] } ?? 0
        return (profile[best], (Double(best) + 0.5) / binsPerFrame * onsets.stepSeconds)
    }

    /// Rounds to 2 decimals, preferring an integer BPM when within 0.05.
    static func snap(_ bpm: Double) -> Double {
        let whole = bpm.rounded()
        if abs(bpm - whole) <= 0.05 { return whole }
        return (bpm * 100).rounded() / 100
    }

    static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func linearFit(x: [Double], y: [Double]) -> (intercept: Double, slope: Double)? {
        let n = Double(x.count)
        guard n >= 2 else { return nil }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (a, b) in zip(x, y) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (my - slope * mx, slope)
    }

    static func circularMeanPhase(_ times: [Double], period: Double) -> Double {
        var s = 0.0, c = 0.0
        for t in times {
            let a = 2 * Double.pi * t / period
            s += sin(a); c += cos(a)
        }
        var phase = atan2(s, c) / (2 * Double.pi) * period
        if phase < 0 { phase += period }
        return phase
    }

    /// Mean low-band energy at grid positions `phase + k * period`.
    static func gridEnergy(phase: Double, period: Double, lowBand: [Float]) -> Double {
        guard !lowBand.isEmpty else { return 0 }
        let fps = Double(TrackAnalysis.Waveforms.framesPerSecond)
        var sum = 0.0, n = 0
        var t = phase.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        while true {
            let f = Int((t * fps).rounded())
            if f >= lowBand.count { break }
            // Small window to tolerate a frame or two of misalignment.
            let lo = max(0, f - 1), hi = min(lowBand.count - 1, f + 1)
            sum += Double(lowBand[lo...hi].max() ?? 0)
            n += 1
            t += period
        }
        return n > 0 ? sum / Double(n) : 0
    }

    static func bestPhase(candidates: [Double], period: Double, lowBand: [Float]) -> Double {
        candidates.max { gridEnergy(phase: $0, period: period, lowBand: lowBand) < gridEnergy(phase: $1, period: period, lowBand: lowBand) } ?? candidates[0]
    }

    /// Naive downbeat choice: the beat phase (of 4) with the strongest low-band energy.
    /// Returns the bar position of the first grid beat.
    static func downbeatPosition(firstBeat: Double, period: Double, lowBand: [Float]) -> Int {
        guard !lowBand.isEmpty else { return 1 }
        let energies = (0..<4).map { gridEnergy(phase: firstBeat + Double($0) * period, period: 4 * period, lowBand: lowBand) }
        let best = energies.indices.max { energies[$0] < energies[$1] } ?? 0
        // Beat `best` is a downbeat, so the first beat is at bar position (4 - best) % 4 + 1.
        return (4 - best) % 4 + 1
    }
}
