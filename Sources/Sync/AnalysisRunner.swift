import Analysis
import DeckhandCore
import Foundation

/// How file tags are used during analysis.
public struct AnalysisPolicy: Sendable, Equatable {
    /// Use the file's key tag when present instead of detecting the key.
    public var keyFromTags = true
    /// Use the file's BPM tag to choose tempo and pin the beat grid.
    public var bpmHintFromTags = true

    public init(keyFromTags: Bool = true, bpmHintFromTags: Bool = true) {
        self.keyFromTags = keyFromTags
        self.bpmHintFromTags = bpmHintFromTags
    }

    /// Stored with cached results; a different policy means re-analysis.
    var fingerprint: String { "key-tags=\(keyFromTags ? 1 : 0);bpm-hint=\(bpmHintFromTags ? 1 : 0)" }
}

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
        case failed(title: String, error: String)
    }

    let cache: AnalysisCache
    let policy: AnalysisPolicy
    let progress: @Sendable (Event) -> Void

    public init(cache: AnalysisCache, policy: AnalysisPolicy, progress: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.cache = cache
        self.policy = policy
        self.progress = progress
    }

    /// Analyzes items not already cached under this policy. Returns results for all analyzed items.
    public func run(_ items: [Item]) -> [String: TrackAnalysis] {
        let pending = items.filter { cache.analysis(forHash: $0.contentHash, policy: policy) == nil }
        guard !pending.isEmpty else { return [:] }
        let lock = NSLock()
        nonisolated(unsafe) var results: [String: TrackAnalysis] = [:]
        nonisolated(unsafe) var started = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        for item in pending {
            queue.addOperation {
                let index = lock.withLock { started += 1; return started }
                progress(.started(index: index, total: pending.count, title: item.title))
                do {
                    let a = try analyze(item.url)
                    try cache.store(a, forHash: item.contentHash, policy: policy)
                    lock.withLock { results[item.contentHash] = a }
                } catch {
                    progress(.failed(title: item.title, error: "\(error)"))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        try? cache.saveFingerprints()
        return results
    }

    func analyze(_ url: URL) throws -> TrackAnalysis {
        let tags = (policy.keyFromTags || policy.bpmHintFromTags) ? FileTagReader.read(url) : FileTags()
        let hints = AnalysisHints(bpm: policy.bpmHintFromTags ? tags.bpm : nil, key: policy.keyFromTags ? tags.key : nil)
        return try TrackAnalyzer.analyze(url: url, hints: hints)
    }
}
