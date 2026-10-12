import Analysis
import DeckhandCore
import Foundation
import MusicSource
import OneLibrary

/// What a sync did.
public struct SyncResult: Sendable {
    /// Track IDs by what happened to them.
    public var copied: [String] = []
    public var adopted: [String] = []
    public var analyzed: [String] = []
    public var analysisFailed: [String] = []
    /// Analysis files checked, and those actually rewritten.
    public var anlzChecked: [String] = []
    public var anlzWritten: [String] = []
    public var artworkChecked: [String] = []
    public var imagesWritten = 0
    /// USB paths of audio deleted after the sync.
    public var removed: [String] = []
    public var wroteDatabase = false
    /// The manifest as saved; nil if it didn't need saving.
    public var manifest: Manifest?
    /// The drive's selection or settings were edited during the sync and kept.
    public var keptConcurrentEdits = false

    public init() {}
}

/// Carries out a ChangeSet on a drive.
///
/// Order: move/copy audio → analyze → analysis files → artwork → build and validate the database locally → check
/// the manifest wasn't replaced meanwhile → write and swap in the database → flush → save the manifest → delete
/// what left the drive. Until the swap, the drive's existing library stays valid; files the manifest vouches for
/// are only rewritten in place after it stops vouching for them, so a sync cut short never leaves them trusted.
public struct SyncExecutor {
    public enum Event: Sendable {
        case copying(index: Int, total: Int, title: String)
        case analyzing(index: Int, total: Int, title: String)
        case analyzed(done: Int, total: Int, title: String)
        case analysisFailed(title: String, error: String)
        /// Checking (and where needed rewriting) a track's analysis files on the drive.
        case writingAnalysisFiles(index: Int, total: Int, title: String)
        case writingDatabase
        case committing
        case removing(count: Int)
        case done
    }

    let cache: AnalysisCache
    let progress: @Sendable (Event) -> Void
    /// Cover art source; with none, the drive's art is left as it is.
    public var artwork: (any ArtworkProvider)?
    /// Analyze audio the analyzer failed on before (`--retry-failed`).
    public var retryFailedAnalysis = false

    /// Only analysis that changed, moved, or lacks the manifest's prior proof needs to be inspected again.
    static func analysisValidationDirectories(_ tracks: [ChangeSet.Track], baseline: Manifest) -> Set<String> {
        Set(tracks.compactMap { track -> String? in
            guard track.isPlaced, let path = track.usbPath else { return nil }
            let previous = baseline.tracks[track.id]
            let trusted = previous?.anlzFingerprint != nil && previous?.usbPath == path
                && previous?.contentHash == track.contentHash && !track.changes.contains(.analysisFiles)
            return trusted ? nil : AnlzPath.directory(forAudioPath: path)
        })
    }

    static let dbRelativePath = DriveProbe.databasePath
    /// For tests: stop as if the drive were unplugged just before the manifest is saved.
    var stopBeforeManifest = false

    public init(cache: AnalysisCache, progress: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.cache = cache
        self.progress = progress
    }

    /// `forceDatabase` rewrites the database even if nothing in it changed.
    @discardableResult
    public func execute(_ changes: ChangeSet, on volume: Volume, forceDatabase: Bool = false) throws -> SyncResult {
        guard changes.base.acceptsSource(changes.nextManifest.sourceID) else { throw SyncError.sourceMismatch }
        guard changes.isComplete else { throw SyncError.incompletePlan(max(1, changes.summary.unknown)) }
        var result = SyncResult()
        guard !changes.isClean || forceDatabase else {
            progress(.done)
            return result
        }
        try volume.checkWritable()
        let free = try volume.currentAvailable()
        if changes.spaceNeeded > free { throw SyncError.insufficientSpace(needed: changes.spaceNeeded, available: free) }

        let timer = PhaseTimer()
        let base = changes.base
        // The drive's manifest as this sync last saved or read it.
        var saved = base
        let profile = changes.profile
        var tracks = changes.tracks
        var manifest = changes.nextManifest

        // 1. Audio.
        try placeAudio(&tracks, on: volume, result: &result)
        var wroteFiles = !result.copied.isEmpty || !result.adopted.isEmpty
        timer.mark("copy")

        // 2. Analysis.
        let toAnalyze = tracks.indices.filter { tracks[$0].changes.contains(.analyze) }
        if !toAnalyze.isEmpty {
            let progress = self.progress
            let runner = AnalysisRunner(cache: cache) { event in
                switch event {
                case .started(let i, let n, let title): progress(.analyzing(index: i, total: n, title: title))
                case .finished(let d, let n, let title): progress(.analyzed(done: d, total: n, title: title))
                case .failed(let title, let error): progress(.analysisFailed(title: title, error: error))
                }
            }
            _ = runner.run(toAnalyze.compactMap { i in
                tracks[i].source.location.map { .init(url: $0, contentHash: tracks[i].contentHash!, title: tracks[i].source.title) }
            }, retryFailed: retryFailedAnalysis)
            for i in toAnalyze {
                var c = tracks[i].changes
                c.remove(.analyze)
                if let s = cache.summary(forHash: tracks[i].contentHash!) {
                    tracks[i].facts.analysis = AnalysisFacts(s)
                    tracks[i].facts.analysisFailure = nil
                    c.insert(.analysisFiles)
                    tracks[i].anlzMissing = true
                    result.analyzed.append(tracks[i].id)
                } else {
                    tracks[i].facts.analysisFailure = cache.analysisFailure(forHash: tracks[i].contentHash!) ?? "analysis failed"
                    result.analysisFailed.append(tracks[i].id)
                }
                tracks[i].status = c.isEmpty ? .failed(tracks[i].facts.analysisFailure ?? "") : .pending(c)
            }
            timer.mark("analyze")
        }
        try cache.save()

        // 3. Analysis files.
        let anlzWork = tracks.indices.filter { tracks[$0].changes.contains(.analysisFiles) }
        var vouchingWithdrawn = false
        for (n, i) in anlzWork.enumerated() {
            let t = tracks[i]
            progress(.writingAnalysisFiles(index: n + 1, total: anlzWork.count, title: t.source.title))
            guard let hash = t.contentHash, let summary = cache.summary(forHash: hash), let a = cache.analysis(forHash: hash) else {
                // The cache entry went away since evaluating: this sync writes the track without analysis.
                tracks[i].facts.analysis = nil
                continue
            }
            tracks[i].facts.analysis = AnalysisFacts(summary)
            let built = Self.anlzContent(analysis: a, sections: cache.sections(forHash: hash),
                                         detected: cache.detectedCues(forHash: hash), profile: profile)
            let unchanged = Manifest.matches(manifest.tracks[t.id]?.anlzFingerprint, built.fingerprint)
            if t.anlzMissing || !unchanged || profile.rewriteAnalysisFiles {
                let writes = anlzWrites(path: t.usbPath!, analysis: a, cues: built.cues, phrases: built.phrases,
                                        options: profile.anlzOptions, on: volume, force: profile.rewriteAnalysisFiles)
                if !writes.isEmpty {
                    try volume.ensureMounted()
                    if !vouchingWithdrawn, let r = base.tracks[t.id], r.usbPath == t.usbPath, r.contentHash == t.contentHash,
                       r.anlzFingerprint != nil {
                        // The manifest vouches for these files. Overwriting them in place first needs a saved manifest
                        // that doesn't (one write and flush covers every track this phase may rewrite).
                        let before = saved
                        saved = try withdrawVouching(for: anlzWork.map { tracks[$0].id }, basedOn: saved, on: volume)
                        if manifest.takeEdits(from: saved, since: before) { result.keptConcurrentEdits = true }
                        vouchingWithdrawn = true
                    }
                    for (url, data) in writes { try FileOps.write(data, to: url) }
                    wroteFiles = true
                    result.anlzWritten.append(t.id)
                }
            }
            manifest.tracks[t.id]?.anlzInputs = Manifest.digest(SyncStatus.anlzInputs(AnalysisFacts(summary), key: profile.anlzKey))
            manifest.tracks[t.id]?.anlzFingerprint = Manifest.digest(built.fingerprint)
            result.anlzChecked.append(t.id)
        }
        timer.mark("anlz files")

        // 4. Artwork.
        var orphanedArt: [String] = []
        if profile.artwork, let provider = artwork {
            orphanedArt = try writeArtwork(&tracks, &manifest, changes: changes, provider: provider, on: volume, result: &result)
            if result.imagesWritten > 0 { wroteFiles = true }
            timer.mark("artwork")
        }

        // 5. Database rows, now that sizes, analysis and art are final.
        var rows: [ExportTrack] = []
        var rowsChanged = false
        for t in tracks where t.isPlaced {
            let row = SyncStatus.exportTrack(t, settings: profile.settings, fallbackDate: base.createdAt)
            let fingerprint = Manifest.digest(row.fingerprint(keyFormat: profile.settings.keyFormat))
            if fingerprint != base.tracks[t.id]?.recordFingerprint { rowsChanged = true }
            manifest.tracks[t.id]?.recordFingerprint = fingerprint
            manifest.tracks[t.id]?.fileSize = t.driveSize
            manifest.tracks[t.id]?.rowAnalysis = t.rowAnalysis?.stored
            rows.append(row)
        }
        let playlistsChanged = changes.playlists.contains { $0.status != .clean } || !changes.removedPlaylists.isEmpty
        let writeDatabase = forceDatabase || rowsChanged || playlistsChanged || !changes.removedTracks.isEmpty
            || changes.drive.contains(.databaseMissing) || changes.drive.contains(.databaseChanged)

        // 6. Database: built and validated locally (SQLite on a FAT stick flushes per page and takes tens of seconds),
        // then written to the drive in one pass and renamed into place.
        if writeDatabase {
            progress(.writingDatabase)
            let contents = OneLibraryDatabase.Contents(
                tracks: rows,
                playlists: changes.playlists.map {
                    ExportPlaylist(playlistId: $0.record.playlistId, name: $0.record.name, parentId: $0.record.parentPlaylistId,
                                   isFolder: $0.source.isFolder, sequenceNo: $0.record.sequenceNo, contentIds: $0.record.contentIds)
                },
                keyFormat: profile.settings.keyFormat)
            let dbURL = volume.url(forUsbPath: Self.dbRelativePath)
            let rbDir = dbURL.deletingLastPathComponent()
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-\(UUID().uuidString).db")
            defer { try? FileManager.default.removeItem(at: local) }
            try OneLibraryDatabase.write(contents, to: local, previous: carriesHistory(changes, on: volume) ? dbURL : nil)
            timer.mark("db build")
            // Keep the plan's proof for unchanged analysis. A rating or playlist edit mustn't reread the USB's
            // entire waveform library. Replaced/missing databases and forced rebuilds get a full inspection.
            let inspectAll = forceDatabase || changes.drive.contains(.databaseChanged) || changes.drive.contains(.databaseMissing)
            let issues = try OneLibraryValidator.validate(database: local, volumeRoot: volume.url,
                analysisDirectoriesToInspect: inspectAll ? nil : Self.analysisValidationDirectories(tracks, baseline: base))
            if !issues.isEmpty { throw OneLibraryError.validation(issues) }
            timer.mark("db validate")

            try volume.ensureMounted()
            // Last chance to back out with the drive's library untouched: another sync must not have saved meanwhile.
            try Manifest.checkUnchanged(since: saved, on: volume)
            let staging = rbDir.appendingPathComponent(".deckhand-staging-exportLibrary.db")
            try FileOps.write(try Data(contentsOf: local), to: staging)
            timer.mark("database")

            progress(.committing)
            FileOps.syncFilesystem()
            timer.mark("commit flush")
            for suffix in ["-wal", "-shm"] { unlink(dbURL.path + suffix) }
            unlink(rbDir.appendingPathComponent("exportLibrary.db.deckhand-backup").path) // left by older versions
            guard rename(staging.path, dbURL.path) == 0 else { throw FileOps.posixError(dbURL.path) }
            FileOps.removeAppleDouble(of: dbURL)
            manifest.lastSyncedAt = Date()
            manifest.databaseId = OneLibraryDatabase.fileId(local)
            result.wroteDatabase = true
            timer.mark("commit swap")
        }

        // 7. Manifest, once the files it vouches for are on the stick (the database path flushed already).
        if wroteFiles && !result.wroteDatabase { FileOps.syncFilesystem() }
        if stopBeforeManifest { throw SyncError.volumeDisappeared(volume.name) }
        if manifest != saved {
            let committed = try Manifest.commit(manifest, basedOn: saved, on: volume)
            if committed.selectedPlaylistIds != manifest.selectedPlaylistIds || committed.entireLibrary != manifest.entireLibrary
                || committed.settings != manifest.settings { result.keptConcurrentEdits = true }
            result.manifest = committed
            timer.mark("commit manifest")
        }
        FileOps.syncFilesystem()

        // 8. Delete what left the drive. Analysis folders shared with a kept track (path-hash collisions) stay.
        let deletions = changes.removedTracks.filter(\.deletesFiles)
        if !deletions.isEmpty {
            progress(.removing(count: deletions.count))
            let keptAnlz = Set(tracks.compactMap { $0.usbPath.map { DriveProbe.key(AnlzPath.directory(forAudioPath: $0)) } })
            for r in deletions {
                try? FileManager.default.removeItem(at: volume.url(forUsbPath: r.record.usbPath))
                let dir = AnlzPath.directory(forAudioPath: r.record.usbPath)
                if !keptAnlz.contains(DriveProbe.key(dir)) { try? FileManager.default.removeItem(at: volume.url(forUsbPath: dir)) }
                result.removed.append(r.record.usbPath)
            }
        }
        for path in orphanedArt {
            try? FileManager.default.removeItem(at: volume.url(forUsbPath: path))
            try? FileManager.default.removeItem(at: volume.url(forUsbPath: ArtworkWriter.mediumPath(forSmall: path)))
        }
        // Deckhand writes without xattrs, so `._` files can only appear next to files macOS itself touched.
        FileOps.removeAppleDoubleFiles(in: volume.url(forUsbPath: Self.dbRelativePath).deletingLastPathComponent())
        timer.mark("cleanup")
        progress(.done)
        return result
    }

    /// Moves adopted audio into place, verifies audio already at its path, and copies the rest.
    private func placeAudio(_ tracks: inout [ChangeSet.Track], on volume: Volume, result: inout SyncResult) throws {
        let work = tracks.indices.filter { !tracks[$0].changes.isDisjoint(with: [.new, .audioChanged, .missingOnDrive, .adopt]) }
        let copyTotal = work.filter { tracks[$0].copies }.count
        var placed: [String: (size: Int64, copied: Bool)] = [:]   // tracks sharing a file place it once
        var copies = 0
        for i in work {
            let t = tracks[i]
            guard case .ok(let hash, _, _) = t.facts.audio, let src = t.source.location, let path = t.usbPath else { continue }
            let dst = volume.url(forUsbPath: path)
            try volume.ensureMounted()
            if let done = placed[DriveProbe.key(path)] {
                if done.copied { result.copied.append(t.id) } else { result.adopted.append(t.id) }
                tracks[i].driveSize = done.size
                continue
            }
            var actual: Int64?
            var copied = false
            if let from = t.adoptFrom {
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                do {
                    try FileManager.default.moveItem(at: volume.url(forUsbPath: from), to: dst)
                } catch {
                    throw SyncError.copyFailed(from, error)
                }
                actual = FileOps.size(dst)
                result.adopted.append(t.id)
            } else if t.changes.contains(.adopt) {
                // Already at its path. Copies are renamed into place only when complete, but FAT can lose unflushed
                // data in a crash, so it's only trusted if it holds the same audio. Its tags may differ (another
                // track with the same audio and name owns it): that's fine, and it isn't copied over.
                if (try? AudioHash.hash(dst)) == hash {
                    actual = FileOps.size(dst)
                    result.adopted.append(t.id)
                }
            }
            if actual == nil {
                copies += 1
                progress(.copying(index: copies, total: max(copyTotal, copies), title: t.source.title))
                do {
                    actual = try FileOps.copyData(from: src, to: dst)
                } catch {
                    throw SyncError.copyFailed(src.path, error)
                }
                copied = true
                result.copied.append(t.id)
            }
            placed[DriveProbe.key(path)] = (actual!, copied)
            tracks[i].driveSize = actual!
        }
    }

    /// Player history refers to content IDs, which only mean the same tracks in a database Deckhand wrote: the
    /// one it last recorded, or (after a sync cut short) one whose tracks are all in Deckhand's folder.
    private func carriesHistory(_ changes: ChangeSet, on volume: Volume) -> Bool {
        let base = changes.base
        guard base.lastSyncedAt != nil, changes.probe.databaseId != nil else { return false }
        if base.databaseId == nil || base.databaseId == changes.probe.databaseId { return true }
        guard let ids = try? DeviceLibrary.contentIds(database: volume.url(forUsbPath: Self.dbRelativePath)), !ids.isEmpty else {
            return false
        }
        let own = DriveProbe.key(DriveProbe.audioRoot + "/")
        return ids.keys.allSatisfy { DriveProbe.key($0).hasPrefix(own) }
    }

    /// Rereads cover art where evaluate asked, writes images the drive lacks, sets each track's image, and returns
    /// image paths no track uses anymore (deleted after the sync).
    private func writeArtwork(_ tracks: inout [ChangeSet.Track], _ manifest: inout Manifest, changes: ChangeSet,
                              provider: any ArtworkProvider, on volume: Volume, result: inout SyncResult) throws -> [String] {
        let recorded = changes.base.artwork ?? [:]
        var used: [String: Int] = [:]
        var next = changes.base.nextImageId ?? 1
        for i in tracks.indices where tracks[i].isPlaced {
            let id = tracks[i].id
            var data: Data?
            var hash: String?
            if tracks[i].changes.contains(.artworkCheck) {
                // Reading and hashing art costs ~200 KB per track, so only where the track or file changed.
                data = provider.artwork(forTrackId: id)
                hash = data.map(ArtworkWriter.hash)
                manifest.tracks[id]?.artworkKey = tracks[i].artworkKey
                manifest.tracks[id]?.artworkHash = hash
                result.artworkChecked.append(id)
            } else {
                hash = manifest.tracks[id]?.artworkHash
                // Evaluate found the art unchanged under a new key (or kept a retained track's): record the key.
                if let key = tracks[i].artworkKey { manifest.tracks[id]?.artworkKey = key }
            }
            guard let h = hash else {
                tracks[i].artworkPath = nil
                continue
            }
            if let imageId = used[h] {
                tracks[i].artworkPath = ArtworkWriter.path(imageId: imageId)
                continue
            }
            let imageId = recorded[h] ?? {
                defer { next += 1 }
                return next
            }()
            let small = ArtworkWriter.path(imageId: imageId), medium = ArtworkWriter.mediumPath(forSmall: small)
            let vouched = recorded[h] == imageId
            if !vouched || !changes.probe.hasImage(small) || !changes.probe.hasImage(medium) {
                guard let d = data ?? provider.artwork(forTrackId: id),
                      let s = ArtworkWriter.jpeg(d, size: ArtworkWriter.smallSize),
                      let m = ArtworkWriter.jpeg(d, size: ArtworkWriter.mediumSize) else {
                    // Unusable art: the track goes without until its art changes.
                    manifest.tracks[id]?.artworkHash = nil
                    tracks[i].artworkPath = nil
                    continue
                }
                try volume.ensureMounted()
                // New images are only trusted once the manifest records them; ones it already records are replaced whole.
                if vouched {
                    try FileOps.writeAtomically(s, to: volume.url(forUsbPath: small))
                    try FileOps.writeAtomically(m, to: volume.url(forUsbPath: medium))
                } else {
                    try FileOps.write(s, to: volume.url(forUsbPath: small))
                    try FileOps.write(m, to: volume.url(forUsbPath: medium))
                }
                result.imagesWritten += 1
            }
            used[h] = imageId
            tracks[i].artworkPath = small
        }
        if !used.isEmpty || changes.base.artwork != nil { manifest.artwork = used }
        if next != (changes.base.nextImageId ?? 1) || changes.base.nextImageId != nil { manifest.nextImageId = next }
        return recorded.filter { used[$0.key] == nil }.map { ArtworkWriter.path(imageId: $0.value) }
    }

    /// The track's analysis files whose bytes differ from what's on the drive (all of them when `force`). A
    /// fingerprint can change without the bytes changing (it includes the analysis version), and reading is cheaper
    /// than writing on flash.
    private func anlzWrites(path: String, analysis: TrackAnalysis, cues: [CuePoint], phrases: PhraseAnalysis?,
                            options: AnlzWriter.Options, on volume: Volume, force: Bool) -> [(URL, Data)] {
        let totalSamples = UInt64((analysis.durationSeconds * Double(analysis.sampleRate)).rounded())
        let files = AnlzWriter(audioPath: path, analysis: analysis, totalSamples: totalSamples, cues: cues,
                               phrases: phrases, options: options).build()
        let dir = volume.url(forUsbPath: AnlzPath.directory(forAudioPath: path))
        return [(files.dat, "ANLZ0000.DAT"), (files.ext, "ANLZ0000.EXT"), (files.twoEx, "ANLZ0000.2EX")].compactMap { data, name in
            let url = dir.appendingPathComponent(name)
            if !force, FileOps.size(url) == Int64(data.count), (try? Data(contentsOf: url)) == data { return nil }
            return (url, data)
        }
    }

    /// Saves the manifest no longer vouching for these tracks' analysis files, and flushes, before any is rewritten in
    /// place: if the sync is then cut short, the next one checks those files instead of trusting half-written ones.
    private func withdrawVouching(for ids: [String], basedOn base: Manifest, on volume: Volume) throws -> Manifest {
        var m = base
        for id in ids {
            m.tracks[id]?.anlzInputs = nil
            m.tracks[id]?.anlzFingerprint = nil
        }
        let saved = try Manifest.commit(m, basedOn: base, on: volume)
        FileOps.syncFilesystem()
        return saved
    }

    /// The cues and phrases a track's analysis files hold, and their fingerprint (`Manifest.Track.anlzFingerprint`).
    static func anlzContent(analysis a: TrackAnalysis, sections: [StructureAnalyzer.Section]?, detected: CueAnalyzer.Result?,
                            profile: OutputProfile) -> (cues: [CuePoint], phrases: PhraseAnalysis?, fingerprint: String) {
        let s = profile.settings
        let cues = CueBuilder.cues(detected: detected, analysis: a, mode: s.cues, hotStyle: s.hotCues, sections: sections,
                                   buildLeadBars: s.buildLead)
        let phrases = s.phrases ? sections.flatMap { StructureAnalyzer.phrases(sections: $0, analysis: a) } : nil
        let phraseKey = phrases.map { $0.phrases.map { "\($0.beat):\($0.kind)" }.joined(separator: ",") } ?? "-"
        var fingerprint = "v\(a.version);pqt2=\(profile.anlzOptions.includeExtendedBeatGrid);cues=\(CueBuilder.fingerprint(cues));pssi=\(phraseKey)"
        // Format 1 and masked phrases add nothing, so fingerprints on existing drives still match.
        if AnlzWriter.formatVersion > 1 { fingerprint += ";w\(AnlzWriter.formatVersion)" }
        if !profile.anlzOptions.maskPhrases { fingerprint += ";unmasked" }
        return (cues, phrases, fingerprint)
    }
}

/// Prints phase durations to stderr when DECKHAND_TIMING is set.
public final class PhaseTimer {
    private var last = Date()

    public init() {}
    private let enabled = ProcessInfo.processInfo.environment["DECKHAND_TIMING"] != nil

    public func mark(_ phase: String) {
        guard enabled else { return }
        let now = Date()
        FileHandle.standardError.write(Data(String(format: "[timing] %@ %.2fs\n", phase, now.timeIntervalSince(last)).utf8))
        last = now
    }
}
