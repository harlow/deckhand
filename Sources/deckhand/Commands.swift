import ArgumentParser
import DeckhandCore
import Foundation
import MusicSource
import OneLibrary
import Sync

struct PlaylistsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "playlists", abstract: "List Apple Music playlists.")

    @Flag(help: "Output JSON.") var json = false

    func run() throws {
        let lib = try AppleMusicLibrary.load()
        if json {
            try printJSON(lib.playlists.map {
                ["id": $0.id, "name": $0.name, "parentId": $0.parentId ?? "", "folder": $0.isFolder ? "true" : "false",
                 "tracks": String($0.trackIds.count)]
            })
            return
        }
        print("APPLE MUSIC PLAYLISTS\n")
        print("ID                  TRACKS  NAME")
        let byId = Dictionary(uniqueKeysWithValues: lib.playlists.map { ($0.id, $0) })
        for p in lib.playlists {
            var depth = 0
            var cur = p.parentId
            while let c = cur, let parent = byId[c] { depth += 1; cur = parent.parentId }
            let indent = String(repeating: "  ", count: depth)
            let count = p.isFolder ? "" : String(p.trackIds.count)
            print("\(p.id)  \(count.leftPad(6))  \(indent)\(p.isFolder ? "▸ " : "")\(p.name)")
        }
    }
}

struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "List mounted removable drives.")

    func run() throws {
        let volumes = Volume.removable()
        if volumes.isEmpty {
            print("No removable drives found. Plug in a USB drive and try again.")
            return
        }
        for v in volumes {
            let managed = (try? Manifest.load(from: v)) != nil ? "Deckhand" : "—"
            let fmt = v.formatIsSupported ? v.format : "\(v.format) (not readable by DJ players)"
            print("\(v.url.path)  \(fmt)  \(formatBytes(v.available)) free of \(formatBytes(v.capacity))  \(managed)")
        }
    }
}

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Mark a USB drive as Deckhand-managed. Never formats the drive."
    )

    @Argument(help: "Drive, e.g. /Volumes/DJUSB.") var volume: String

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        try v.checkWritable()
        if !v.formatIsSupported {
            warn("""
            Warning: \(v.name) is formatted as \(v.format). Pioneer/AlphaTheta players need FAT32 or exFAT.
            Deckhand does not format drives. To reformat (ERASES EVERYTHING on the drive), use Disk Utility,
            or: diskutil eraseDisk FAT32 DJUSB MBRFormat <disk identifier>
            """)
            throw ExitCode.failure
        }
        if try Manifest.load(from: v) != nil {
            print("\(v.name) is already a Deckhand drive.")
            return
        }
        let existing = FileManager.default.fileExists(atPath: v.url(forUsbPath: "/PIONEER/rekordbox").path)
        if existing {
            print("Note: \(v.name) has an existing Rekordbox library. Deckhand will replace exportLibrary.db on first sync;")
            print("other files are left untouched.")
        }
        try Manifest().save(to: v)
        print("Initialized \(v.name) as a Deckhand drive.")
        print("Next: deckhand sync \(v.url.path) --playlist \"<name>\"")
    }
}

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate", abstract: "Check a drive's library for problems.")

    @Argument var volume: String

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        let db = v.url(forUsbPath: "/PIONEER/rekordbox/exportLibrary.db")
        let issues = try OneLibraryValidator.validate(database: db, volumeRoot: v.url)
        if issues.isEmpty {
            print("OK — no problems found on \(v.name).")
        } else {
            print("\(issues.count) problem(s) on \(v.name):")
            for i in issues { print("  - \(i)") }
            throw ExitCode.failure
        }
    }
}

struct EjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "eject", abstract: "Flush writes and safely eject a drive.")

    @Argument var volume: String

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        sync()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["eject", v.url.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
    }
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

extension OneLibraryDatabase.KeyFormat: ExpressibleByArgument {}
extension CueMode: ExpressibleByArgument {}
extension HotCueStyle: ExpressibleByArgument {}
extension TrackColorRule: ExpressibleByArgument {}

struct AnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze tracks ahead of time (BPM, beat grid, key, cues, energy, waveforms) so syncs only copy files.",
        discussion: "Results are stored in Deckhand's cache, not in your music files."
    )

    @Option(name: .long, help: "Only these playlists (repeatable). Default: the whole Apple Music library.")
    var playlist: [String] = []
    @Flag(help: "Try again on tracks the analyzer failed on before (otherwise skipped until Deckhand's analyzer changes).")
    var retryFailed = false
    @Flag(help: .hidden) var all = false

    func run() throws {
        var tracks: [SourceTrack] = []
        if playlist.isEmpty {
            tracks = try AppleMusicLibrary.allSongs()
        } else {
            let lib = try AppleMusicLibrary.load()
            var seen = Set<String>()
            for name in playlist {
                guard let p = lib.playlist(named: name) else { throw SyncError.playlistNotFound(name) }
                tracks += p.trackIds.filter { seen.insert($0).inserted }.compactMap { lib.tracks[$0] }
            }
        }
        let eligible = tracks.filter { SyncPlanner.unavailableReason($0) == nil }
        let cache = try AnalysisCache()
        let fingerprinting = ProgressBar("Fingerprinting", total: eligible.count)
        let items = try eligible.map { t -> AnalysisRunner.Item in
            defer { fingerprinting.advance(t.title) }
            return AnalysisRunner.Item(url: t.location!, contentHash: try cache.contentHash(of: t.location!), title: t.title)
        }
        try? cache.save()
        fingerprinting.finish("\(items.count) tracks")
        let start = Date()
        let bar = LockedBox<ProgressBar?>(nil)
        let failures = LockedBox<[String]>([])
        let runner = AnalysisRunner(cache: cache) { event in
            switch event {
            case .started(_, let n, _): bar.update { if $0 == nil { $0 = ProgressBar("Analyzing     ", total: n) } }
            case .finished(_, _, let title): bar.value?.advance(title)
            case .failed(let title, let error): failures.update { $0.append("\(title): \(error)") }
            }
        }
        let cached = Set(items.filter { cache.isAnalyzed($0.contentHash) }.map(\.contentHash)).count
        let previouslyFailed = retryFailed ? 0 : Set(items.filter {
            !cache.isAnalyzed($0.contentHash) && cache.analysisFailure(forHash: $0.contentHash) != nil
        }.map(\.contentHash)).count
        let results = runner.run(items, retryFailed: retryFailed)
        bar.value?.finish()
        for f in failures.value { warn("  ! \(f)") }
        let elapsed = Int(Date().timeIntervalSince(start))
        print("\nAnalyzed \(results.count) tracks in \(elapsed)s; \(cached) already up to date.")
        if previouslyFailed > 0 {
            print("\(previouslyFailed) tracks the analyzer failed on before were skipped (--retry-failed tries them again).")
        }
        let skipped = tracks.count - eligible.count
        if skipped > 0 { print("\(skipped) tracks skipped (no local file, DRM, or unsupported format).") }
    }
}

struct ImportPlaylistsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-playlists",
        abstract: "Recreate a drive's existing playlists (e.g. from Rekordbox) in Apple Music.",
        discussion: "Tracks are matched to songs already in your Apple Music library; with --add-missing, tracks that aren't found are copied to ~/Music/Deckhand Imports and added."
    )

    @Argument(help: "Drive, e.g. /Volumes/DJUSB.") var volume: String
    @Option(name: .long, help: "Only these playlists (repeatable). Default: all that don't exist in Apple Music.")
    var playlist: [String] = []
    @Flag(help: "Also import playlists whose name already exists in Apple Music (creates a second playlist).")
    var includeExisting = false
    @Flag(help: "Also add drive tracks that aren't in Apple Music (copied to ~/Music/Deckhand Imports first).")
    var addMissing = false
    @Flag(help: "Show the plan without changing Apple Music.") var dryRun = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    /// Deletes `dir` and its subfolders only where they contain no files (staged files Music
    /// references in place must survive).
    private func removeEmptyFolders(_ dir: URL) {
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            removeEmptyFolders(sub)
        }
        let remaining = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
        if remaining.isEmpty { try? fm.removeItem(at: dir) }
    }

    /// Formats Music.app can import.
    static let importable: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "mp4"]

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        let device = try DeviceLibrary.read(database: v.url(forUsbPath: "/PIONEER/rekordbox/exportLibrary.db"))
        let library = try AppleMusicLibrary.load()
        let existing = Dictionary(library.playlists.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let importer = PlaylistImporter(volume: v, device: device, songs: try AppleMusicLibrary.allSongs(), cache: try AnalysisCache())

        print("Matching \(v.name)'s tracks to Apple Music…")
        let plan = try importer.plan(existingNames: Set(existing.keys), only: playlist.isEmpty ? nil : Set(playlist),
                                     includeAllTracks: addMissing)
        let methods = plan.methods.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", ")
        print("Matched by: \(methods.isEmpty ? "—" : methods)\n")

        let toCreate = plan.playlists.filter { $0.source.isFolder || includeExisting || !$0.existsInAppleMusic }
        print("PLAYLIST                     TRACKS  MATCHED  ACTION")
        for p in plan.playlists {
            let action = toCreate.contains { $0.source.playlistId == p.source.playlistId }
                ? (p.source.isFolder ? "create folder" : "create")
                : "skip (exists in Apple Music)"
            let name = p.source.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            print("\(name) \(String(p.source.contentIds.count).leftPad(6))  \(String(p.trackIds.count).leftPad(7))  \(action)")
        }
        let unmatched = addMissing ? plan.missing : toCreate.flatMap(\.unmatched)
        let toAdd = addMissing ? plan.missing.filter { Self.importable.contains(($0.usbPath as NSString).pathExtension.lowercased()) } : []
        if !unmatched.isEmpty {
            let bytes = Int64(toAdd.reduce(0) { $0 + $1.fileSize })
            print("\nNot in Apple Music (\(unmatched.count))\(addMissing ? ", \(toAdd.count) will be added (\(formatBytes(bytes)))" : ""):")
            for t in unmatched.prefix(30) {
                let skip = addMissing && !toAdd.contains { $0.contentId == t.contentId } ? "  [format Music can't import]" : ""
                print("  \(addMissing ? "+" : "!") \(t.artist) — \(t.title)\(skip)")
            }
            if unmatched.count > 30 { print("  … and \(unmatched.count - 30) more") }
            if !addMissing { print("  (use --add-missing to add them to Apple Music)") }
        }
        guard !toCreate.filter({ !$0.source.isFolder }).isEmpty || !toAdd.isEmpty else {
            print("\nNothing to import.")
            return
        }
        if dryRun {
            print("\nDry run: Apple Music not changed.")
            return
        }
        if !yes {
            print("\nUpdate Apple Music as shown? [y/N] ", terminator: "")
            guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { print("Cancelled."); return }
        }

        var added: [Int: String] = [:]
        if !toAdd.isEmpty {
            let staging = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Deckhand Imports")
            for (i, t) in toAdd.enumerated() {
                let src = v.url(forUsbPath: t.usbPath)
                let folder = SyncPlanner.sanitize(t.artist.isEmpty ? "Unknown Artist" : t.artist)
                let dst = staging.appendingPathComponent(folder).appendingPathComponent(src.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: src, to: dst) }
                    let result = try AppleMusicWriter.addFile(dst, title: t.title, artist: t.artist, album: t.album, genre: t.genre)
                    added[t.contentId] = result.id
                    // If Music copied the file into its media folder, the staging copy is redundant.
                    if URL(fileURLWithPath: result.location).standardizedFileURL != dst.standardizedFileURL {
                        try? FileManager.default.removeItem(at: dst)
                    }
                    print("  added [\(i + 1)/\(toAdd.count)] \(t.artist) — \(t.title)")
                } catch {
                    warn("  ! could not add \(t.title): \(error)")
                }
            }
            removeEmptyFolders(staging)
        }

        var created: [Int: String] = [:]
        let resolved = Dictionary(uniqueKeysWithValues: PlaylistImporter.resolve(plan, added: added).map { ($0.source.playlistId, $0) })
        for p in toCreate.map({ resolved[$0.source.playlistId] ?? $0 }) {
            let parent = p.source.parentId.flatMap { created[$0] }
            if p.source.isFolder, let folder = existing[p.source.name], folder.isFolder {
                created[p.source.playlistId] = folder.id
                continue
            }
            let id = try AppleMusicWriter.createPlaylist(named: p.source.name, isFolder: p.source.isFolder, inFolder: parent)
            created[p.source.playlistId] = id
            if !p.source.isFolder {
                let missing = try AppleMusicWriter.add(trackIds: p.trackIds, toPlaylist: id)
                print("  created \(p.source.name) (\(p.trackIds.count - missing.count) tracks)")
                if !missing.isEmpty { warn("  ! \(missing.count) tracks could not be added") }
            }
        }
        print("\nDone. The new playlists are in Music.app; sync them with `deckhand sync <drive> --playlist \"<name>\"`.")
    }
}

/// Mutable value shared with progress callbacks running on worker threads.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T { lock.withLock { stored } }

    func update(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

/// Progress bars for `sync`: one per phase, plain lines for the rest.
final class SyncProgress: @unchecked Sendable {
    private let copy = LockedBox<ProgressBar?>(nil)
    private let analyze = LockedBox<ProgressBar?>(nil)
    private let anlz = LockedBox<ProgressBar?>(nil)
    private let failures = LockedBox<[String]>([])

    func handle(_ event: SyncExecutor.Event) {
        switch event {
        case .copying(let i, let n, let title):
            copy.update { if $0 == nil { $0 = ProgressBar("Copying       ", total: n) } }
            if i > 1 { copy.value?.advance(title) }
        case .analyzing(_, let n, _):
            finishCopy()
            analyze.update { if $0 == nil { $0 = ProgressBar("Analyzing     ", total: n) } }
        case .analyzed(_, _, let title): analyze.value?.advance(title)
        case .analysisFailed(let title, let error): failures.update { $0.append("\(title): \(error)") }
        case .writingAnalysisFiles(_, let n, let title):
            finishCopy()
            analyze.value?.finish()
            anlz.update { if $0 == nil { $0 = ProgressBar("Analysis files", total: n) } }
            anlz.value?.advance(title)
        case .writingDatabase:
            finishCopy()
            analyze.value?.finish()
            anlz.value?.finish()
            for f in failures.value { warn("  ! analysis failed for \(f)") }
            failures.update { $0.removeAll() }
            print("  writing library database")
        case .committing: print("  committing")
        case .removing(let n): print("  removing \(n) orphaned track(s)")
        case .done: break
        }
    }

    func finish() {
        finishCopy()
        analyze.value?.finish()
        anlz.value?.finish()
    }

    private func finishCopy() {
        guard let bar = copy.value else { return }
        bar.advance()
        bar.finish()
        copy.update { $0 = nil }
    }
}

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove leftovers from other tools (e.g. a Rekordbox export) that nothing on the drive uses.",
        discussion: """
            Only considers audio under /Contents, analysis and artwork under /PIONEER, and Rekordbox's legacy \
            database files. Never touches Deckhand's files, player settings, or any other folders on the drive.
            """
    )

    @Argument var volume: String
    @Flag(help: "List what would be removed without deleting.") var dryRun = false
    @Flag(help: "Keep Rekordbox's export.pdb (older CDJs such as the CDJ-3000 read it instead of OneLibrary).")
    var keepLegacy = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        guard let manifest = try Manifest.load(from: v), manifest.lastSyncedAt != nil, !manifest.tracks.isEmpty else {
            throw ValidationError("Sync \(v.name) with Deckhand first; cleanup relies on knowing which files Deckhand uses.")
        }
        var cleanup = try DriveCleanup.scan(v, manifest: manifest)
        if keepLegacy { cleanup.items.removeAll { $0.category == .legacyDatabase } }
        guard !cleanup.items.isEmpty else {
            print("Nothing to clean up on \(v.name).")
            return
        }
        print("Leftovers on \(v.name):\n")
        for category in DriveCleanup.Category.allCases {
            let items = cleanup.items.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let bytes = items.reduce(0) { $0 + $1.bytes }
            print("  \(category.rawValue): \(items.count)\(bytes > 0 ? " (\(formatBytes(bytes)))" : "")")
            if category == .audio || category == .legacyDatabase {
                for i in items.prefix(10) { print("      \(i.path)") }
                if items.count > 10 { print("      … and \(items.count - 10) more") }
            }
        }
        print("\nTotal: \(formatBytes(cleanup.bytes)) would be freed.")
        if dryRun {
            print("Dry run: nothing deleted.")
            return
        }
        if !yes {
            print("\nDelete these from \(v.name)? This can't be undone. [y/N] ", terminator: "")
            guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { print("Cancelled."); return }
        }
        let failed = cleanup.apply(v)
        print(failed.isEmpty ? "Removed." : "Removed, except \(failed.count) item(s) that couldn't be deleted.")
    }
}

struct RatingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ratings",
        abstract: "Back up or restore Apple Music star ratings (Music keeps them only in its library, not the files).",
        subcommands: [Backup.self, Restore.self]
    )

    struct Backup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save every rating to ~/Library/Application Support/Deckhand/Ratings.")

        func run() throws {
            let lib = try AppleMusicLibrary.load(allSongs: true)
            let backup = RatingsBackup(tracks: lib.tracks.values)
            if let url = try backup.save() {
                print("Saved \(backup.entries.count) ratings to \(url.path)")
            } else {
                print("\(backup.entries.count) ratings; unchanged since the last backup.")
            }
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put ratings from a backup back into Apple Music.",
            discussion: "By default only unrated tracks are filled in; ratings you've changed since are kept."
        )

        @Argument(help: "Backup file (default: the latest backup).")
        var file: String?

        @Flag(help: "Also replace ratings that differ from the backup.")
        var overwrite = false

        @Flag(help: "Show what would change without changing anything.")
        var dryRun = false

        func run() throws {
            guard let url = file.map({ URL(fileURLWithPath: $0) }) ?? RatingsBackup.latest() else {
                throw ValidationError("No backup found in \(RatingsBackup.directory.path)")
            }
            let backup = try RatingsBackup.load(from: url)
            let lib = try AppleMusicLibrary.load(allSongs: true)
            let changes = backup.changes(for: Array(lib.tracks.values), overwrite: overwrite)
            print("Backup from \(backup.savedAt.formatted()): \(backup.entries.count) ratings; \(changes.count) to restore.")
            for c in changes.prefix(30) {
                print("  \(c.title): \(c.from == 0 ? "unrated" : String(repeating: "★", count: c.from)) → \(String(repeating: "★", count: c.to))")
            }
            if changes.count > 30 { print("  … and \(changes.count - 30) more") }
            guard !dryRun, !changes.isEmpty else { return }
            for (stars, group) in Dictionary(grouping: changes, by: \.to) {
                try AppleMusicWriter.setRating(stars, trackIds: group.map(\.trackId))
            }
            print("Restored \(changes.count) ratings.")
        }
    }
}
