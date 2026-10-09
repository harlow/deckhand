import Analysis
import DeckhandCore
import Foundation

/// Analyzes tracks concurrently and caches results by audio content hash.
public struct AnalysisRunner {
    public struct Item: Sendable {
        public var url: URL
        public var contentHash: String
        public var title: String

        public init(url: URL, contentHash: String, title: String) {
            self.url = url
            self.contentHash = contentHash
            self.title = title
        }
    }

    public enum Event: Sendable {
        case started(index: Int, total: Int, title: String)
        /// A track finished (successfully or not); `done` counts completed tracks.
        case finished(done: Int, total: Int, title: String)
        case failed(title: String, error: String)
    }

    let cache: AnalysisCache
    let progress: @Sendable (Event) -> Void

    public init(cache: AnalysisCache, progress: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.cache = cache
        self.progress = progress
    }

    /// Analyzes items not already cached. Returns results for all analyzed items.
    public func run(_ items: [Item]) -> [String: TrackAnalysis] {
        let pending = items.filter { cache.analysis(forHash: $0.contentHash) == nil }
        guard !pending.isEmpty else { return [:] }
        let lock = NSLock()
        nonisolated(unsafe) var results: [String: TrackAnalysis] = [:]
        nonisolated(unsafe) var started = 0
        nonisolated(unsafe) var completed = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        for item in pending {
            queue.addOperation {
                let index = lock.withLock { started += 1; return started }
                progress(.started(index: index, total: pending.count, title: item.title))
                do {
                    let r = try analyze(item.url)
                    try cache.store(r.analysis, cues: r.cues, sections: r.sections, forHash: item.contentHash)
                    let a = r.analysis
                    lock.withLock { results[item.contentHash] = a }
                } catch {
                    progress(.failed(title: item.title, error: "\(error)"))
                }
                let done = lock.withLock { completed += 1; return completed }
                progress(.finished(done: done, total: pending.count, title: item.title))
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        try? cache.saveFingerprints()
        return results
    }

    /// Decodes once and runs every analysis stage on the same audio; cue and structure detection
    /// share one pass of per-beat features.
    func analyze(_ url: URL) throws -> (analysis: TrackAnalysis, cues: CueAnalyzer.Result, sections: [StructureAnalyzer.Section]) {
        let audio = try AudioDecoder.decodeMono(url)
        let analysis = TrackAnalyzer.analyze(audio)
        guard analysis.beats.count > 64 else { return (analysis, CueAnalyzer.Result(cues: [], energy: nil), []) }
        let beatTimes = analysis.beats.map { Double($0.timeMs) / 1000 } + [analysis.durationSeconds]
        let features = BeatFeatures(audio: audio, waveforms: analysis.waveforms, beatTimes: beatTimes,
                                    timelineOffset: audio.timelineOffsetSeconds).rows
        let cues = CueAnalyzer.detect(features: features, beatTimesMs: analysis.beats.map(\.timeMs),
                                      barPositions: analysis.beats.map(\.barPosition), bpm: analysis.bpm)
        let sections = StructureAnalyzer.analyze(audio, analysis: analysis, features: features)
        return (analysis, cues, sections)
    }
}
