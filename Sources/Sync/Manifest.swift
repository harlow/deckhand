import CryptoKit
import Foundation

/// Deckhand's record of what it wrote to a drive, stored in `/.deckhand/`. Not read by DJ players. Written last on
/// every sync.
///
/// It's also where the app keeps each drive's selection, so it can change while a sync runs: saves go through
/// `update`, which refuses to overwrite a copy other than the one a change was based on.
public struct Manifest: Codable, Sendable, Equatable {
    /// Bump only for changes older versions can't safely read and rewrite; they refuse to save newer formats.
    public static let currentFormat = 1
    static let directory = ".deckhand"
    static let fileName = "manifest.json"

    public struct Track: Codable, Sendable, Equatable {
        public var contentId: Int
        public var usbPath: String
        public var contentHash: String
        /// Unused; still written so older versions can read the manifest.
        public var analysisVersion: Int
        /// Inputs the ANLZ files were last written from (cues, writer options); a change forces a rewrite.
        public var anlzFingerprint: String?
        /// Cache entry, settings and recipe `anlzFingerprint` was computed from; while unchanged the
        /// fingerprint is too, so checking it needs no decoding.
        public var anlzInputs: String? = nil
        /// The track's source fields (title, rating, …) when last written. Superseded by `recordFingerprint`; kept
        /// for the app's track list until it reads SyncStatus.
        public var metadataFingerprint: String?
        /// Artwork hash, valid while `artworkKey` (audio file and track modification) is unchanged.
        public var artworkKey: String? = nil
        public var artworkHash: String? = nil
        /// Digest of the database row last written (`ExportTrack.fingerprint`). Older manifests lack it, which
        /// rewrites the database once.
        public var recordFingerprint: String? = nil
        /// Size of the copy on the drive. Tag edits can grow the source without changing its audio, and then it
        /// isn't copied again.
        public var fileSize: Int64? = nil
    }

    public struct Playlist: Codable, Sendable, Equatable {
        public var playlistId: Int
        public var name: String
        public var parentPlaylistId: Int?
        public var sequenceNo: Int
        public var contentIds: [Int]
    }

    public var format = Manifest.currentFormat
    public var deviceId = UUID().uuidString
    public var createdAt = Date()
    public var lastSyncedAt: Date?
    /// Source playlist IDs the user selected for this drive.
    public var selectedPlaylistIds: [String] = []
    /// Put every song on the drive, not just those in the selected playlists. Optional for older manifests.
    public var entireLibrary: Bool?
    /// Keyed by source track ID.
    public var tracks: [String: Track] = [:]
    /// Keyed by source playlist ID.
    public var playlists: [String: Playlist] = [:]
    public var nextContentId = 1
    public var nextPlaylistId = 1
    /// Output settings chosen for this drive (cue source, hot cue style, key format, …).
    public var settings: [String: String]?
    /// Artwork content hash → image ID. Optional so older manifests still decode.
    public var artwork: [String: Int]?
    public var nextImageId: Int?

    /// Incremented on every save; picks the newer of the two manifest files. Optional for older manifests.
    public var generation: Int?
    /// `OneLibraryDatabase.fileId` of the database this manifest describes, to notice it being replaced.
    public var databaseId: String?

    public init() {}

    /// `generation`, counting a manifest from before generations existed as 0.
    public var generationNumber: Int { generation ?? 0 }

    /// The manifest is saved alternately to two files, overwriting the older one in place: on FAT sticks creating
    /// and renaming files costs ~0.5 s each, and a write cut short leaves the other copy intact.
    static func urls(root: URL) -> [URL] {
        let dir = root.appendingPathComponent(directory)
        return [dir.appendingPathComponent(fileName), dir.appendingPathComponent("manifest-b.json")]
    }

    /// The readable copies by file index, and the first error from an unreadable one.
    struct Slots {
        var copies: [(slot: Int, manifest: Manifest)] = []
        var error: Error?

        /// The highest generation; on a tie, the second file.
        var newest: (slot: Int, manifest: Manifest)? {
            copies.max { ($0.manifest.generationNumber, $0.slot) < ($1.manifest.generationNumber, $1.slot) }
        }
    }

    static func readSlots(root: URL) -> Slots {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var slots = Slots()
        for (i, u) in urls(root: root).enumerated() where FileManager.default.fileExists(atPath: u.path) {
            do {
                slots.copies.append((i, try decoder.decode(Manifest.self, from: Data(contentsOf: u))))
            } catch {
                slots.error = slots.error ?? error
            }
        }
        return slots
    }

    public static func load(from volume: Volume) throws -> Manifest? { try load(root: volume.url) }

    static func load(root: URL) throws -> Manifest? {
        let slots = readSlots(root: root)
        if let newest = slots.newest { return newest.manifest }
        if let error = slots.error { throw error }
        return nil
    }

    /// Saves `change` applied to the drive's newest manifest, provided that's still the generation of `base` (nil:
    /// no manifest yet); else throws `SyncError.manifestConflict`. Writes whichever file doesn't hold the newest
    /// copy, so the only valid copy is never overwritten. Refuses to overwrite a newer format.
    @discardableResult
    public static func update(on volume: Volume, basedOn base: Manifest?,
                              _ change: (inout Manifest) throws -> Void) throws -> Manifest {
        try update(root: volume.url, name: volume.name, basedOn: base, change)
    }

    static func update(root: URL, name: String, basedOn base: Manifest?,
                       _ change: (inout Manifest) throws -> Void) throws -> Manifest {
        let slots = readSlots(root: root)
        let newest = slots.newest
        if newest == nil, base != nil, let error = slots.error { throw error }
        guard newest?.manifest.generationNumber == base?.generationNumber else {
            throw SyncError.manifestConflict(name)
        }
        if let n = newest?.manifest, n.format > currentFormat { throw SyncError.newerManifest(n.format) }
        var m = newest?.manifest ?? base ?? Manifest()
        try change(&m)
        if m.format > currentFormat { throw SyncError.newerManifest(m.format) }
        m.generation = (newest?.manifest.generationNumber ?? 0) + 1
        try write(m, to: urls(root: root)[newest.map { 1 - $0.slot } ?? 0])
        return m
    }

    /// Saves without a conflict check, as the generation after the drive's newest copy. For new drives and tests;
    /// anything read earlier goes through `update`.
    public func save(to volume: Volume) throws { try save(root: volume.url) }

    func save(root: URL) throws {
        let newest = Self.readSlots(root: root).newest
        var m = self
        m.generation = (newest?.manifest.generationNumber ?? 0) + 1
        try Self.write(m, to: Self.urls(root: root)[newest.map { 1 - $0.slot } ?? 0])
    }

    private static func write(_ m: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileOps.write(try encoder.encode(m), to: url)
    }

    /// Applies `change` to the drive's newest manifest and saves it, retrying when another save lands in between.
    /// Refuses while a sync holds the drive (it would have to merge the change). For the app's selection edits.
    @discardableResult
    public static func edit(on volume: Volume, _ change: (inout Manifest) -> Void) throws -> Manifest {
        try editLock.withLock {
            if let held = SyncLock.current(on: volume) { throw SyncError.driveBusy(volume.name, held) }
            var attempts = 0
            while true {
                guard let base = try load(from: volume) else { throw SyncError.notInitialized(volume.name) }
                do {
                    return try update(on: volume, basedOn: base, change)
                } catch SyncError.manifestConflict(let name) {
                    attempts += 1
                    if attempts == 3 { throw SyncError.manifestConflict(name) }
                }
            }
        }
    }

    /// Serializes this process's read-modify-write cycles (e.g. two quick toggles in the app).
    private static let editLock = NSLock()

    /// Saves a sync's result `ours`, computed from `base`. If the drive's manifest was edited meanwhile, keeps those
    /// edits (see `merged`); throws `manifestConflict` if anything else changed.
    static func commit(_ ours: Manifest, basedOn base: Manifest, on volume: Volume) throws -> Manifest {
        var ours = ours, base = base
        for _ in 0..<3 {
            do {
                return try update(on: volume, basedOn: base) { $0 = ours }
            } catch SyncError.manifestConflict {
                guard let theirs = try load(from: volume), let m = merged(ours: ours, base: base, theirs: theirs) else {
                    throw SyncError.manifestConflict(volume.name)
                }
                ours = m
                base = theirs
            }
        }
        throw SyncError.manifestConflict(volume.name)
    }

    /// Throws unless `base` is still the drive's newest manifest, or was only edited in ways `merged` keeps.
    static func checkUnchanged(since base: Manifest, on volume: Volume) throws {
        guard let current = try load(from: volume) else { throw SyncError.manifestConflict(volume.name) }
        guard current.generationNumber == base.generationNumber || merged(ours: base, base: base, theirs: current) != nil else {
            throw SyncError.manifestConflict(volume.name)
        }
    }

    /// `ours` (a sync's result from `base`) with the edits the app makes — selection, entire library, settings —
    /// taken from `theirs` wherever it changed them. Nil if `theirs` changed anything else (another sync).
    static func merged(ours: Manifest, base: Manifest, theirs: Manifest) -> Manifest? {
        func rest(_ m: Manifest) -> Data? {
            var m = m
            m.selectedPlaylistIds = []
            m.entireLibrary = nil
            m.settings = nil
            m.generation = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(m)
        }
        guard let a = rest(base), a == rest(theirs) else { return nil }
        var m = ours
        if theirs.selectedPlaylistIds != base.selectedPlaylistIds { m.selectedPlaylistIds = theirs.selectedPlaylistIds }
        if theirs.entireLibrary != base.entireLibrary { m.entireLibrary = theirs.entireLibrary }
        if theirs.settings != base.settings { m.settings = theirs.settings }
        return m
    }
}

extension Manifest {
    /// Fingerprints are stored as short digests (full ones run to kilobytes per track). Older manifests hold the
    /// full strings, which still match.
    public static func digest(_ fingerprint: String) -> String {
        // Hex by table: String(format:) per byte dominated evaluating large libraries.
        let digits = Array("0123456789abcdef".utf8)
        var out = Array("d:".utf8)
        out.reserveCapacity(26)
        for b in SHA256.hash(data: Data(fingerprint.utf8)).prefix(12) {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func matches(_ stored: String?, _ fingerprint: String) -> Bool {
        stored == fingerprint || stored == digest(fingerprint)
    }
}
