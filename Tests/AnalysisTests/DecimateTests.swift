import Foundation
import Testing
@testable import Analysis

@Suite struct DecimateTests {
    /// Any window of outputs must be bit-identical to the same samples of the whole decimated signal:
    /// S-KEY decimates only its clip windows, and cached analyses depend on the exact values.
    @Test func windowsMatchWholeSignal() {
        var rng = SystemRandomNumberGenerator()
        for factor in [2, 4] {
            let d = Decimator(factor: factor)
            for n in [factor + 1, 50, 133, 1_000, 44_117] {
                let x = (0..<n).map { _ in Float.random(in: -1...1, using: &rng) }
                let whole = x.withUnsafeBufferPointer { d.apply($0, outputs: 0..<d.outputCount(n)) }
                #expect(whole.count == (n - 1) / factor + 1)
                for _ in 0..<50 {
                    let a = Int.random(in: 0..<whole.count, using: &rng)
                    let b = Int.random(in: (a + 1)...whole.count, using: &rng)
                    let window = x.withUnsafeBufferPointer { d.apply($0, outputs: a..<b) }
                    #expect(window == Array(whole[a..<b]), "n \(n) factor \(factor) window \(a)..<\(b)")
                }
            }
        }
    }

    @Test func passesLowFrequencies() {
        let rate = 44_100
        let x = (0..<rate).map { Float(sin(2 * .pi * 440 * Double($0) / Double(rate))) }
        let audio = DecodedAudio(samples: x, sampleRate: rate, frameCount: rate, channelCount: 1)
        let y = audio.decimated(by: 4)
        #expect(y.sampleRate == rate / 4)
        let mid = y.samples[1_000..<10_000]
        #expect(abs(mid.map { abs($0) }.max()! - 1) < 0.01)
    }
}
