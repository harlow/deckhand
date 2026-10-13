import DeckhandCore
import Accelerate
import Foundation

/// Small, gain-independent descriptors of cached audio envelopes. These describe band balance,
/// beat-relative accents and the energy contour; they do not identify mood, instruments or vocals.
public struct AudioMatchProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var texture: [Double]
    public var groove: [Double]?
    public var energyShape: [Double]

    public init?(analysis: TrackAnalysis) {
        let w = analysis.waveforms
        let n = min(w.low.count, w.mid.count, w.high.count)
        guard n >= 300, analysis.durationSeconds.isFinite, analysis.durationSeconds > 0 else { return nil }
        let bands = [w.low, w.mid, w.high]
        // Describe the body, using vector reductions over every frame to avoid rhythmic aliasing
        // from sparse sampling (a regular stride can repeatedly miss a kick or hi-hat).
        let lo = n / 10, hi = n - n / 10
        var power = [Double](repeating: 0, count: 3)
        for b in 0..<3 {
            var sum: Float = 0, minimum: Float = 0, maximum: Float = 0
            bands[b].withUnsafeBufferPointer { values in
                let start = values.baseAddress! + lo
                vDSP_svesq(start, 1, &sum, vDSP_Length(hi - lo))
                vDSP_minv(start, 1, &minimum, vDSP_Length(hi - lo))
                vDSP_maxv(start, 1, &maximum, vDSP_Length(hi - lo))
            }
            guard sum.isFinite, minimum >= 0, maximum <= 1 else { return nil }
            power[b] = Double(sum)
        }
        let total = power.reduce(0, +)
        guard total.isFinite, total > 1e-10 else { return nil }
        version = Self.currentVersion
        texture = power.map { $0 / total }

        var shape = [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            let a = i * n / 8, z = (i + 1) * n / 8
            let hop = max(1, (z - a) / 128)
            var count = 0
            for f in stride(from: a, to: z, by: hop) {
                let value = bands.reduce(0) { $0 + Double($1[f]) }
                guard value.isFinite, value >= 0 else { return nil }
                shape[i] += value; count += 1
            }
            shape[i] /= Double(max(1, count))
        }
        let maximum = shape.max() ?? 0
        energyShape = maximum > 0 ? shape.map { $0 / maximum } : []

        // Average eight subdivisions of each beat at their position in the four-beat bar.
        // Compare accents at relative beat positions, rather than comparing absolute BPM.
        let beats = analysis.beats
        let fps = Double(TrackAnalysis.Waveforms.framesPerSecond)
        var sums = [Double](repeating: 0, count: 96), counts = [Int](repeating: 0, count: 32)
        var valid = 0
        let barStep = max(1, beats.count / 256)
        if beats.count >= 17 {
            for i in 0..<(beats.count - 1) where (i / 4) % barStep == 0 {
                let beat = beats[i], next = beats[i + 1]
                guard (1...4).contains(beat.barPosition), beat.timeMs >= 0 else { continue }
                let a = Double(beat.timeMs) / 1000 * fps, z = Double(next.timeMs) / 1000 * fps
                guard z > a + 8, a >= Double(lo), z <= Double(hi) else { continue }
                valid += 1
                for p in 0..<8 {
                    let f = min(n - 1, Int(a + (Double(p) + 0.5) / 8 * (z - a)))
                    let bin = (beat.barPosition - 1) * 8 + p
                    counts[bin] += 1
                    for b in 0..<3 { sums[b * 32 + bin] += Double(bands[b][f]) }
                }
            }
        }
        if valid >= 16, counts.allSatisfy({ $0 > 0 }) {
            var accents: [Double] = []
            for b in 0..<3 {
                let values = (0..<32).map { sums[b * 32 + $0] / Double(counts[$0]) }
                let mean = values.reduce(0, +) / 32
                let centered = values.map { $0 - mean }
                let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
                // A flat envelope contains no rhythmic evidence.
                accents += norm / (32.0).squareRoot() > max(1e-6, mean * 0.05) ? centered.map { $0 / norm } : Array(repeating: 0, count: 32)
            }
            groove = accents.contains(where: { $0 != 0 }) ? accents : nil
        } else { groove = nil }
    }

    public func textureSimilarity(to other: Self) -> Double? {
        guard valid(other), texture.count == 3, other.texture.count == 3,
              (texture + other.texture).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(texture.reduce(0, +) - 1) < 0.01, abs(other.texture.reduce(0, +) - 1) < 0.01 else { return nil }
        return max(0, 1 - zip(texture, other.texture).reduce(0) { $0 + abs($1.0 - $1.1) } / 2)
    }

    public func grooveSimilarity(to other: Self) -> Double? {
        guard valid(other), let a = groove, let b = other.groove, a.count == 96, b.count == 96,
              (a + b).allSatisfy(\.isFinite) else { return nil }
        guard texture.count == 3, other.texture.count == 3,
              (texture + other.texture).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        var best: Double?
        // A one-beat downbeat error shouldn't make an otherwise identical groove unrelated.
        for shift in 0..<4 {
            var score = 0.0, weight = 0.0
            for band in 0..<3 {
                var dot = 0.0, aa = 0.0, bb = 0.0
                for i in 0..<32 {
                    let x = a[band * 32 + i], y = b[band * 32 + (i + shift * 8) % 32]
                    dot += x * y; aa += x * x; bb += y * y
                }
                guard aa > 1e-8, bb > 1e-8 else { continue }
                let w = (texture[band] * other.texture[band]).squareRoot()
                score += w * dot / (aa * bb).squareRoot(); weight += w
            }
            if weight > 1e-8 { best = max(best ?? 0, max(0, min(1, score / weight))) }
        }
        return best
    }

    public func energySimilarity(to other: Self) -> Double? {
        guard valid(other), energyShape.count == 8, other.energyShape.count == 8,
              (energyShape + other.energyShape).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              energyShape.contains(where: { $0 > 0 }), other.energyShape.contains(where: { $0 > 0 }) else { return nil }
        return max(0, 1 - zip(energyShape, other.energyShape).reduce(0) { $0 + abs($1.0 - $1.1) } / 8)
    }

    private func valid(_ other: Self) -> Bool { version == Self.currentVersion && other.version == Self.currentVersion }
}
