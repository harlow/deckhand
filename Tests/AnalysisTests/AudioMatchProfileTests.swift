import Analysis
import DeckhandCore
import Foundation
import Testing

/// Independent controlled envelopes: same rhythm at different tempos/gains, shifted accents,
/// changed instrumentation balance, and changed arrangement. No user's files are read.
enum MatchAudioFixture {
    static func analysis(bpm: Double = 120, gain: Double = 1, offset: Double = 0,
                         bright: Bool = false, breakdown: Bool = true, beatCount: Int = 128) -> TrackAnalysis {
        let seconds = Double(beatCount) * 60 / bpm
        let n = Int(seconds * 150)
        var low: [Float] = [], mid: [Float] = [], high: [Float] = [], rms: [Float] = []
        for f in 0..<n {
            let position = Double(f) / 150 * bpm / 60
            let phase = (position + offset).truncatingRemainder(dividingBy: 1)
            let beat = Int(position)
            let level = gain * (breakdown && (48..<64).contains(beat) ? 0.25 : 1)
            let kick = (phase < 0.15 ? 0.6 : 0.08) * (beat % 4 == 0 ? 1 : 0.8)
            let hat = (phase > 0.45 && phase < 0.65 ? 0.35 : 0.025)
            let clap = (beat % 4 == 1 || beat % 4 == 3) && phase < 0.2 ? 0.35 : 0.06
            low.append(Float(level * kick * (bright ? 0.2 : 1)))
            mid.append(Float(level * clap))
            high.append(Float(level * hat * (bright ? 2 : 0.4)))
            rms.append((low.last! + mid.last! + high.last!) / 3)
        }
        return TrackAnalysis(durationSeconds: seconds, sampleRate: 44100, bpm: bpm,
            beats: (0..<beatCount).map { .init(barPosition: $0 % 4 + 1, timeMs: Int(Double($0) * 60 / bpm * 1000), bpm: bpm) },
            key: MusicalKey(parsing: "8A"), waveforms: .init(peak: rms, rms: rms, low: low, mid: mid, high: high))
    }
}

@Suite struct AudioMatchProfileTests {
    @Test func matchesRhythmAcrossGainAndTempoButSeparatesShiftedAccentsAndBandBalance() throws {
        let seed = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis()))
        let same = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis(bpm: 126, gain: 0.4)))
        let shifted = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis(offset: 0.5)))
        let bright = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis(bright: true)))
        #expect(try #require(seed.grooveSimilarity(to: same)) > 0.9)
        #expect(try #require(seed.textureSimilarity(to: same)) > 0.98)
        #expect(try #require(seed.grooveSimilarity(to: shifted)) < 0.65)
        #expect(try #require(seed.textureSimilarity(to: bright)) < 0.65)
        let flat = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis(breakdown: false)))
        #expect(seed.energySimilarity(to: same)! > seed.energySimilarity(to: flat)!)
    }

    @Test func longTracksSampleEveryBeatPositionAndInvalidEvidenceIsIgnored() throws {
        let long = try #require(AudioMatchProfile(analysis: MatchAudioFixture.analysis(beatCount: 512)))
        #expect(long.groove?.count == 96)
        var rotated = MatchAudioFixture.analysis(beatCount: 512)
        rotated.beats = rotated.beats.map { beat in var beat = beat; beat.barPosition = beat.barPosition % 4 + 1; return beat }
        let shiftedGrid = try #require(AudioMatchProfile(analysis: rotated))
        #expect(try #require(long.grooveSimilarity(to: shiftedGrid)) > 0.99)
        var analysis = MatchAudioFixture.analysis()
        analysis.beats = []
        #expect(AudioMatchProfile(analysis: analysis)?.groove == nil)
        analysis.waveforms = .init(peak: [], rms: [], low: Array(repeating: 0, count: 300),
            mid: Array(repeating: 0, count: 300), high: Array(repeating: 0, count: 300))
        #expect(AudioMatchProfile(analysis: analysis) == nil)
        var corrupt = long
        corrupt.texture[0] = .nan; corrupt.groove?[0] = .infinity
        #expect(long.textureSimilarity(to: corrupt) == nil && long.grooveSimilarity(to: corrupt) == nil)
        corrupt = long; corrupt.version = 0
        #expect(long.textureSimilarity(to: corrupt) == nil)
        let decoded = try JSONDecoder().decode(AudioMatchProfile.self, from: JSONEncoder().encode(long))
        #expect(decoded == long)
    }
}
