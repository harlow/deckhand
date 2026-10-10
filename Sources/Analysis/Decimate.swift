import Accelerate
import Foundation

extension DecodedAudio {
    /// Low-pass filters and keeps every `factor`-th sample. Beat and key analysis only need
    /// content below a few kHz, so they run on a decimated copy.
    public func decimated(by factor: Int) -> DecodedAudio {
        guard factor > 1, samples.count > factor else { return self }
        let decimator = Decimator(factor: factor)
        let outCount = decimator.outputCount(samples.count)
        let output = samples.withUnsafeBufferPointer { decimator.apply($0, outputs: 0..<outCount) }

        var result = DecodedAudio(samples: output, sampleRate: sampleRate / factor, frameCount: outCount, channelCount: channelCount)
        result.timelineOffsetFrames = timelineOffsetFrames / factor
        return result
    }
}

/// Windowed-sinc low-pass (Blackman, 16 taps per unit of `factor`) followed by keeping every
/// `factor`-th sample. Output sample k is centered on input sample k * factor; input beyond either
/// end of the signal reads as zero. Any range of outputs can be computed on its own, with the same
/// values as decimating the whole signal.
struct Decimator {
    let factor: Int
    let filter: [Float]

    init(factor: Int) {
        self.factor = factor
        let taps = 16 * factor + 1
        let cutoff = 0.45 / Double(factor) // fraction of the input sample rate
        let mid = Double(taps - 1) / 2
        var filter = (0..<taps).map { i -> Float in
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(taps - 1))
            return Float(sinc * window)
        }
        let gain = filter.reduce(0, +)
        filter = filter.map { $0 / gain }
        self.filter = filter
    }

    func outputCount(_ inputCount: Int) -> Int { (inputCount - 1) / factor + 1 }

    /// Output samples `outputs` of decimating `x`. Outputs whose filter span lies inside `x` read it
    /// in place; only the few at the signal's edges go through a small zero-padded copy.
    ///
    /// vDSP_desamp computes outputs in blocks of 8 and a call's last `count % 8` outputs by a different
    /// path, with different rounding. To match one call over the whole signal exactly, every call here
    /// starts on a multiple of 8 and is a whole number of blocks, except one ending at the last output.
    func apply(_ x: UnsafeBufferPointer<Float>, outputs: Range<Int>) -> [Float] {
        let taps = filter.count, half = taps / 2, n = x.count, total = outputCount(n)
        guard !outputs.isEmpty else { return [] }
        let block = 8
        func roundUp(_ k: Int) -> Int { min(total, (k + block - 1) / block * block) }
        let lo = outputs.lowerBound / block * block, hi = roundUp(outputs.upperBound)
        // Output k reads x[k * factor - half ..< k * factor - half + taps]; [insideLo, insideHi) stay inside x.
        let firstInside = (half + factor - 1) / factor
        let endInside = n - taps + half >= 0 ? (n - taps + half) / factor + 1 : 0
        let insideLo = min(max(lo, roundUp(firstInside)), hi)
        let insideHi = max(min(hi, endInside / block * block), insideLo)

        var output = [Float](repeating: 0, count: hi - lo)
        output.withUnsafeMutableBufferPointer { out in
            func dst(_ k: Int) -> UnsafeMutablePointer<Float> { out.baseAddress! + (k - lo) }
            if insideHi > insideLo {
                vDSP_desamp(x.baseAddress! + (insideLo * factor - half), vDSP_Stride(factor), filter,
                            dst(insideLo), vDSP_Length(insideHi - insideLo), vDSP_Length(taps))
            }
            for edge in [lo..<insideLo, insideHi..<hi] where !edge.isEmpty {
                let start = edge.lowerBound * factor - half
                var padded = [Float](repeating: 0, count: (edge.count - 1) * factor + taps)
                let from = max(start, 0), to = min(start + padded.count, n)
                if to > from {
                    padded.withUnsafeMutableBufferPointer {
                        ($0.baseAddress! + (from - start)).update(from: x.baseAddress! + from, count: to - from)
                    }
                }
                vDSP_desamp(padded, vDSP_Stride(factor), filter, dst(edge.lowerBound), vDSP_Length(edge.count), vDSP_Length(taps))
            }
        }
        if lo == outputs.lowerBound, hi == outputs.upperBound { return output }
        return Array(output[(outputs.lowerBound - lo)..<(outputs.upperBound - lo)])
    }
}
