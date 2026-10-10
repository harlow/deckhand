import Foundation
import Sync

/// Machine-readable lines the `deckhand` CLI prints for the app, besides `@progress`.
public enum JobLine: Sendable, Equatable {
    /// `@result {...}`: the last line of `deckhand sync`, from its self-check after writing.
    case result(SyncReport)
    /// `@live {...}`: `--require-live` was given and Music couldn't be read live, so nothing was written.
    case live(LiveWarning)

    public static func parse(_ line: String) -> JobLine? {
        let decoder = JSONDecoder()
        if let json = payload(line, "@result") {
            return (try? decoder.decode(SyncReport.self, from: json)).map(JobLine.result)
        }
        if let json = payload(line, "@live") {
            return (try? decoder.decode(LiveWarning.self, from: json)).map(JobLine.live)
        }
        return nil
    }

    private static func payload(_ line: String, _ tag: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(tag + " ") else { return nil }
        return Data(trimmed.dropFirst(tag.count + 1).utf8)
    }
}

/// What a sync reported in its `@result` line: what it did, and whether reading everything again afterwards was clean.
public struct SyncReport: Decodable, Sendable, Equatable {
    /// The drive's manifest generation after the sync.
    public var generation: Int
    /// Nothing left to do after syncing.
    public var clean: Bool
    /// Changes still pending (`ChangeSet.Summary.total`).
    public var pending: Int
    public var tracks: Int?
    public var copied: Int?
    public var analyzed: Int?
    public var analysisFailed: Int?
    public var removed: Int?
    public var wroteDatabase: Bool?
    public var summary: ChangeSet.Summary?

    public init(generation: Int, clean: Bool, pending: Int, summary: ChangeSet.Summary? = nil) {
        self.generation = generation
        self.clean = clean
        self.pending = pending
        self.summary = summary
    }
}

public struct LiveWarning: Decodable, Sendable, Equatable {
    public var live: Bool
    /// The Apple Event error, e.g. -1743 (not allowed) or -1712 (timed out).
    public var status: Int32
    public var reason: String
}
