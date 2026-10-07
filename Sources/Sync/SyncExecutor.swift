import Analysis
import DeckhandCore
import Foundation
import OneLibrary

/// Applies a SyncPlan to a drive.
///
/// Order: copy audio → analyze → write ANLZ → build DB in staging → validate →
/// back up and swap DB → write manifest → delete orphans → flush.
/// Until the swap, the drive's existing library stays valid.
public struct SyncExecutor {
    public enum Event: Sendable {
        case copying(index: Int, total: Int, title: String)
        case analyzing(index: Int, total: Int, title: String)
        case analysisFailed(title: String, error: String)
        case writingDatabase
        case committing
        case removing(count: Int)
        case done
    }

    let cache: AnalysisCache
    let progress: @Sendable (Event) -> Void
    /// ANLZ writer options; see AnlzWriter.Options.
    public var anlzOptions = AnlzWriter.Options()
    public var analysisPolicy = AnalysisPolicy()
    /// Cover art source; tracks get no artwork when nil.
    public var artwork: (any ArtworkProvider)?
    /// Rewrite analysis files for all tracks, e.g. after changing anlzOptions.
    public var rewriteAnalysisFiles = false

    static let dbRelativePath = "/PIONEER/rekordbox/exportLibrary.db"
    static let managedPaths = ["PIONEER", "Contents", "Contents/Deckhand", Manifest.directory]

    public init(cache: AnalysisCache, progress: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.cache = cache
        self.progress = progress
    }

    public func execute(_ plan: SyncPlan, keyFormat: OneLibraryDatabase.KeyFormat = .classic) throws {
        let volume = plan.volume
        try volume.checkWritable()
        let free = try Volume(url: volume.url).available
        let needed = plan.bytesToCopy + 20 << 20
        if needed > free { throw SyncError.insufficientSpace(needed: needed, available: free) }

        let timer = PhaseTimer()
        // 1. Copy audio.
        let toCopy = plan.tracks.filter { $0.action != .unchanged }
        for (i, t) in toCopy.enumerated() {
            progress(.copying(index: i + 1, total: toCopy.count, title: t.source.title))
            try ensureMounted(volume)
            let dst = volume.url(forUsbPath: t.usbPath)
            if FileManager.default.fileExists(atPath: dst.path), FileOps.size(dst) == t.fileSize,
               (try? FileOps.sha256(dst)) == t.contentHash {
                continue
            }
            do {
                try FileOps.copyData(from: t.sourceFile, to: dst)
            } catch {
                throw SyncError.copyFailed(t.sourceFile.path, error)
            }
        }

        timer.mark("copy")
        // 2. Analyze and 3. write ANLZ files for new/replaced tracks.
        let progress = self.progress
        let runner = AnalysisRunner(cache: cache, policy: analysisPolicy) { event in
            switch event {
            case .started(let i, let n, let title): progress(.analyzing(index: i, total: n, title: title))
            case .failed(let title, let error): progress(.analysisFailed(title: title, error: error))
            }
        }
        var analyses = runner.run(plan.tracks.filter(\.needsAnalysis).map {
            .init(url: $0.sourceFile, contentHash: $0.contentHash, title: $0.source.title)
        })
        timer.mark("analyze")
        try cache.saveFingerprints()

        for t in plan.tracks {
            guard let a = analyses[t.contentHash] ?? cache.analysis(forHash: t.contentHash, policy: analysisPolicy) else { continue }
            analyses[t.contentHash] = a
            if t.action == .unchanged && !t.needsAnalysis && !rewriteAnalysisFiles { continue }
            try ensureMounted(volume)
            try writeAnlz(for: t, analysis: a, on: volume)
        }

        // 4. Build the database in staging.
        timer.mark("anlz files")
        var manifest = plan.manifest
        let (artPaths, orphanedArt) = try writeArtwork(plan, manifest: &manifest)
        timer.mark("artwork")
        progress(.writingDatabase)
        let contents = OneLibraryDatabase.Contents(
            tracks: plan.tracks.map {
                var e = exportTrack($0, analysis: analyses[$0.contentHash])
                e.artworkPath = artPaths[$0.source.id]
                return e
            },
            playlists: plan.playlists.map {
                ExportPlaylist(playlistId: $0.playlistId, name: $0.source.name, parentId: $0.parentPlaylistId,
                               isFolder: $0.source.isFolder, sequenceNo: $0.sequenceNo, contentIds: $0.contentIds)
            },
            keyFormat: keyFormat
        )
        let dbURL = volume.url(forUsbPath: Self.dbRelativePath)
        let rbDir = dbURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: rbDir, withIntermediateDirectories: true)
        let staging = rbDir.appendingPathComponent(".deckhand-staging-exportLibrary.db")
        try? FileManager.default.removeItem(at: staging)
        try OneLibraryDatabase.write(contents, to: staging, previous: dbURL)

        // 5. Validate.
        let issues = try OneLibraryValidator.validate(database: staging, volumeRoot: volume.url)
        if !issues.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            throw OneLibraryError.validation(issues)
        }

        timer.mark("database")
        // 6. Commit: keep a backup of the previous DB, then swap.
        progress(.committing)
        try ensureMounted(volume)
        FileOps.syncFilesystem()
        let backup = rbDir.appendingPathComponent("exportLibrary.db.deckhand-backup")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: dbURL, to: backup)
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        if FileManager.default.fileExists(atPath: dbURL.path) {
            _ = try FileManager.default.replaceItemAt(dbURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: dbURL)
        }

        manifest.lastSyncedAt = Date()
        try manifest.save(to: volume)
        FileOps.syncFilesystem()

        timer.mark("commit")
        // 7. Remove orphaned files Deckhand owns.
        if !plan.removedTracks.isEmpty {
            progress(.removing(count: plan.removedTracks.count))
            for r in plan.removedTracks {
                try? FileManager.default.removeItem(at: volume.url(forUsbPath: r.usbPath))
                try? FileManager.default.removeItem(at: volume.url(forUsbPath: AnlzPath.directory(forAudioPath: r.usbPath)))
            }
        }
        for path in orphanedArt {
            try? FileManager.default.removeItem(at: volume.url(forUsbPath: path))
            try? FileManager.default.removeItem(at: volume.url(forUsbPath: ArtworkWriter.mediumPath(forSmall: path)))
        }
        try? FileManager.default.removeItem(at: backup)
        FileOps.removeAppleDoubleFiles(volumeRoot: volume.url, managedPaths: Self.managedPaths)
        FileOps.syncFilesystem()
        timer.mark("cleanup")
        progress(.done)
    }

    /// Writes each distinct cover once and returns track ID → small-image path, plus image
    /// paths no longer used (deleted after commit).
    private func writeArtwork(_ plan: SyncPlan, manifest: inout Manifest) throws -> ([String: String], [String]) {
        guard let artwork else { return ([:], []) }
        let previous = manifest.artwork ?? [:]
        var used: [String: Int] = [:]
        var next = manifest.nextImageId ?? 1
        var paths: [String: String] = [:]
        for t in plan.tracks {
            guard let data = artwork.artwork(forTrackId: t.source.id) else { continue }
            let hash = ArtworkWriter.hash(data)
            let id = used[hash] ?? previous[hash] ?? {
                defer { next += 1 }
                return next
            }()
            let path = ArtworkWriter.path(imageId: id)
            if used[hash] == nil {
                let small = plan.volume.url(forUsbPath: path)
                let medium = plan.volume.url(forUsbPath: ArtworkWriter.mediumPath(forSmall: path))
                if !FileManager.default.fileExists(atPath: small.path) || !FileManager.default.fileExists(atPath: medium.path) {
                    guard let s = ArtworkWriter.jpeg(data, size: ArtworkWriter.smallSize),
                          let m = ArtworkWriter.jpeg(data, size: ArtworkWriter.mediumSize) else { continue }
                    try ensureMounted(plan.volume)
                    try FileOps.writeAtomically(s, to: small)
                    try FileOps.writeAtomically(m, to: medium)
                }
                used[hash] = id
            }
            paths[t.source.id] = path
        }
        manifest.artwork = used
        manifest.nextImageId = next
        let orphaned = previous.filter { used[$0.key] == nil }.map { ArtworkWriter.path(imageId: $0.value) }
        return (paths, orphaned)
    }

    private func ensureMounted(_ volume: Volume) throws {
        guard FileManager.default.fileExists(atPath: volume.url.path),
              (try? Volume(url: volume.url)) != nil else {
            throw SyncError.volumeDisappeared(volume.name)
        }
    }

    private func writeAnlz(for t: SyncPlan.TrackEntry, analysis: TrackAnalysis, on volume: Volume) throws {
        let totalSamples = UInt64((analysis.durationSeconds * Double(analysis.sampleRate)).rounded())
        let files = AnlzWriter(audioPath: t.usbPath, analysis: analysis, totalSamples: totalSamples, options: anlzOptions).build()
        let dir = volume.url(forUsbPath: AnlzPath.directory(forAudioPath: t.usbPath))
        try FileOps.writeAtomically(files.dat, to: dir.appendingPathComponent("ANLZ0000.DAT"))
        try FileOps.writeAtomically(files.ext, to: dir.appendingPathComponent("ANLZ0000.EXT"))
        try FileOps.writeAtomically(files.twoEx, to: dir.appendingPathComponent("ANLZ0000.2EX"))
    }

    private func exportTrack(_ t: SyncPlan.TrackEntry, analysis: TrackAnalysis?) -> ExportTrack {
        let s = t.source
        let duration = analysis?.durationSeconds ?? s.durationSeconds ?? 0
        let bitrate = duration > 0 ? Int((Double(t.fileSize) * 8 / duration / 1000).rounded()) : 0
        return ExportTrack(
            contentId: t.contentId,
            title: s.title,
            artist: s.artist,
            album: s.album,
            albumArtist: s.albumArtist,
            genre: s.genre,
            trackNumber: s.trackNumber,
            discNumber: s.discNumber,
            year: s.year,
            durationSeconds: duration,
            bpm: analysis?.bpm,
            key: analysis?.key,
            rating: s.rating ?? 0,
            comment: s.comment,
            usbPath: t.usbPath,
            fileSize: Int(t.fileSize),
            fileType: AudioFileType(fileExtension: t.sourceFile.pathExtension) ?? .mp3,
            bitrateKbps: bitrate,
            sampleRate: analysis?.sampleRate ?? 44100,
            dateAdded: s.dateAdded ?? Date(),
            analysisPath: analysis == nil ? nil : AnlzPath.directory(forAudioPath: t.usbPath) + "/ANLZ0000.DAT"
        )
    }
}

/// Prints phase durations to stderr when DECKHAND_TIMING is set.
final class PhaseTimer {
    private var last = Date()
    private let enabled = ProcessInfo.processInfo.environment["DECKHAND_TIMING"] != nil

    func mark(_ phase: String) {
        guard enabled else { return }
        let now = Date()
        FileHandle.standardError.write(Data(String(format: "[timing] %@ %.1fs\n", phase, now.timeIntervalSince(last)).utf8))
        last = now
    }
}
