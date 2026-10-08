import DeckhandCore
import Foundation
import Testing
@testable import Analysis

@Suite struct SKeyTests {
    func sine(_ hz: Double, seconds: Double, rate: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / Double(rate))) }
    }

    @Test func outputOrderMapsToDeckhandKeys() {
        let key = { (i: Int) -> MusicalKey in
            let c = SKey.deckhandIndex[i]
            return MusicalKey(tonic: c / 2, mode: c % 2 == 1 ? .minor : .major)
        }
        #expect(key(0) == MusicalKey(tonic: 9, mode: .major))    // A major
        #expect(key(3) == MusicalKey(tonic: 0, mode: .major))    // C major
        #expect(key(12) == MusicalKey(tonic: 11, mode: .minor))  // B minor
        #expect(key(22) == MusicalKey(tonic: 9, mode: .minor))   // A minor
        #expect(key(23) == MusicalKey(tonic: 10, mode: .minor))  // Bb minor
        #expect(Set(SKey.deckhandIndex).count == 24)
    }

    @Test func clipsSpreadAcrossTrack() {
        let n = 360 * SKey.sampleRate
        let starts = SKey.clipStarts(n)
        #expect(starts.count == SKey.maxClips)
        #expect(starts.first! >= n / 10)
        #expect(starts.last! + SKey.clipSamples <= n * 9 / 10 + 1)
        #expect(SKey.clipStarts(10 * SKey.sampleRate) == [0])
        #expect(SKey.clipStarts(40 * SKey.sampleRate).count == 2)
    }

    @Test func cqtPeaksAtTheRightBin() {
        // 440 Hz = 27.5 Hz · 2^4 → bin 48 of the 84 kept bins.
        let cqt = SKeyCQT.logCQT(sine(440, seconds: 15, rate: SKey.sampleRate))
        #expect(cqt.count == SKey.bins * SKey.frames)
        let mid = SKey.frames / 2
        let column = (0..<SKey.bins).map { cqt[$0 * SKey.frames + mid] }
        #expect(column.indices.max { column[$0] < column[$1] } == 48)
        // Values are dB/80 + 1 with an 80 dB floor below the loudest bin: range at most 1.
        #expect(cqt.max()! - cqt.min()! <= 1 + 1e-5)
    }

    @Test func resamplesNonIntegerRatios() {
        let audio = DecodedAudio(samples: sine(1000, seconds: 2, rate: 48_000), sampleRate: 48_000, frameCount: 96_000, channelCount: 1)
        let x = SKey.resampled(audio)!
        #expect(abs(x.count - 2 * SKey.sampleRate) < 600)
        // ~1000 Hz survives: count upward zero crossings in the middle second.
        let mid = Array(x[SKey.sampleRate / 2..<(SKey.sampleRate * 3 / 2)])
        let crossings = zip(mid, mid.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 1000) <= 2)
    }

    @Test func modelProducesADistribution() throws {
        try #require(SKey.Model.shared != nil, "SKeyChromaNet.mlmodelc missing from the Analysis bundle")
        // A minor triad (A3, C4, E4) for 20 s at 44.1 kHz.
        let rate = 44_100
        let a = sine(220, seconds: 20, rate: rate), c = sine(261.63, seconds: 20, rate: rate), e = sine(329.63, seconds: 20, rate: rate)
        let samples = (0..<a.count).map { (a[$0] + c[$0] + e[$0]) / 3 }
        let audio = DecodedAudio(samples: samples, sampleRate: rate, frameCount: samples.count, channelCount: 1)
        let p = try #require(SKey.probabilities(audio))
        #expect(p.count == 24)
        #expect(abs(p.reduce(0, +) - 1) < 1e-3)
    }
}
