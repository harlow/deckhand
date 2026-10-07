import DeckhandCore
import Foundation
import Testing
@testable import Analysis

@Suite struct KeyAnalyzerTests {
    /// Transposing the input by k semitones transposes the detected tonic by k. Exact for
    /// octave-periodic chroma (the model scores 12 rotations of a 72-band, 6-octave profile).
    @Test func rotationEquivariant() {
        var rng = SystemRandomNumberGenerator()
        let pitchClasses = (0..<12).map { _ in Double.random(in: 0...1, using: &rng) }
        let x = (0..<72).map { pitchClasses[$0 % 12] }
        let key = KeyAnalyzer.classify(x)
        for k in 1..<12 {
            let shifted = (0..<72).map { x[($0 - k + 72) % 72] }
            let moved = KeyAnalyzer.classify(shifted)
            #expect(moved == MusicalKey(tonic: key.tonic + k, mode: key.mode))
        }
    }

    @Test func silenceHasNoKey() {
        let audio = DecodedAudio(samples: [Float](repeating: 0, count: 44_100 * 5), sampleRate: 44_100, frameCount: 44_100 * 5, channelCount: 1)
        #expect(KeyAnalyzer.analyze(audio) == nil)
    }

    /// An A-minor triad (A, C, E) sustained for 20 s is detected as A minor or its relative C major.
    @Test func sineTriad() {
        let sr = 11_025
        let freqs = [220.0, 261.63, 329.63, 440.0, 523.25, 659.26]
        let n = sr * 20
        let samples = (0..<n).map { i in Float(freqs.reduce(0) { $0 + sin(2 * .pi * $1 * Double(i) / Double(sr)) } / 6) }
        let audio = DecodedAudio(samples: samples, sampleRate: sr, frameCount: n, channelCount: 1)
        let key = KeyAnalyzer.analyze(audio)
        #expect(key == MusicalKey(tonic: 9, mode: .minor) || key == MusicalKey(tonic: 0, mode: .major))
    }
}
