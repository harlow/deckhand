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

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Sync selected playlists to a drive.")

    @Argument(help: "Drive, e.g. /Volumes/DJUSB.") var volume: String
    @Option(name: .long, help: "Playlist name or ID (repeatable). Replaces the drive's saved selection.")
    var playlist: [String] = []
    @Flag(help: "Show what would change without writing anything.") var dryRun = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "List every track change.") var verbose = false
    @Option(help: "Key display on the player: classic (Am) or alphanumeric (8A).")
    var keyFormat: OneLibraryDatabase.KeyFormat = .classic
    @OptionGroup var tagOptions: TagOptions
    @Option(help: "Cues to write: memory, hot (A–H), both, or none.") var cues: CueMode = .both
    @Option(help: "Cue positions: auto (Mixed In Key's if it has the track, else Deckhand's), deckhand, or mik.")
    var cueSource: CueSource = .auto
    @Option(help: "Hot cue pads: named (A Mix In … H Mix Out, from song structure) or phrase (first 8 phrase cues).")
    var hotCues: HotCueStyle = .named
    @Option(help: "Bars between the Build hot cue and the main drop (8, 16 or 32).") var buildLead = 8
    @Option(help: "Track color tag: energy (blue → red) or none.") var trackColor: TrackColorRule = .energy
    @Flag(inversion: .prefixedNo, help: "Write phrase analysis (colored Intro/Build/Breakdown/Drop/Outro bars).")
    var phrases = true
    @Flag(help: .hidden) var extendedBeatgrid = false
    @Flag(help: .hidden) var rewriteAnalysis = false

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        guard let manifest = try Manifest.load(from: v) else { throw SyncError.notInitialized(v.name) }
        if !dryRun { try v.checkWritable() }

        let lib = try AppleMusicLibrary.load()
        var selected = manifest.selectedPlaylistIds
        if !playlist.isEmpty {
            selected = try playlist.map { name in
                guard let p = lib.playlist(named: name) else { throw SyncError.playlistNotFound(name) }
                return p.id
            }
        } else if selected.isEmpty {
            selected = try promptForPlaylists(lib)
        }

        let cache = try AnalysisCache()
        let plan = try SyncPlanner(library: lib, cache: cache, policy: tagOptions.policy)
            .plan(volume: v, selectedPlaylistIds: selected, previous: manifest)
        printPlan(plan)

        if dryRun {
            print("\nNo changes written.")
            return
        }
        let selectionChanged = plan.manifest.selectedPlaylistIds != manifest.selectedPlaylistIds
        if (plan.hasChanges || selectionChanged) && !yes {
            print("\nSync? [Y/n] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer.isEmpty || answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        let bars = SyncProgress()
        var executor = SyncExecutor(cache: cache) { event in bars.handle(event) }
        executor.anlzOptions.includeExtendedBeatGrid = extendedBeatgrid
        executor.rewriteAnalysisFiles = rewriteAnalysis
        executor.analysisPolicy = tagOptions.policy
        executor.artwork = lib.artwork
        executor.mixedInKey = tagOptions.mixedInKeyLibrary
        executor.cueMode = cues
        executor.cueSource = cueSource
        executor.hotCueStyle = hotCues
        executor.buildLeadBars = buildLead
        executor.trackColorRule = trackColor
        executor.writePhrases = phrases
        let wrote = try executor.execute(plan, keyFormat: keyFormat, force: selectionChanged || rewriteAnalysis)
        bars.finish()
        if !wrote {
            print("\nAlready up to date.")
            return
        }
        print("\nDone. \(plan.tracks.count) tracks in \(plan.playlists.filter { !$0.source.isFolder }.count) playlists on \(v.name).")
        print("Run `deckhand eject \(v.url.path)` before unplugging.")
    }

    private func promptForPlaylists(_ lib: SourceLibrary) throws -> [String] {
        let candidates = lib.playlists.filter { !$0.isFolder }
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError("No playlists selected for this drive. Pass --playlist \"<name>\".")
        }
        print("Select playlists to sync (comma-separated numbers):\n")
        for (i, p) in candidates.enumerated() {
            print("  \(String(i + 1).leftPad(3))  \(p.name)  (\(p.trackIds.count))")
        }
        print("\n> ", terminator: "")
        let picks = (readLine() ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let ids = picks.compactMap { $0 >= 1 && $0 <= candidates.count ? candidates[$0 - 1].id : nil }
        guard !ids.isEmpty else { throw ValidationError("No playlists selected.") }
        return ids
    }

    private func printPlan(_ plan: SyncPlan) {
        print("Deckhand — \(plan.volume.name)\n")
        print("PLAYLISTS")
        let symbol: [SyncPlan.PlaylistAction: String] = [.create: "+", .change: "~", .unchanged: "="]
        for p in plan.playlists where !p.source.isFolder {
            print("\(symbol[p.action]!) \(p.source.name)  (\(p.contentIds.count))")
        }
        for p in plan.removedPlaylists { print("- \(p.name)") }

        let add = plan.tracks.filter { $0.action == .add }
        let replace = plan.tracks.filter { $0.action == .replace }
        print("\nTRACKS")
        print("+ \(add.count) new")
        print("- \(plan.removedTracks.count) orphaned")
        print("~ \(replace.count) changed")
        print("= \(plan.tracks.count - add.count - replace.count) unchanged")
        if verbose {
            for t in add { print("  + \(t.source.title)") }
            for t in replace { print("  ~ \(t.source.title)") }
            for t in plan.removedTracks { print("  - \(t.usbPath)") }
        }
        print("\nANALYSIS\n\(plan.analysisCount) tracks need analysis")
        print("\nCOPY\n\(formatBytes(plan.bytesToCopy))")

        if !plan.skipped.isEmpty {
            print("\nCannot sync \(plan.skipped.count) track(s)\n")
            for (playlist, items) in Dictionary(grouping: plan.skipped, by: \.playlist).sorted(by: { $0.key < $1.key }) {
                print(playlist)
                for s in items { print("  ! \(s.track)\n    \(s.reason)") }
            }
        }
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show a drive's sync state.")

    @Argument var volume: String

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        guard let m = try Manifest.load(from: v) else { throw SyncError.notInitialized(v.name) }
        print("\(v.name)  \(v.format)  \(formatBytes(v.available)) free")
        print("Last sync: \(m.lastSyncedAt.map { $0.formatted() } ?? "never")")
        print("Tracks: \(m.tracks.count)   Playlists: \(m.playlists.count)")
        let missing = m.tracks.values.filter { !FileManager.default.fileExists(atPath: v.url(forUsbPath: $0.usbPath).path) }
        if !missing.isEmpty { print("Missing audio files: \(missing.count) (sync again to repair)") }
        if let lib = try? AppleMusicLibrary.load() {
            let names = m.selectedPlaylistIds.map { id in lib.playlists.first { $0.id == id }?.name ?? "(deleted: \(id))" }
            print("Selected playlists: \(names.joined(separator: ", "))")
            if let cache = try? AnalysisCache(),
               let plan = try? SyncPlanner(library: lib, cache: cache).plan(volume: v, selectedPlaylistIds: m.selectedPlaylistIds, previous: m) {
                print(plan.hasChanges ? "Pending changes: yes (run deckhand sync --dry-run for details)" : "Up to date with Apple Music.")
            }
        }
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
extension CueSource: ExpressibleByArgument {}
extension HotCueStyle: ExpressibleByArgument {}
extension TrackColorRule: ExpressibleByArgument {}

/// How existing file tags feed analysis. Shared by `sync` and `analyze`.
struct TagOptions: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Use the file's key tag (e.g. from Mixed In Key) instead of detecting the key.")
    var keyTags = true
    @Flag(inversion: .prefixedNo, help: "Use the file's BPM tag to choose the tempo and pin the beat grid.")
    var bpmHint = true
    @Flag(inversion: .prefixedNo, help: "Use Mixed In Key's stored analysis (tempo, key) when it has the track.")
    var mixedInKey = true

    var policy: AnalysisPolicy { AnalysisPolicy(keyFromTags: keyTags, bpmHintFromTags: bpmHint, useMixedInKey: mixedInKey) }

    /// Loaded only when enabled; nil if MIK isn't installed.
    var mixedInKeyLibrary: MixedInKeyLibrary? { mixedInKey ? MixedInKeyLibrary.load() : nil }
}

struct AnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze tracks ahead of time (BPM, beat grid, key, cues, energy, waveforms) so syncs only copy files.",
        discussion: "Results are stored in Deckhand's cache, not in your music files."
    )

    @Option(name: .long, help: "Playlist name or ID (repeatable).") var playlist: [String] = []
    @Flag(help: "Analyze every song in the Apple Music library, including ones in no playlist.") var all = false
    @OptionGroup var tagOptions: TagOptions

    func validate() throws {
        if playlist.isEmpty && !all { throw ValidationError("Pass --playlist \"<name>\" or --all.") }
    }

    func run() throws {
        var tracks: [SourceTrack] = []
        if all {
            tracks = try AppleMusicLibrary.allSongs()
        } else {
            let lib = try AppleMusicLibrary.load()
            var seen = Set<String>()
            for name in playlist {
                guard let p = lib.playlist(named: name) else { throw SyncError.playlistNotFound(name) }
                tracks += p.trackIds.filter { seen.insert($0).inserted }.compactMap { lib.tracks[$0] }
            }
        }
        let eligible = tracks.filter { SyncPlanner.eligibilityProblem($0) == nil }
        let cache = try AnalysisCache()
        let fingerprinting = ProgressBar("Fingerprinting", total: eligible.count)
        let items = try eligible.map { t -> AnalysisRunner.Item in
            defer { fingerprinting.advance(t.title) }
            return AnalysisRunner.Item(url: t.location!, contentHash: try cache.contentHash(of: t.location!), title: t.title)
        }
        try? cache.saveFingerprints()
        fingerprinting.finish("\(items.count) tracks")
        let start = Date()
        let bar = LockedBox<ProgressBar?>(nil)
        let failures = LockedBox<[String]>([])
        let runner = AnalysisRunner(cache: cache, policy: tagOptions.policy, mixedInKey: tagOptions.mixedInKeyLibrary) { event in
            switch event {
            case .started(_, let n, _): bar.update { if $0 == nil { $0 = ProgressBar("Analyzing     ", total: n) } }
            case .finished(_, _, let title): bar.value?.advance(title)
            case .failed(let title, let error): failures.update { $0.append("\(title): \(error)") }
            }
        }
        let results = runner.run(items)
        bar.value?.finish()
        for f in failures.value { warn("  ! \(f)") }
        let cached = items.count - results.count
        let elapsed = Int(Date().timeIntervalSince(start))
        print("\nAnalyzed \(results.count) tracks in \(elapsed)s; \(cached) already up to date.")
        if !results.isEmpty {
            let keyTags = results.values.filter { $0.keySource == .fileTag }.count
            let bpmHints = results.values.filter { $0.bpmSource == .analysisWithTagHint }.count
            print("Key from file tags: \(keyTags)   BPM guided by file tags: \(bpmHints)")
        }
        let skipped = tracks.count - eligible.count
        if skipped > 0 { print("\(skipped) tracks skipped (no local file, DRM, or unsupported format).") }
    }
}

struct ImportPlaylistsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-playlists",
        abstract: "Recreate a drive's existing playlists (e.g. from Rekordbox) in Apple Music.",
        discussion: "Tracks are matched to songs already in your Apple Music library; nothing is copied or added to the library itself."
    )

    @Argument(help: "Drive, e.g. /Volumes/RATS.") var volume: String
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
        case .writingDatabase:
            finishCopy()
            analyze.value?.finish()
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
    }

    private func finishCopy() {
        guard let bar = copy.value else { return }
        bar.advance()
        bar.finish()
        copy.update { $0 = nil }
    }
}
