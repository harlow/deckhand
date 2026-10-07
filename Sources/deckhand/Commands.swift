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

        var executor = SyncExecutor(cache: cache) { event in
            switch event {
            case .copying(let i, let n, let title): print("  copy    [\(i)/\(n)] \(title)")
            case .analyzing(let i, let n, let title): print("  analyze [\(i)/\(n)] \(title)")
            case .analysisFailed(let title, let error): warn("  ! analysis failed for \(title): \(error)")
            case .writingDatabase: print("  writing library database")
            case .committing: print("  committing")
            case .removing(let n): print("  removing \(n) orphaned track(s)")
            case .done: break
            }
        }
        executor.anlzOptions.includeExtendedBeatGrid = extendedBeatgrid
        executor.rewriteAnalysisFiles = rewriteAnalysis
        executor.analysisPolicy = tagOptions.policy
        executor.artwork = lib.artwork
        executor.mixedInKey = tagOptions.mixedInKeyLibrary
        executor.cueMode = cues
        executor.cueSource = cueSource
        let wrote = try executor.execute(plan, keyFormat: keyFormat, force: selectionChanged || rewriteAnalysis)
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
        abstract: "Analyze tracks ahead of time (BPM, beat grid, key, waveforms) so syncs only copy files.",
        discussion: "Results are stored in Deckhand's cache, not in your music files."
    )

    @Option(name: .long, help: "Playlist name or ID (repeatable).") var playlist: [String] = []
    @Flag(help: "Analyze every local track in the Apple Music library.") var all = false
    @OptionGroup var tagOptions: TagOptions

    func validate() throws {
        if playlist.isEmpty && !all { throw ValidationError("Pass --playlist \"<name>\" or --all.") }
    }

    func run() throws {
        let lib = try AppleMusicLibrary.load()
        var ids: [String] = []
        if all {
            var seen = Set<String>()
            ids = lib.playlists.flatMap(\.trackIds).filter { seen.insert($0).inserted }
        } else {
            var seen = Set<String>()
            for name in playlist {
                guard let p = lib.playlist(named: name) else { throw SyncError.playlistNotFound(name) }
                ids += p.trackIds.filter { seen.insert($0).inserted }
            }
        }
        let tracks = ids.compactMap { lib.tracks[$0] }
        let eligible = tracks.filter { SyncPlanner.eligibilityProblem($0) == nil }
        let cache = try AnalysisCache()
        print("Checking \(eligible.count) tracks…")
        let items = try eligible.map {
            AnalysisRunner.Item(url: $0.location!, contentHash: try cache.contentHash(of: $0.location!), title: $0.title)
        }
        let start = Date()
        let runner = AnalysisRunner(cache: cache, policy: tagOptions.policy, mixedInKey: tagOptions.mixedInKeyLibrary) { event in
            switch event {
            case .started(let i, let n, let title): print("  analyze [\(i)/\(n)] \(title)")
            case .failed(let title, let error): warn("  ! \(title): \(error)")
            }
        }
        let results = runner.run(items)
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
