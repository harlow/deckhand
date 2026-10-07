import Accelerate
import Foundation

extension DecodedAudio {
    /// Low-pass filters and keeps every `factor`-th sample. Beat and key analysis only need
    /// content below a few kHz, so they run on a decimated copy.
    public func decimated(by factor: Int) -> DecodedAudio {
        guard factor > 1, samples.count > factor else { return self }
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

        // Pad so output sample k is centered on input sample k * factor.
        let pad = [Float](repeating: 0, count: taps / 2)
        let input = pad + samples + pad
        let outCount = (samples.count - 1) / factor + 1
        var output = [Float](repeating: 0, count: outCount)
        vDSP_desamp(input, vDSP_Stride(factor), filter, &output, vDSP_Length(outCount), vDSP_Length(taps))

        var result = DecodedAudio(samples: output, sampleRate: sampleRate / factor, frameCount: outCount, channelCount: channelCount)
        result.timelineOffsetFrames = timelineOffsetFrames / factor
        return result
    }
}
