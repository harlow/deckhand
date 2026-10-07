import DeckhandCore
import Foundation
import Testing
@testable import Analysis

@Suite struct BeatGridTests {
    /// Beat times at a constant tempo with deterministic jitter.
    func beats(bpm: Double, first: Double, count: Int, jitter: Double = 0.004) -> [Double] {
        (0..<count).map { i -> Double in
            let n = Double(i)
            let wobble: Double = jitter * sin(n * 1.7)
            return first + n * 60 / bpm + wobble
        }
    }

    @Test func fitsIntegerTempo() throws {
        let grid = try #require(BeatAnalyzer.fitGrid(beats: beats(bpm: 124, first: 0.31, count: 200)))
        #expect(grid.bpm == 124)
        #expect(abs(grid.firstBeat - 0.31) < 0.01)
    }

    @Test func keepsTwoDecimalTempo() throws {
        let grid = try #require(BeatAnalyzer.fitGrid(beats: beats(bpm: 122.55, first: 0.1, count: 300, jitter: 0.002)))
        #expect(abs(grid.bpm - 122.55) < 0.015)
    }

    @Test func correctsHalfTimeIntoRange() throws {
        let grid = try #require(BeatAnalyzer.fitGrid(beats: beats(bpm: 64, first: 0.2, count: 100)))
        #expect(grid.bpm == 128)
    }

    @Test func tagHintSelectsOctave() throws {
        // Tracker locked at 120; a half-time tag (60) keeps 120, a tag of 240 also maps to 120.
        let detected = beats(bpm: 120, first: 0.05, count: 200)
        #expect(BeatAnalyzer.fitGrid(beats: detected, bpmHint: 60)?.bpm == 120)
        #expect(BeatAnalyzer.fitGrid(beats: detected, bpmHint: 240)?.bpm == 120)
    }

    @Test func snapsNearIntegers() {
        #expect(BeatAnalyzer.snap(127.97) == 128)
        #expect(BeatAnalyzer.snap(127.93) == 127.93)
    }

    @Test func shiftedGridKeepsBarPositions() {
        let grid = BeatGrid(bpm: 120, firstBeat: 0.4, firstBarPosition: 1)
        let shifted = grid.shifted(by: 0.2)
        // 0.6 s wraps to 0.1 s, one beat earlier, which is bar position 4.
        #expect(abs(shifted.firstBeat - 0.1) < 1e-9)
        #expect(shifted.firstBarPosition == 4)
        let a = grid.beats(duration: 10).map(\.barPosition)
        #expect(Array(a.prefix(5)) == [1, 2, 3, 4, 1])
    }

    @Test func clickTrackEndToEnd() throws {
        // 30 s of 128 BPM kick-like clicks (decaying 60 Hz burst with a broadband click), first beat at 0.25 s.
        let sr = 11_025
        let bpm = 128.0
        var x = [Float](repeating: 0, count: sr * 30)
        var t = 0.25
        while t < 30 {
            let start = Int(t * Double(sr))
            for i in 0..<min(Int(0.12 * Double(sr)), x.count - start) {
                let s = Double(i) / Double(sr)
                let body = sin(2 * .pi * 60 * s) * exp(-s * 30)
                let click = i < 20 ? (i % 2 == 0 ? 0.6 : -0.6) : 0
                x[start + i] += Float(0.8 * body + click)
            }
            t += 60 / bpm
        }
        let audio = DecodedAudio(samples: x, sampleRate: sr, frameCount: x.count, channelCount: 1)
        let waveforms = WaveformAnalyzer.analyze(audio)
        let grid = try #require(BeatAnalyzer.analyze(audio, lowBand: waveforms.low))
        #expect(grid.bpm == 128)
        var phaseError = (grid.firstBeat - 0.25).truncatingRemainder(dividingBy: grid.period)
        if phaseError > grid.period / 2 { phaseError -= grid.period }
        #expect(abs(phaseError) < 0.005)
    }

    @Test func keyFinderIndexMapping() {
        #expect(KeyAnalyzer.key(fromKeyFinderIndex: 0) == MusicalKey(tonic: 9, mode: .major)) // A major
        #expect(KeyAnalyzer.key(fromKeyFinderIndex: 1) == MusicalKey(tonic: 9, mode: .minor)) // A minor
        #expect(KeyAnalyzer.key(fromKeyFinderIndex: 7) == MusicalKey(tonic: 0, mode: .minor)) // C minor
        #expect(KeyAnalyzer.key(fromKeyFinderIndex: 23) == MusicalKey(tonic: 8, mode: .minor)) // Ab minor
    }
}
