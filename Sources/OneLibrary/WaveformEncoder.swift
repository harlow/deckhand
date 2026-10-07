import DeckhandCore
import Foundation

/// Encodes generic 150 fps envelopes into the Pioneer waveform byte formats.
struct WaveformEncoder {
    let wf: TrackAnalysis.Waveforms

    init(_ wf: TrackAnalysis.Waveforms) { self.wf = wf }

    /// Downsamples a per-frame series into `count` buckets by taking the max of each bucket.
    static func bucketMax(_ x: [Float], count: Int) -> [Float] {
        guard !x.isEmpty, count > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        return (0..<count).map { i in
            let a = i * x.count / count
            let b = max(a + 1, (i + 1) * x.count / count)
            return x[a..<min(b, x.count)].max() ?? 0
        }
    }

    /// Downsamples by averaging each bucket.
    static func bucketMean(_ x: [Float], count: Int) -> [Float] {
        guard !x.isEmpty, count > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        return (0..<count).map { i in
            let a = i * x.count / count
            let b = min(x.count, max(a + 1, (i + 1) * x.count / count))
            return x[a..<b].reduce(0, +) / Float(b - a)
        }
    }

    static func quantize(_ v: Float, max m: Int) -> Int {
        Swift.max(0, Swift.min(m, Int((v * Float(m)).rounded())))
    }

    /// Display height 0–31. Fitted against Rekordbox output, which tracks sqrt(RMS).
    static func height(rms: Float) -> Int {
        Swift.max(0, Swift.min(31, Int((30 * rms.squareRoot() - 3).rounded())))
    }

    /// 3-band amplitude 0–127, fitted against Rekordbox PWV7 values.
    static func band(_ v: Float, gain: Float) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(127, Int((gain * v.squareRoot()).rounded()))))
    }

    /// "Whiteness" 0–7 from the share of high-frequency energy.
    private func whiteness(low: Float, mid: Float, high: Float) -> Int {
        let total = low + mid + high
        guard total > 0 else { return 0 }
        return Self.quantize((mid + high * 2) / (total * 2), max: 7)
    }

    // MARK: Monochrome

    /// PWAV: 400 entries, height (5 bits) | whiteness (3 bits).
    func monoPreview(count: Int) -> [UInt8] {
        let rm = Self.bucketMax(wf.rms, count: count)
        let lo = Self.bucketMax(wf.low, count: count)
        let md = Self.bucketMax(wf.mid, count: count)
        let hi = Self.bucketMax(wf.high, count: count)
        return (0..<count).map { i in
            UInt8(whiteness(low: lo[i], mid: md[i], high: hi[i]) << 5 | Self.height(rms: rm[i]))
        }
    }

    /// PWV2: 100 entries, height 0–15.
    func tinyPreview(count: Int) -> [UInt8] {
        Self.bucketMax(wf.rms, count: count).map { UInt8(Self.height(rms: $0) / 2) }
    }

    /// PWV3: one entry per frame, height (5 bits) | whiteness (3 bits).
    func monoDetail() -> [UInt8] {
        (0..<wf.frameCount).map { i in
            UInt8(whiteness(low: wf.low[i], mid: wf.mid[i], high: wf.high[i]) << 5 | Self.height(rms: wf.rms[i]))
        }
    }

    // MARK: Color

    /// PWV5: one u16 per frame: red(3) green(3) blue(3) height(5) unused(2).
    func colorDetail() -> [UInt16] {
        (0..<wf.frameCount).map { i in
            let (r, g, b) = rgb(low: wf.low[i], mid: wf.mid[i], high: wf.high[i])
            let h = Self.height(rms: wf.rms[i])
            return UInt16(r << 13 | g << 10 | b << 7 | h << 2)
        }
    }

    private func rgb(low: Float, mid: Float, high: Float) -> (Int, Int, Int) {
        let m = max(low, mid, high)
        guard m > 0 else { return (0, 0, 0) }
        return (Self.quantize(low / m, max: 7), Self.quantize(mid / m, max: 7), Self.quantize(high / m, max: 7))
    }

    /// PWV4: 6 bytes per entry. Layout partially understood; see docs/formats.md.
    func colorPreview(count: Int) -> [UInt8] {
        let pk = Self.bucketMax(wf.peak, count: count)
        let rm = Self.bucketMax(wf.rms, count: count)
        let lo = Self.bucketMax(wf.low, count: count)
        let md = Self.bucketMax(wf.mid, count: count)
        let hi = Self.bucketMax(wf.high, count: count)
        var out = [UInt8]()
        out.reserveCapacity(count * 6)
        for i in 0..<count {
            out.append(UInt8(Self.quantize(rm[i], max: 127)))
            out.append(UInt8(Self.quantize(pk[i], max: 255)))
            out.append(UInt8(Self.quantize(lo[i], max: 127)))
            out.append(UInt8(Self.quantize(md[i], max: 127)))
            out.append(UInt8(Self.quantize(hi[i], max: 127)))
            out.append(UInt8(Self.quantize(rm[i], max: 31)))
        }
        return out
    }

    // MARK: 3-band (OneLibrary)

    /// PWV7 (frames == nil) / PWV6 (frames == 1200): [low, mid, high] bytes per entry.
    func threeBand(frames: Int?) -> [UInt8] {
        let lo: [Float], md: [Float], hi: [Float]
        if let frames {
            // The overview is averaged; Rekordbox's PWV6 values run well below PWV7 peaks.
            lo = Self.bucketMean(wf.low, count: frames)
            md = Self.bucketMean(wf.mid, count: frames)
            hi = Self.bucketMean(wf.high, count: frames)
        } else {
            (lo, md, hi) = (wf.low, wf.mid, wf.high)
        }
        var out = [UInt8]()
        out.reserveCapacity(lo.count * 3)
        for i in 0..<lo.count {
            out.append(Self.band(lo[i], gain: 110))
            out.append(Self.band(md[i], gain: 80))
            out.append(Self.band(hi[i], gain: 45))
        }
        return out
    }

    /// PWVC: three u16 values. Rekordbox writes per-track values in the ~0x50–0x1F4 range;
    /// meaning unconfirmed (likely per-band display scale).
    func threeBandScale() -> (UInt16, UInt16, UInt16) {
        func scale(_ x: [Float]) -> UInt16 {
            let m = x.max() ?? 0
            return UInt16(Self.quantize(m, max: 255)) + 0x50
        }
        return (scale(wf.low), scale(wf.mid), scale(wf.high))
    }
}
