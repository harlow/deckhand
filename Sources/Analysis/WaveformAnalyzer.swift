import DeckhandCore
import Foundation

/// Computes 150 frame/second amplitude envelopes, full band and split into low/mid/high.
public enum WaveformAnalyzer {
    /// Band split points in Hz.
    static let lowCutoff: Double = 200
    static let highCutoff: Double = 2_500

    public static func analyze(_ audio: DecodedAudio) -> TrackAnalysis.Waveforms {
        let fps = TrackAnalysis.Waveforms.framesPerSecond
        let hop = Double(audio.sampleRate) / Double(fps)
        let frameCount = Int((Double(audio.samples.count) / hop).rounded(.up))
        let sr = Double(audio.sampleRate)

        var lowpass = Biquad.lowpass(cutoff: lowCutoff, sampleRate: sr)
        var highpass = Biquad.highpass(cutoff: highCutoff, sampleRate: sr)

        var peak = [Float](repeating: 0, count: frameCount)
        var rms = [Float](repeating: 0, count: frameCount)
        var low = [Float](repeating: 0, count: frameCount)
        var mid = [Float](repeating: 0, count: frameCount)
        var high = [Float](repeating: 0, count: frameCount)

        audio.samples.withUnsafeBufferPointer { x in
            for f in 0..<frameCount {
                let start = Int((Double(f) * hop).rounded())
                let end = min(x.count, Int((Double(f + 1) * hop).rounded()))
                if start >= end { continue }
                var pk: Float = 0, sumSq: Float = 0, sumLo: Float = 0, sumMid: Float = 0, sumHi: Float = 0
                for i in start..<end {
                    let s = x[i]
                    let lo = lowpass.process(s)
                    let hi = highpass.process(s)
                    let md = s - lo - hi
                    pk = max(pk, abs(s))
                    sumSq += s * s
                    sumLo += lo * lo
                    sumMid += md * md
                    sumHi += hi * hi
                }
                let n = Float(end - start)
                peak[f] = min(1, pk)
                rms[f] = min(1, (sumSq / n).squareRoot())
                low[f] = min(1, (sumLo / n).squareRoot())
                mid[f] = min(1, (sumMid / n).squareRoot())
                high[f] = min(1, (sumHi / n).squareRoot())
            }
        }

        return .init(peak: peak, rms: rms, low: low, mid: mid, high: high)
    }
}

/// Direct-form I biquad (RBJ cookbook).
struct Biquad {
    var b0, b1, b2, a1, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    static func lowpass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }

    static func highpass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }
}
