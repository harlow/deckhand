import Accelerate
import AVFoundation
import CoreML
import Foundation

/// S-KEY key classifier (Kong et al., "S-KEY: Self-supervised Learning of Major and Minor Keys from
/// Audio", ICASSP 2025; Deezer, MIT). Log-CQT front-end in Swift, ChromaNet in Core ML.
/// Assets: SKeyConstants.swift and Resources/SKeyChromaNet.mlmodelc, from Scripts/export-skey.py.
enum SKey {
    static let sampleRate = 22_050
    static let clipSeconds = 15
    static let clipSamples = clipSeconds * sampleRate
    static let bins = 84
    static let frames = 646
    static let maxClips = 6

    /// 24 key probabilities indexed tonic * 2 + (minor ? 1 : 0), averaged over up to `maxClips`
    /// 15 s clips. Nil if the model is unavailable or the audio is too short/silent.
    static func probabilities(_ audio: DecodedAudio) -> [Double]? {
        guard Model.shared != nil, let cqts = clips(audio) else { return nil }
        return probabilities(clips: cqts)
    }

    /// Mean ChromaNet output over `clips` (from `clips(_:)`), in Deckhand's key order.
    static func probabilities(clips cqts: [[Float]]) -> [Double]? {
        guard let model = Model.shared else { return nil }
        let outputs = model.predict(cqts)
        guard !outputs.isEmpty else { return nil }
        var sum = [Double](repeating: 0, count: 24)
        for p in outputs {
            for (i, v) in p.enumerated() { sum[deckhandIndex[i]] += v }
        }
        return sum.map { $0 / Double(outputs.count) }
    }

    /// Log-CQTs (`bins × frames`, row-major) of the clips ChromaNet sees; nil if too short or silent.
    static func clips(_ audio: DecodedAudio) -> [[Float]]? {
        guard let x = Resampled(audio), x.count >= sampleRate * 2 else { return nil }
        let peak = x.peak()
        guard peak > 0 else { return nil }
        var scale = 1 / peak
        return clipStarts(x.count).map { start -> [Float] in
            var clip = x.samples(start..<min(x.count, start + clipSamples))
            vDSP_vsmul(clip, 1, &scale, &clip, 1, vDSP_Length(clip.count))
            if clip.count < clipSamples { clip += [Float](repeating: 0, count: clipSamples - clip.count) }
            return SKeyCQT.logCQT(clip)
        }
    }

    /// The track at 22.05 kHz. Integer-ratio inputs (44.1, 88.2 kHz) are decimated lazily, only over the
    /// clip windows plus one pass for the peak, so the full-length resampled track is never held in memory.
    private struct Resampled {
        let source: DecodedAudio
        let full: [Float]?
        let decimator: Decimator?
        let count: Int

        init?(_ audio: DecodedAudio) {
            source = audio
            let factor = audio.sampleRate / SKey.sampleRate
            if audio.sampleRate != SKey.sampleRate, audio.sampleRate % SKey.sampleRate == 0, audio.samples.count > factor {
                let d = Decimator(factor: factor)
                (full, decimator, count) = (nil, d, d.outputCount(audio.samples.count))
            } else {
                guard let x = resampled(audio) else { return nil }
                (full, decimator, count) = (x, nil, x.count)
            }
        }

        func samples(_ range: Range<Int>) -> [Float] {
            if let full { return Array(full[range]) }
            return source.samples.withUnsafeBufferPointer { decimator!.apply($0, outputs: range) }
        }

        /// Largest magnitude over the whole track.
        func peak() -> Float {
            var peak: Float = 0
            if let full {
                vDSP_maxmgv(full, 1, &peak, vDSP_Length(full.count))
                return peak
            }
            let chunk = 1 << 16
            for start in stride(from: 0, to: count, by: chunk) {
                let x = samples(start..<min(count, start + chunk))
                var m: Float = 0
                vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
                peak = max(peak, m)
            }
            return peak
        }
    }

    /// Up to `maxClips` clip starts spread evenly between 10% and 90% of the track.
    static func clipStarts(_ n: Int) -> [Int] {
        guard n > clipSamples else { return [0] }
        let k = max(1, min(maxClips, n / clipSamples))
        let lo = Double(n) * 0.1, hi = max(lo, Double(n) * 0.9 - Double(clipSamples))
        if k == 1 { return [Int((lo + hi) / 2)] }
        return (0..<k).map { Int(lo + (hi - lo) * Double($0) / Double(k - 1)) }
    }

    /// S-KEY's output order (A major … G# major, B minor … Bb minor) → tonic * 2 + minor.
    static let deckhandIndex: [Int] = (0..<24).map { i in
        i < 12 ? ((9 + i) % 12) * 2 : ((11 + i - 12) % 12) * 2 + 1
    }

    static func resampled(_ audio: DecodedAudio) -> [Float]? {
        if audio.sampleRate == sampleRate { return audio.samples }
        if audio.sampleRate % sampleRate == 0 { return audio.decimated(by: audio.sampleRate / sampleRate).samples }
        guard !audio.samples.isEmpty,
              let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to) else { return nil }
        // The converter reads the samples and writes the result in place, through buffers that wrap
        // the arrays' storage rather than copies of the track.
        let capacity = Int(Double(audio.samples.count) * Double(sampleRate) / Double(audio.sampleRate)) + 1024
        var result = [Float](repeating: 0, count: capacity)
        let frames: Int? = audio.samples.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                withBuffer(UnsafeMutableRawPointer(mutating: src.baseAddress!), count: src.count, format: from) { input in
                    withBuffer(UnsafeMutableRawPointer(dst.baseAddress!), count: dst.count, format: to) { output in
                        guard let input, let output else { return nil }
                        output.frameLength = 0
                        let feed = OneShotInput(input)
                        var error: NSError?
                        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
                        return error == nil ? Int(output.frameLength) : nil
                    }
                }
            }
        }
        guard let frames else { return nil }
        result.removeLast(capacity - frames)
        return result
    }

    /// Runs `body` with a mono float buffer over `count` samples at `data`, without copying them.
    private static func withBuffer<T>(_ data: UnsafeMutableRawPointer, count: Int, format: AVAudioFormat,
                                      _ body: (AVAudioPCMBuffer?) -> T) -> T {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Float>.size), mData: data)
        return body(AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil))
    }

    /// Hands the converter the whole input once, then signals end of stream.
    private final class OneShotInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .endOfStream; return nil }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }

    /// Compiled ChromaNet; predictions are serialized because MLModel thread-safety isn't guaranteed.
    final class Model: @unchecked Sendable {
        static let shared: Model? = {
            guard let url = AnalysisResources.modelURL else { return nil }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
            return Model(model)
        }()

        private let model: MLModel
        private let lock = NSLock()

        init(_ model: MLModel) { self.model = model }

        /// One batched prediction for all clips.
        func predict(_ cqts: [[Float]]) -> [[Double]] {
            let inputs: [MLFeatureProvider] = cqts.compactMap { cqt in
                guard let a = try? MLMultiArray(shape: [1, 1, NSNumber(value: SKey.bins), NSNumber(value: SKey.frames)], dataType: .float32) else { return nil }
                cqt.withUnsafeBufferPointer { a.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
                return try? MLDictionaryFeatureProvider(dictionary: ["cqt": a])
            }
            guard let batch = lock.withLock({ try? model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions()) }) else { return [] }
            return (0..<batch.count).compactMap { i in
                guard let p = batch.features(at: i).featureValue(for: "probs")?.multiArrayValue, p.count == 24 else { return nil }
                return (0..<24).map { p[$0].doubleValue }
            }
        }
    }
}

/// S-KEY's log-magnitude CQT (nnAudio VQT, gamma 0): 99 bins from 27.5 Hz, 12 per octave, hop 512 at
/// 22.05 kHz, computed octave by octave on a signal halved with a 256-tap low-pass, in dB (power,
/// 80 dB range) mapped to `db / 80 + 1`. Returns the lowest 84 bins, row-major bins × frames.
enum SKeyCQT {
    static let octaves = 9
    static let taps = 128
    static let kernelsT: (real: [Float], imag: [Float]) = {
        // 12 × 128 → 128 × 12 for frames × taps · taps × bins.
        var r = [Float](repeating: 0, count: 12 * taps), i = r
        vDSP_mtrans(SKeyConstants.kernelsReal, 1, &r, 1, vDSP_Length(taps), 12)
        vDSP_mtrans(SKeyConstants.kernelsImag, 1, &i, 1, vDSP_Length(taps), 12)
        return (r, i)
    }()

    static func logCQT(_ clip: [Float]) -> [Float] {
        var hop = 512
        var current = clip
        var octaveFrames: [(re: [Float], im: [Float], frames: Int)] = []   // lowest octave first
        for o in 0..<octaves {
            if o > 0 {
                current = halve(current)
                hop /= 2
            }
            octaveFrames.insert(octave(current, hop: hop), at: 0)
        }
        let frames = octaveFrames.map(\.frames).min()!
        // Concatenate octaves (12 bins each, lowest first), keep the top 99 bins.
        let allBins = octaves * 12
        let drop = allBins - SKeyConstants.lengths.count
        var power = [Float](repeating: 0, count: SKeyConstants.lengths.count * frames)   // bins × frames
        for (o, oct) in octaveFrames.enumerated() {
            let re = resize(oct.re, frames: oct.frames, to: frames)
            let im = resize(oct.im, frames: oct.frames, to: frames)
            for b in 0..<12 {
                let bin = o * 12 + b - drop
                guard bin >= 0 else { continue }
                let norm = SKeyConstants.lengths[bin]   // (|z|·√len)² = |z|²·len
                for f in 0..<frames {
                    let x = re[f * 12 + b], y = im[f * 12 + b]
                    power[bin * frames + f] = (x * x + y * y) * norm
                }
            }
        }
        // AmplitudeToDB(stype "power", top_db 80) on magnitudes: 10·log10(max(|X|, 1e-10)).
        var db = power.map { 10 * log10(max($0.squareRoot(), 1e-10)) }
        let floor = (db.max() ?? 0) - 80
        db = db.map { max($0, floor) / 80 + 1 }
        return Array(db[0..<(SKey.bins * frames)])
    }

    /// conv1d(lowpass, stride 2, zero padding 127) — nnAudio's downsampling_by_2.
    static func halve(_ x: [Float]) -> [Float] {
        let pad = [Float](repeating: 0, count: 127)
        let padded = pad + x + pad
        let n = (padded.count - SKeyConstants.lowpass.count) / 2 + 1
        var out = [Float](repeating: 0, count: n)
        vDSP_desamp(padded, 2, SKeyConstants.lowpass, &out, vDSP_Length(n), vDSP_Length(SKeyConstants.lowpass.count))
        return out
    }

    /// Reflect-pad by 64, frame with `hop`, project onto the 12 complex kernels. Rows are frames.
    static func octave(_ x: [Float], hop: Int) -> (re: [Float], im: [Float], frames: Int) {
        let half = taps / 2
        var padded = [Float](repeating: 0, count: x.count + taps)
        for i in 0..<half { padded[i] = x[half - i] }
        for i in 0..<x.count { padded[half + i] = x[i] }
        for i in 0..<half { padded[half + x.count + i] = x[x.count - 2 - i] }
        let frames = (padded.count - taps) / hop + 1
        var framed = [Float](repeating: 0, count: frames * taps)
        for f in 0..<frames {
            framed.withUnsafeMutableBufferPointer { dst in
                padded.withUnsafeBufferPointer { src in
                    (dst.baseAddress! + f * taps).update(from: src.baseAddress! + f * hop, count: taps)
                }
            }
        }
        var re = [Float](repeating: 0, count: frames * 12), im = re
        vDSP_mmul(framed, 1, kernelsT.real, 1, &re, 1, vDSP_Length(frames), 12, vDSP_Length(taps))
        vDSP_mmul(framed, 1, kernelsT.imag, 1, &im, 1, vDSP_Length(frames), 12, vDSP_Length(taps))
        return (re, im, frames)   // imaginary sign is irrelevant for magnitude
    }

    /// Linear resampling along frames (bilinear, align_corners = false), 12 bins per row.
    static func resize(_ v: [Float], frames m: Int, to n: Int) -> [Float] {
        guard m != n else { return v }
        var out = [Float](repeating: 0, count: n * 12)
        for f in 0..<n {
            let src = min(max((Double(f) + 0.5) * Double(m) / Double(n) - 0.5, 0), Double(m - 1))
            let i0 = Int(src), i1 = min(i0 + 1, m - 1)
            let w = Float(src - Double(i0))
            for b in 0..<12 { out[f * 12 + b] = v[i0 * 12 + b] * (1 - w) + v[i1 * 12 + b] * w }
        }
        return out
    }
}
