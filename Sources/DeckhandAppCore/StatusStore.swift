import DeckhandCore
import Foundation
import Sync

/// Everything one status evaluation reads, captured on the main thread.
public struct StatusInputs: Sendable {
    public var library: SourceLibrary
    public var driveId: String
    public var volume: Volume
    public var manifest: Manifest
    public var probe: DriveProbe

    public init(library: SourceLibrary, driveId: String, volume: Volume, manifest: Manifest, probe: DriveProbe) {
        self.library = library
        self.driveId = driveId
        self.volume = volume
        self.manifest = manifest
        self.probe = probe
    }
}

public enum StatusEvaluator {
    /// What the app's Sync (`deckhand sync <drive> -y --analyze --require-live`) would change, decided by the engine
    /// from the same library, drive files and settings. Off the main thread: stats each source file. Never hashes:
    /// audio the cache hasn't hashed yet is `.unknown` until the app's background hashing gets to it.
    public static func evaluate(_ inputs: StatusInputs, cache: AnalysisCache) -> DriveStatus {
        let m = inputs.manifest
        var profile = OutputProfile(settings: OutputSettings(saved: m.settings))
        profile.artwork = inputs.library.artwork != nil
        profile.analyzeMissing = true
        let scope = SyncStatus.scope(library: inputs.library, selection: Selection(m))
        var facts: [String: TrackFacts] = [:]
        facts.reserveCapacity(scope.trackIds.count)
        for id in scope.trackIds {
            guard let t = inputs.library.tracks[id] else { continue }
            facts[id] = SyncPlanner.facts(for: t, previousHash: m.tracks[id]?.contentHash, cache: cache, hashing: false)
        }
        let changes = SyncPlanner.evaluate(library: inputs.library, volume: inputs.volume, manifest: m, facts: facts,
                                           probe: inputs.probe, profile: profile)
        return DriveStatus(changes, driveId: inputs.driveId, available: inputs.volume.available)
    }
}

/// Decides which status evaluation the app shows. Evaluations run off the main thread and can land out of order;
/// the newest one issued wins. A finished sync makes everything issued before it stale and, if it reported clean,
/// shows clean right away; the evaluation issued once the library and drive have been read again ("verification")
/// replaces that, and is checked for anything still pending.
public struct StatusStore: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Superseded by a newer evaluation, or started before a sync finished: dropped.
        case stale
        case applied
        /// A sync's verification found nothing pending.
        case verified
        /// A sync's verification found work left: the status to warn about.
        case leftover(DriveStatus)
    }

    /// The latest status; nil until the first evaluation for the active drive lands ("Checking…").
    public private(set) var status: DriveStatus?
    private var issued = 0
    private var applied = 0
    /// Results of evaluations issued before this are stale.
    private var floor = 0
    private enum Verification: Sendable { case none, notIssued, issued(Int) }
    /// After a sync: its verification evaluation, until it lands.
    private var verification = Verification.none

    public init() {}

    public var awaitingVerification: Bool { if case .none = verification { false } else { true } }

    /// Issues an evaluation; pass its number to `finish`.
    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// Issues the evaluation that follows a sync's re-read of the library and drive.
    public mutating func beginVerification() -> Int {
        let request = begin()
        if awaitingVerification {
            verification = .issued(request)
            floor = request
        }
        return request
    }

    public mutating func finish(_ result: DriveStatus, request: Int) -> Outcome {
        guard request >= floor, request > applied else { return .stale }
        applied = request
        status = result
        guard case .issued(let v) = verification, request >= v else { return .applied }
        verification = .none
        return result.isClean ? .verified : .leftover(result)
    }

    /// A sync of `driveId` (the active drive) finished. Evaluations issued before now are stale, and so are later ones
    /// until the verification is issued (they'd use the drive as it was read before the sync). If the sync reported
    /// clean, shows that now.
    public mutating func syncFinished(driveId: String, report: SyncReport?) {
        floor = Int.max
        verification = .notIssued
        if report?.clean == true, let s = status, s.driveId == driveId { status = s.markedClean() }
    }

    /// Another drive is active (or none): forget the status until an evaluation for it lands.
    public mutating func reset() {
        status = nil
        floor = issued + 1
        verification = .none
    }
}

/// Orders reads that run concurrently and can finish out of order (drive manifests and probes): a result is applied
/// only if no read of the same thing begun later has been applied already. Local changes take a token too, so a read
/// begun before them can't overwrite them.
public struct ReadLedger: Sendable {
    private var issued = 0
    private var applied: [String: Int] = [:]

    public init() {}

    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// Whether a read of `key` begun with `token` is newer than what's applied; records it if so.
    public mutating func accept(_ key: String, _ token: Int) -> Bool {
        guard token > applied[key, default: 0] else { return false }
        applied[key] = token
        return true
    }
}
