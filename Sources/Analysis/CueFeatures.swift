import Accelerate
import DeckhandCore
import Foundation

/// Per-beat audio descriptors used by cue and energy analysis.
///
/// Columns: the waveform envelopes (low, mid, high, rms, peak, flux), then log power in
/// `bandEdges.count - 1` log-spaced bands, spectral flatness and onset density.
public struct BeatFeatures: Sendable {
    public static let envelopeNames = ["low", "mid", "high", "rms", "peak", "flux"]
    static let bandEdges: [Double] = [30, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 12000, 16000]
    public static var names: [String] {
        envelopeNames + (0..<(bandEdges.count - 1)).map { "band\($0)" } + ["flatness", "onsets"]
    }

    /// One row per beat interval [beat i, beat i+1).
    public var rows: [[Float]]

    public var count: Int { rows.count }

    /// `beatTimes` are seconds on the player timeline (the same timeline as `analysis.waveforms`);
    /// `timelineOffset` is how far the player timeline runs ahead of the decoded audio.
    public init(audio: DecodedAudio, waveforms w: TrackAnalysis.Waveforms, beatTimes: [Double], timelineOffset: Double) {
        guard beatTimes.count > 1, w.frameCount > 0 else { rows = []; return }
        let env = Self.envelopes(w, beatTimes: beatTimes)
        let spec = Spectrogram(audio)
        rows = (0..<(beatTimes.count - 1)).map { i in
            env[i] + spec.summary(from: beatTimes[i] - timelineOffset, to: beatTimes[i + 1] - timelineOffset)
        }
    }

    static func envelopes(_ w: TrackAnalysis.Waveforms, beatTimes: [Double]) -> [[Float]] {
        let fps = Double(TrackAnalysis.Waveforms.framesPerSecond)
        let n = w.frameCount
        return (0..<(beatTimes.count - 1)).map { i in
            let a = max(0, min(n - 1, Int((beatTimes[i] * fps).rounded())))
            let b = max(a + 1, min(n, Int((beatTimes[i + 1] * fps).rounded())))
            var lo: Float = 0, md: Float = 0, hi: Float = 0, rm: Float = 0, pk: Float = 0, flux: Float = 0
            for f in a..<b {
                lo += w.low[f]; md += w.mid[f]; hi += w.high[f]; rm += w.rms[f]
                pk = max(pk, w.peak[f])
                if f > 0 {
                    flux += max(0, w.low[f] - w.low[f - 1]) + max(0, w.mid[f] - w.mid[f - 1]) + max(0, w.high[f] - w.high[f - 1])
                }
            }
            let c = Float(b - a)
            return [lo / c, md / c, hi / c, rm / c, pk, flux / c]
        }
    }
}

/// Band-energy spectrogram (2048-point FFT, hop 1024) with per-frame flatness and onset strength.
struct Spectrogram {
    static let fftSize = 2048
    static let hop = 1024

    let frameRate: Double
    /// [frame][band] log10 power.
    let bands: [[Float]]
    let flatness: [Float]
    let onset: [Float]

    init(_ audio: DecodedAudio) {
        let n = Self.fftSize, half = n / 2
        let sr = Double(audio.sampleRate)
        frameRate = sr / Double(Self.hop)
        let x = audio.samples
        let frames = x.count >= n ? (x.count - n) / Self.hop + 1 : 0
        let edges = BeatFeatures.bandEdges.map { min(half, max(1, Int($0 / sr * Double(n)))) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let log2n = vDSP_Length(log2(Double(n)))
        guard frames > 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            bands = []; flatness = []; onset = []; return
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var bands: [[Float]] = [], flatness: [Float] = [], onset: [Float] = []
        bands.reserveCapacity(frames)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: edges.count - 1)
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                vDSP_vmul(xp.baseAddress! + f * Self.hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBytes {
                            vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                var row = [Float](repeating: 0, count: edges.count - 1)
                var flux: Float = 0
                for b in 0..<(edges.count - 1) {
                    var s: Float = 0
                    vDSP_sve(power.withUnsafeBufferPointer { $0.baseAddress! + edges[b] }, 1, &s, vDSP_Length(max(1, edges[b + 1] - edges[b])))
                    let v = log10(s / Float(max(1, edges[b + 1] - edges[b])) + 1e-10)
                    row[b] = v
                    flux += max(0, v - previous[b])
                }
                previous = row
                // Spectral flatness over 60 Hz–8 kHz: geometric / arithmetic mean of power.
                let lo = edges[1], hi = edges[8]
                var logSum: Float = 0, sum: Float = 0
                for k in lo..<hi { logSum += log(power[k] + 1e-12); sum += power[k] }
                let count = Float(hi - lo)
                flatness.append(exp(logSum / count) / (sum / count + 1e-12))
                bands.append(row)
                onset.append(flux)
            }
        }
        self.bands = bands
        self.flatness = flatness
        self.onset = onset
    }

    /// Mean band log-power, mean flatness and onset density over [t0, t1) seconds of decoded audio.
    func summary(from t0: Double, to t1: Double) -> [Float] {
        let width = (BeatFeatures.bandEdges.count - 1) + 2
        guard !bands.isEmpty else { return [Float](repeating: 0, count: width) }
        let a = max(0, min(bands.count - 1, Int((t0 * frameRate).rounded())))
        let b = max(a + 1, min(bands.count, Int((t1 * frameRate).rounded())))
        var out = [Float](repeating: 0, count: width)
        for f in a..<b {
            for k in 0..<bands[f].count { out[k] += bands[f][k] }
            out[width - 2] += flatness[f]
            out[width - 1] += onset[f]
        }
        let c = Float(b - a)
        return out.map { $0 / c }
    }
}
