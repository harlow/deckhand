import Analysis
import DeckhandCore
import Foundation
import MusicSource
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
    /// ANLZ writer options; see AnlzWriter.Options.
    public var anlzOptions = AnlzWriter.Options()
    /// Which imported cues to write as memory and/or hot cues.
    public var cueMode: CueMode = .both
    /// Analyze tracks without cached analysis during sync. When false they're synced without BPM/key
    /// and get them, with full analysis files, on a later sync after `deckhand analyze`.
    public var analyzeMissing = true
    public var hotCueStyle: HotCueStyle = .named
    /// Bars between the "Build" hot cue and the main drop.
    public var buildLeadBars = 8
    /// Write phrase analysis (colored phrase bars on the player).
    public var writePhrases = true
    public var trackColorRule: TrackColorRule = .energy
    /// Cover art source; tracks get no artwork when nil.
    public var artwork: (any ArtworkProvider)?
    /// Rewrite analysis files for all tracks, e.g. after changing anlzOptions.
    public var rewriteAnalysisFiles = false

    static let dbRelativePath = "/PIONEER/rekordbox/exportLibrary.db"

    public init(cache: AnalysisCache, progress: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.cache = cache
        self.progress = progress
    }

    /// Returns false if nothing needed writing (no track, playlist or analysis-file changes).
    @discardableResult
    public func execute(_ plan: SyncPlan, keyFormat: OneLibraryDatabase.KeyFormat = .classic, force: Bool = false) throws -> Bool {
        let volume = plan.volume
        try volume.checkWritable()
        let free = try Volume(url: volume.url).available
        let needed = plan.bytesToCopy + 20 << 20
        if needed > free { throw SyncError.insufficientSpace(needed: needed, available: free) }

        let timer = PhaseTimer()
        // 1. Adopt (move) audio already on the drive, then copy the rest.
        for t in plan.tracks where t.action == .adopt {
            guard let from = t.adoptFrom else { continue }
            try ensureMounted(volume)
            let src = volume.url(forUsbPath: from), dst = volume.url(forUsbPath: t.usbPath)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            do {
                try FileManager.default.moveItem(at: src, to: dst)
            } catch {
                throw SyncError.copyFailed(src.path, error)
            }
        }
        let toCopy = plan.tracks.filter { $0.action == .add || $0.action == .replace }
        for (i, t) in toCopy.enumerated() {
            progress(.copying(index: i + 1, total: toCopy.count, title: t.source.title))
            try ensureMounted(volume)
            let dst = volume.url(forUsbPath: t.usbPath)
            if FileManager.default.fileExists(atPath: dst.path), FileOps.size(dst) == t.fileSize,
               (try? AudioHash.hash(dst)) == t.contentHash {
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
        let runner = AnalysisRunner(cache: cache) { event in
            switch event {
            case .started(let i, let n, let title): progress(.analyzing(index: i, total: n, title: title))
            case .finished(let d, let n, let title): progress(.analyzed(done: d, total: n, title: title))
            case .failed(let title, let error): progress(.analysisFailed(title: title, error: error))
            }
        }
        var analyses = analyzeMissing ? runner.run(plan.tracks.filter(\.needsAnalysis).map {
            .init(url: $0.sourceFile, contentHash: $0.contentHash, title: $0.source.title)
        }) : [:]
        timer.mark("analyze")
        try cache.save()

        var manifest = plan.manifest
        var anlzWritten = 0
        var inputsRecorded = 0
        var summaries: [String: AnalysisCache.Summary] = [:]
        let settingsKey = "\(anlzOptions);\(cueMode);\(hotCueStyle);\(buildLeadBars);\(writePhrases);\(Self.buildId)"
        for (i, t) in plan.tracks.enumerated() {
            progress(.writingAnalysisFiles(index: i + 1, total: plan.tracks.count, title: t.source.title))
            guard let summary = cache.summary(forHash: t.contentHash) else { continue }
            summaries[t.contentHash] = summary
            let datPresent = FileManager.default.fileExists(
                atPath: volume.url(forUsbPath: AnlzPath.directory(forAudioPath: t.usbPath) + "/ANLZ0000.DAT").path)
            // New or changed audio has no recorded fingerprint (the planner drops it), so it's always written.
            let forced = t.needsAnalysis || rewriteAnalysisFiles || !datPresent
            let inputs = "\(summary.revision);\(settingsKey)"
            let previous = manifest.tracks[t.source.id]
            // Same cache entry, settings and build as last time: the fingerprint can't have changed.
            if !forced, previous?.anlzFingerprint != nil, Manifest.matches(previous?.anlzInputs, inputs) { continue }
            guard let a = analyses[t.contentHash] ?? cache.analysis(forHash: t.contentHash) else { continue }
            analyses[t.contentHash] = a
            let sections = cache.sections(forHash: t.contentHash)
            let detected = cache.detectedCues(forHash: t.contentHash)
            let cues = CueBuilder.cues(detected: detected,
                                       analysis: a, mode: cueMode, hotStyle: hotCueStyle,
                                       sections: sections, buildLeadBars: buildLeadBars)
            let phrases = writePhrases ? sections.flatMap { StructureAnalyzer.phrases(sections: $0, analysis: a) } : nil
            let phraseKey = phrases.map { $0.phrases.map { "\($0.beat):\($0.kind)" }.joined(separator: ",") } ?? "-"
            let fingerprint = "v\(a.version);pqt2=\(anlzOptions.includeExtendedBeatGrid);cues=\(CueBuilder.fingerprint(cues));pssi=\(phraseKey)"
            manifest.tracks[t.source.id]?.anlzInputs = Manifest.digest(inputs)
            inputsRecorded += 1
            if !forced && Manifest.matches(previous?.anlzFingerprint, fingerprint) {
                manifest.tracks[t.source.id]?.anlzFingerprint = Manifest.digest(fingerprint)
                continue
            }
            try ensureMounted(volume)
            try writeAnlz(for: t, analysis: a, cues: cues, phrases: phrases, on: volume)
            manifest.tracks[t.source.id]?.anlzFingerprint = Manifest.digest(fingerprint)
            anlzWritten += 1
        }
        // Metadata-only edits (a new rating, a retitled track) still need the database rewritten.
        var metadataChanged = 0
        for t in plan.tracks {
            let f = Self.metadataFingerprint(t.source)
            if !Manifest.matches(manifest.tracks[t.source.id]?.metadataFingerprint, f) { metadataChanged += 1 }
            manifest.tracks[t.source.id]?.metadataFingerprint = Manifest.digest(f)
        }
        if !plan.hasChanges && anlzWritten == 0 && metadataChanged == 0 && !force {
            // Keep what was learned so the next sync skips those checks; the database is unaffected.
            if inputsRecorded > 0 {
                try ensureMounted(volume)
                try manifest.save(to: volume)
            }
            progress(.done)
            return false
        }

        // 4. Build the database in staging.
        timer.mark("anlz files")
        let (artPaths, orphanedArt) = try writeArtwork(plan, manifest: &manifest)
        timer.mark("artwork")
        progress(.writingDatabase)
        let contents = OneLibraryDatabase.Contents(
            tracks: plan.tracks.map {
                let summary = summaries[$0.contentHash]
                var e = exportTrack($0, analysis: summary)
                e.artworkPath = artPaths[$0.source.id]
                e.color = trackColorRule.color(energy: summary?.energy)
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
        // SQLite on a FAT stick flushes per page and takes tens of seconds even for small libraries, so the
        // database is built and validated locally, then written to the drive in one pass.
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: local) }
        // Player history refers to content IDs, which only mean the same tracks if Deckhand wrote the
        // previous database (not, say, a Rekordbox export on a drive being taken over).
        let deckhandWroteDB = plan.manifest.lastSyncedAt != nil
        try OneLibraryDatabase.write(contents, to: local, previous: deckhandWroteDB ? dbURL : nil)
        timer.mark("db build")

        // 5. Validate.
        let issues = try OneLibraryValidator.validate(database: local, volumeRoot: volume.url)
        if !issues.isEmpty { throw OneLibraryError.validation(issues) }
        timer.mark("db validate")

        try ensureMounted(volume)
        let staging = rbDir.appendingPathComponent(".deckhand-staging-exportLibrary.db")
        try FileOps.write(try Data(contentsOf: local), to: staging)
        timer.mark("database")

        // 6. Commit: flush everything written so far, then rename the staged database over the old one.
        progress(.committing)
        FileOps.syncFilesystem()
        timer.mark("commit flush")
        for suffix in ["-wal", "-shm"] { unlink(dbURL.path + suffix) }
        unlink(rbDir.appendingPathComponent("exportLibrary.db.deckhand-backup").path) // left by older versions
        guard rename(staging.path, dbURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: dbURL.path])
        }

        timer.mark("commit swap")
        manifest.lastSyncedAt = Date()
        try manifest.save(to: volume)
        timer.mark("commit manifest")
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
        // Deckhand writes without xattrs, so `._` files can only appear next to files macOS itself touched.
        FileOps.removeAppleDoubleFiles(in: rbDir)
        timer.mark("cleanup")
        progress(.done)
        return true
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
            // Reading and hashing art costs ~200 KB per track, so reuse the hash while neither the audio
            // file nor the track changed. Tracks without art are cheap to ask again.
            let key = Self.artworkKey(t)
            let record = manifest.tracks[t.source.id]
            var data: Data?
            let hash: String
            if record?.artworkKey == key, let h = record?.artworkHash, used[h] != nil || previous[h] != nil {
                hash = h
            } else {
                guard let d = artwork.artwork(forTrackId: t.source.id) else {
                    manifest.tracks[t.source.id]?.artworkHash = nil
                    continue
                }
                data = d
                hash = ArtworkWriter.hash(d)
            }
            let id = used[hash] ?? previous[hash] ?? {
                defer { next += 1 }
                return next
            }()
            let path = ArtworkWriter.path(imageId: id)
            if used[hash] == nil {
                let small = plan.volume.url(forUsbPath: path)
                let medium = plan.volume.url(forUsbPath: ArtworkWriter.mediumPath(forSmall: path))
                // Images are written in place, so only those a completed sync recorded are trusted.
                if previous[hash] != id || !FileManager.default.fileExists(atPath: small.path)
                    || !FileManager.default.fileExists(atPath: medium.path) {
                    guard let data = data ?? artwork.artwork(forTrackId: t.source.id),
                          let s = ArtworkWriter.jpeg(data, size: ArtworkWriter.smallSize),
                          let m = ArtworkWriter.jpeg(data, size: ArtworkWriter.mediumSize) else { continue }
                    try ensureMounted(plan.volume)
                    try FileOps.write(s, to: small)
                    try FileOps.write(m, to: medium)
                }
                used[hash] = id
            }
            manifest.tracks[t.source.id]?.artworkKey = key
            manifest.tracks[t.source.id]?.artworkHash = hash
            paths[t.source.id] = path
        }
        manifest.artwork = used
        manifest.nextImageId = next
        let orphaned = previous.filter { used[$0.key] == nil }.map { ArtworkWriter.path(imageId: $0.value) }
        return (paths, orphaned)
    }

    static func artworkKey(_ t: SyncPlan.TrackEntry) -> String {
        let mtime = FileOps.modificationDate(t.sourceFile)?.timeIntervalSince1970 ?? 0
        return "\(t.contentHash);\(t.fileSize);\(mtime);\(t.source.modifiedDate?.timeIntervalSince1970 ?? 0)"
    }

    private func ensureMounted(_ volume: Volume) throws {
        guard FileManager.default.fileExists(atPath: volume.url.path),
              (try? Volume(url: volume.url)) != nil else {
            throw SyncError.volumeDisappeared(volume.name)
        }
    }

    private func writeAnlz(for t: SyncPlan.TrackEntry, analysis: TrackAnalysis, cues: [CuePoint], phrases: PhraseAnalysis?,
                           on volume: Volume) throws {
        let totalSamples = UInt64((analysis.durationSeconds * Double(analysis.sampleRate)).rounded())
        let files = AnlzWriter(audioPath: t.usbPath, analysis: analysis, totalSamples: totalSamples, cues: cues,
                               phrases: phrases, options: anlzOptions).build()
        let dir = volume.url(forUsbPath: AnlzPath.directory(forAudioPath: t.usbPath))
        try FileOps.write(files.dat, to: dir.appendingPathComponent("ANLZ0000.DAT"))
        try FileOps.write(files.ext, to: dir.appendingPathComponent("ANLZ0000.EXT"))
        try FileOps.write(files.twoEx, to: dir.appendingPathComponent("ANLZ0000.2EX"))
    }

    /// The source fields that end up in the device database (see `exportTrack`).
    public static func metadataFingerprint(_ s: SourceTrack) -> String {
        [s.title, s.artist ?? "", s.album ?? "", s.albumArtist ?? "", s.genre ?? "", s.trackNumber.map(String.init) ?? "",
         s.discNumber.map(String.init) ?? "", s.year.map(String.init) ?? "", String(s.rating ?? 0), s.comment ?? ""]
            .joined(separator: "\u{1F}")
    }

    private func exportTrack(_ t: SyncPlan.TrackEntry, analysis: AnalysisCache.Summary?) -> ExportTrack {
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

extension SyncExecutor {
    /// Changes with every build, so changes to cue or phrase code get ANLZ fingerprints rechecked once.
    static let buildId: String = {
        guard let url = Bundle.main.executableURL else { return "" }
        return "\(FileOps.size(url))-\(FileOps.modificationDate(url)?.timeIntervalSince1970 ?? 0)"
    }()
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
