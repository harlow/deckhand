import ArgumentParser
import DeckhandCore
import DeckhandLibrary
import Foundation
import MusicSource
import OneLibrary
import Sync

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Sync selected playlists to a drive.")

    @Argument(help: "Drive, e.g. /Volumes/DJUSB.") var volume: String
    @Option(name: .long, help: "Playlist name or ID (repeatable). Replaces the drive's saved selection.")
    var playlist: [String] = []
    @Flag(inversion: .prefixedNo, help: "Put every song on the drive, not just those in the chosen playlists (playlists are still the ones you choose). Remembered per drive.")
    var entireLibrary: Bool?
    @Flag(help: "Take over audio already on the drive (e.g. from a Rekordbox export) instead of copying it again.")
    var adopt = false
    @Flag(help: "Show what would change without writing anything.") var dryRun = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "List every track change.") var verbose = false
    // Output settings below are remembered per drive: pass one to change it, omit it to keep the
    // drive's saved value (or the default).
    @Option(help: "Key display on the player: classic (Am) or alphanumeric (8A). Default classic.")
    var keyFormat: OneLibraryDatabase.KeyFormat?
    @Option(help: "Cues to write: memory, hot (A–H), both, or none. Default both.") var cues: CueMode?
    @Option(help: "Hot cue pads: named (A Mix In … H Mix Out, from song structure) or phrase (first 8 phrase cues). Default named.")
    var hotCues: HotCueStyle?
    @Option(help: "Bars between the Build hot cue and the main drop (8, 16 or 32). Default 8.") var buildLead: Int?
    @Option(help: "Track color tag: energy (blue → red) or none. Default energy.") var trackColor: TrackColorRule?
    @Flag(inversion: .prefixedNo, help: "Write phrase analysis (colored Intro/Build/Breakdown/Drop/Outro bars). Default on.")
    var phrases: Bool?
    @Flag(inversion: .prefixedNo, help: "Analyze tracks that aren't analyzed yet. Without either flag, sync asks (or skips with -y).")
    var analyze: Bool?
    @Flag(help: "Try again on tracks the analyzer failed on before.") var retryFailed = false
    @Flag(help: .hidden) var extendedBeatgrid = false
    @Flag(help: .hidden) var rewriteAnalysis = false
    @Flag(help: "Stop without writing if Music is running but its current data can't be read (the library snapshot can trail recent edits). Never shows the Automation prompt.")
    var requireLive = false
    @Option(name: .long, help: "Use a normalized Deckhand library snapshot JSON.")
    var sourceLibrary: String?
    @Flag(help: "Use Apple Music directly instead of the saved Deckhand library.") var music = false

    func run() throws {
        let timer = PhaseTimer()
        let v = try Volume(url: URL(fileURLWithPath: volume))
        guard var manifest = try Manifest.load(from: v) else { throw SyncError.notInitialized(v.name) }
        if manifest.format > Manifest.currentFormat { throw SyncError.newerManifest(manifest.format) }
        if !dryRun { try v.checkWritable() }
        timer.mark("open drive")

        let wholeLibrary = entireLibrary ?? (manifest.entireLibrary == true)
        var lib = try loadLibrary(allSongs: wholeLibrary, requireLive: requireLive, snapshot: sourceLibrary, music: music)
        guard manifest.acceptsSource(lib.sourceID) else { throw SyncError.sourceMismatch }
        if lib.sourceID == nil && lib.playlists.isEmpty && lib.tracks.isEmpty && !manifest.tracks.isEmpty {
            throw ValidationError("Apple Music returned an empty library, so nothing on \(v.name) was changed. Check that Music "
                                  + "has its library and Deckhand may read it (System Settings → Privacy & Security → Media & Apple Music).")
        }
        // nil: the drive's saved selection, read again if it changes before the sync starts writing.
        var selection: Selection?
        if !playlist.isEmpty {
            let ids = try playlist.map { name in
                guard let p = lib.playlist(named: name) else { throw SyncError.playlistNotFound(name) }
                return p.id
            }
            selection = Selection(playlistIds: ids, entireLibrary: wholeLibrary)
        } else if manifest.selectedPlaylistIds.isEmpty && !wholeLibrary {
            selection = Selection(playlistIds: try promptForPlaylists(lib), entireLibrary: false)
        } else if let entireLibrary {
            selection = Selection(playlistIds: manifest.selectedPlaylistIds, entireLibrary: entireLibrary)
        }
        timer.mark("load library")

        let cache = try AnalysisCache()
        timer.mark("open cache")
        var adoptable: [String: String] = [:]
        if adopt {
            let bar = LockedBox<ProgressBar?>(nil)
            adoptable = AdoptScanner.scan(v, owned: Set(manifest.tracks.values.map(\.usbPath)), cache: cache) { i, n, name in
                bar.update { if $0 == nil { $0 = ProgressBar("Scanning drive", total: n) } }
                bar.value?.advance(name)
            }
            bar.value?.finish("\(adoptable.count) existing tracks found")
        }
        let settings = OutputSettings(saved: manifest.settings, keyFormat: keyFormat, cues: cues, hotCues: hotCues,
                                      buildLead: buildLead, trackColor: trackColor, phrases: phrases)
        var profile = OutputProfile(settings: settings)
        profile.anlzOptions.includeExtendedBeatGrid = extendedBeatgrid
        profile.rewriteAnalysisFiles = rewriteAnalysis
        profile.artwork = lib.artwork != nil
        profile.analyzeMissing = analyze ?? true
        var planner = SyncPlanner(library: lib, cache: cache)
        var changes = planner.plan(volume: v, manifest: manifest, profile: profile, selection: selection, adoptable: adoptable,
                                   retryFailedAnalysis: retryFailed)
        timer.mark("plan")
        printChanges(changes, volume: v, verbose: verbose)

        if dryRun {
            print("\nNo changes written.")
            return
        }
        if changes.isClean {
            print("\nAlready up to date.")
            printResult(generation: manifest.generationNumber, after: changes, result: SyncResult())
            return
        }
        let toAnalyze = changes.summary.toAnalyze
        if toAnalyze > 0, analyze == nil {
            let minutes = max(1, Int((Double(toAnalyze) * 4.0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount - 2)) / 60).rounded(.up)))
            var analyzeNow = false
            if !yes && isatty(STDIN_FILENO) != 0 {
                print("\n\(toAnalyze) track(s) aren't analyzed yet (about \(minutes) min). Analyze them now? [Y/n] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                analyzeNow = answer.isEmpty || answer == "y" || answer == "yes"
            } else {
                print("\n\(toAnalyze) track(s) aren't analyzed yet; they'll sync without BPM, key or cues. Run `deckhand analyze`, then sync again.")
            }
            if !analyzeNow {
                profile.analyzeMissing = false
                changes = planner.plan(volume: v, manifest: manifest, profile: profile, selection: selection, adoptable: adoptable,
                                       retryFailedAnalysis: retryFailed)
            }
        }
        if changes.drive.contains(.settings) { print("\nSettings: \(settings.summary)") }
        let adopting = changes.tracks.filter { $0.changes.contains(.adopt) }.count
        if adopting > 0 && !yes {
            print("\n\(adopting) audio files already on \(v.name) will be taken over by Deckhand (moved, not copied).")
            print("Other files on the drive are left alone.")
        }
        if !yes {
            print("\nSync? [Y/n] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer.isEmpty || answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        // Writing starts: hold the drive's lock, and plan again if the manifest changed since it was read (the app
        // saves selection edits there).
        let lock = try SyncLock.acquire(on: v)
        defer { lock.release() }
        if let current = try Manifest.load(from: v), current.generationNumber != manifest.generationNumber {
            manifest = current
            guard current.acceptsSource(lib.sourceID) else { throw SyncError.sourceMismatch }
            if selection?.entireLibrary ?? (current.entireLibrary == true), lib.allTrackIds == nil {
                lib = try loadLibrary(allSongs: true, requireLive: requireLive, snapshot: sourceLibrary, music: music)
                planner = SyncPlanner(library: lib, cache: cache)
            }
            changes = planner.plan(volume: v, manifest: current, profile: profile, selection: selection, adoptable: adoptable,
                                   retryFailedAnalysis: retryFailed)
            print("\nThe drive's selection changed meanwhile; planned again.")
        }

        let bars = SyncProgress()
        var executor = SyncExecutor(cache: cache) { event in bars.handle(event) }
        executor.artwork = lib.artwork
        executor.retryFailedAnalysis = retryFailed
        let result = try executor.execute(changes, on: v)
        bars.finish()
        timer.mark("sync")

        // Self-check: read everything again; a sync that did its job leaves nothing to do.
        print("  checking USB")
        let after = try planner.verify(volume: v, profile: profile)
        timer.mark("verify")
        let onDrive = after.tracks.filter(\.isOnDrive).count
        let lists = after.playlists.filter { !$0.source.isFolder }.count
        print("\nDone. \(onDrive) track\(onDrive == 1 ? "" : "s") in \(lists) playlist\(lists == 1 ? "" : "s") on \(v.name).")
        if !result.analysisFailed.isEmpty {
            print("Analysis failed for \(result.analysisFailed.count) track(s); they're on the drive without BPM, key or cues.")
        }
        if result.keptConcurrentEdits { print("The drive's selection was edited during the sync; that edit is kept for the next sync.") }
        if !after.isClean {
            // "!" lines aren't taken for progress steps by the app.
            warn("Warning: \(v.name) still isn't up to date after syncing:")
            for line in pendingLines(after, limit: 20) { warn("  ! \(line)") }
        }
        print("Run `deckhand eject \(v.url.path)` before unplugging.")
        printResult(generation: result.manifest?.generationNumber ?? manifest.generationNumber, after: after, result: result)
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

    /// One machine-readable line for the app: `@result {...}`.
    private func printResult(generation: Int, after: ChangeSet, result: SyncResult) {
        struct Line: Encodable {
            var generation: Int
            var clean: Bool
            var pending: Int
            var tracks: Int
            var copied: Int
            var analyzed: Int
            var analysisFailed: Int
            var removed: Int
            var wroteDatabase: Bool
            var summary: ChangeSet.Summary
        }
        let line = Line(generation: generation, clean: after.isClean, pending: after.summary.total,
                        tracks: after.tracks.filter(\.isOnDrive).count, copied: result.copied.count,
                        analyzed: result.analyzed.count, analysisFailed: result.analysisFailed.count,
                        removed: result.removed.count, wroteDatabase: result.wroteDatabase, summary: after.summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(line) { print("@result " + String(decoding: data, as: UTF8.self)) }
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show what a sync would change on a drive (reads the drive, never writes it).")

    @Argument var volume: String
    @Flag(help: "Output JSON.") var json = false
    @Flag(help: "List every pending track.") var verbose = false
    @Option(name: .long, help: "Use a normalized Deckhand library snapshot JSON.")
    var sourceLibrary: String?
    @Flag(help: "Use Apple Music directly instead of the saved Deckhand library.") var music = false

    func run() throws {
        let v = try Volume(url: URL(fileURLWithPath: volume))
        guard let m = try Manifest.load(from: v) else { throw SyncError.notInitialized(v.name) }
        let lib = try loadLibrary(allSongs: m.entireLibrary == true, requireLive: false, snapshot: sourceLibrary, music: music)
        guard m.acceptsSource(lib.sourceID) else { throw SyncError.sourceMismatch }
        var profile = OutputProfile(settings: OutputSettings(saved: m.settings))
        profile.artwork = lib.artwork != nil
        let changes = SyncPlanner(library: lib, cache: try AnalysisCache()).plan(volume: v, manifest: m, profile: profile)
        if json {
            try printJSON(StatusReport(changes, volume: v))
            return
        }
        print("\(v.name)  \(v.format)  \(formatBytes(v.available)) free")
        print("Last sync: \(m.lastSyncedAt.map { $0.formatted() } ?? "never")  (manifest generation \(m.generationNumber))")
        if m.format > Manifest.currentFormat { print("Written by a newer Deckhand (format \(m.format)); this version won't sync it.") }
        let names = changes.scope.playlistIds.compactMap { id in lib.playlists.first { $0.id == id }?.name }
        print("Selected: \(m.entireLibrary == true ? "every song; playlists " : "")\(names.isEmpty ? "none" : names.joined(separator: ", "))")
        let s = changes.summary
        let folders = Set(lib.playlists.filter(\.isFolder).map(\.id))
        print("On the drive: \(m.tracks.count) track(s), \(m.playlists.keys.filter { !folders.contains($0) }.count) playlist(s)")
        if changes.isClean {
            print("Up to date with the source library.")
        } else {
            print("\(s.total) change(s) pending (run `deckhand sync \(v.url.path) --dry-run` for details):")
            for line in pendingLines(changes, limit: verbose ? .max : 0) { print("  \(line)") }
        }
        for line in noteLines(changes) { print(line) }
        if changes.scope.unreadable { print("Apple Music returned an empty library; nothing can be judged.") }
        if !changes.isComplete { print("Some facts are unknown; status is incomplete.") }
    }
}

/// The Apple Music library with every field the database uses read live from Music (see `MusicLive`). If Music is
/// running but can't be read, warns and uses the snapshot, or with `requireLive` prints a machine-readable
/// `@live {...}` line for the app and stops (exit status 3) before anything is written.
func loadLibrary(allSongs: Bool, requireLive: Bool, snapshot: String? = nil, music: Bool = false) throws -> SourceLibrary {
    if let snapshot { return try LibrarySnapshot.load(at: URL(fileURLWithPath: snapshot)) }
    if !music, let lib = try DeckhandLibraryStore.savedLibrary() { return lib }
    let (lib, status) = try AppleMusicLibrary.loadLive(allSongs: allSongs, prompt: !requireLive)
    guard case .unavailable(let failure) = status else { return lib }
    if requireLive {
        struct Line: Encodable { var live: Bool; var status: Int32; var reason: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Line(live: false, status: failure.status, reason: failure.description))
        print("@live " + String(decoding: data, as: UTF8.self))
        warn("Couldn't read current data from Music (\(failure)), so nothing was written: the library snapshot can trail "
             + "recent edits. Run without --require-live to sync from the snapshot anyway.")
        throw ExitCode(3)
    }
    warn("Warning: couldn't read current data from Music (\(failure)); using the library snapshot, which can trail recent edits.")
    return lib
}

extension ChangeSet.Track {
    /// On the drive after a sync (retained tracks included).
    var isOnDrive: Bool {
        switch status {
        case .ineligible, .unknown: false
        default: usbPath != nil
        }
    }

    var display: String { [source.artist, source.title].compactMap { $0 }.joined(separator: " — ") }
}

/// Counts of what a sync would do, one line each; with `limit` > 0, also up to that many track lines.
func pendingLines(_ c: ChangeSet, limit: Int) -> [String] {
    let s = c.summary
    var out: [String] = []
    func count(_ change: ChangeSet.TrackChange) -> Int { c.tracks.filter { $0.changes.contains(change) }.count }
    func add(_ n: Int, _ text: String) { if n > 0 { out.append("\(n) \(text)") } }
    add(count(.new), "new track(s) to copy")
    add(count(.audioChanged), "track(s) with changed audio to copy again")
    add(count(.missingOnDrive), "track(s) missing from the drive to copy again")
    add(s.toAdopt, "track(s) to take over from files already on the drive")
    add(s.toAnalyze, "track(s) to analyze")
    add(s.analysisFiles, "track(s) whose analysis files need checking")
    add(s.records, "track(s) with database changes (title, rating, BPM, …)")
    add(s.artwork, "track(s) whose cover art needs checking")
    add(c.removedTracks.filter { $0.reason == .deselected }.count, "track(s) to remove from the drive")
    add(c.removedTracks.filter { $0.reason == .lost }.count, "track(s) to drop (source unavailable and gone from the drive)")
    add(s.playlistsToCreate, "playlist(s) to add")
    add(s.playlistsToUpdate, "playlist(s) to update")
    add(s.playlistsToRemove, "playlist(s) to remove")
    out += driveLines(s)
    if s.bytesToCopy > 0 { out.append("\(formatBytes(s.bytesToCopy)) to copy") }
    if limit > 0 {
        for t in c.tracks where !t.changes.isEmpty {
            out.append("~ \(t.display): \(t.changes.sorted().map(\.rawValue).joined(separator: ", "))")
            if out.count >= limit { break }
        }
        for r in c.removedTracks where r.reason != .superseded { out.append("- \(r.record.usbPath)") }
    }
    return out
}

func driveLines(_ s: ChangeSet.Summary) -> [String] {
    s.drive.map {
        switch $0 {
        case .settings: "output settings changed"
        case .selection: "selection changed"
        case .databaseMissing: "the drive has no library database"
        case .databaseChanged: "the drive's library database was replaced since Deckhand wrote it"
        case .legacyManifest: "manifest from an older Deckhand to update"
        }
    }
}

/// Tracks that won't change but are worth knowing about.
func noteLines(_ c: ChangeSet) -> [String] {
    var out: [String] = []
    let retained = c.tracks.compactMap { t -> String? in if case .retained(let r) = t.status { "\(t.display): \(r)" } else { nil } }
    if !retained.isEmpty {
        out.append("\(retained.count) track(s) kept on the drive although their source can't be read right now:")
        out += retained.prefix(10).map { "  \($0)" }
    }
    let failed = c.tracks.filter { if case .failed = $0.status { true } else { false } }
    if !failed.isEmpty {
        out.append("\(failed.count) track(s) on the drive without analysis (the analyzer failed; `deckhand analyze --retry-failed` tries again).")
    }
    let ineligible = c.tracks.filter { if case .ineligible = $0.status { true } else { false } }
    if !ineligible.isEmpty { out.append("\(ineligible.count) track(s) can't be synced (no local file, DRM or unsupported format).") }
    return out
}

/// Prints a sync plan.
func printChanges(_ c: ChangeSet, volume: Volume, verbose: Bool) {
    print("Deckhand — \(volume.name)\n")
    print("PLAYLISTS")
    for p in c.playlists {
        let mark: String
        var detail = ""
        switch p.status {
        case .clean:
            if p.source.isFolder { continue }
            mark = "="
        case .pending(let changes):
            mark = changes.contains(.create) ? "+" : "~"
            if !changes.contains(.create) { detail = "  [\(changes.map(\.rawValue).sorted().joined(separator: ", "))]" }
        case .unknown:
            mark = "?"
        }
        let name = p.source.isFolder ? "▸ \(p.source.name)" : "\(p.source.name)  (\(p.record.contentIds.count))"
        print("\(mark) \(name)\(detail)")
    }
    for p in c.removedPlaylists { print("- \(p.name)") }

    let s = c.summary
    print("\nTRACKS")
    func count(_ change: ChangeSet.TrackChange) -> Int { c.tracks.filter { $0.changes.contains(change) }.count }
    print("+ \(count(.new)) new")
    if s.toAdopt > 0 { print("> \(s.toAdopt) taken over from files already on the drive (moved, not copied)") }
    print("~ \(count(.audioChanged) + count(.missingOnDrive)) to copy again (audio changed or missing from the drive)")
    print("- \(c.removedTracks.filter { $0.reason != .superseded }.count) to remove")
    if s.records > 0 { print("# \(s.records) with database changes") }
    if s.analysisFiles > 0 { print("@ \(s.analysisFiles) analysis files to check") }
    if s.artwork > 0 { print("* \(s.artwork) cover art to check") }
    print("= \(s.clean + s.failed) unchanged")
    if verbose {
        for t in c.tracks where !t.changes.isEmpty {
            print("  ~ \(t.display)  [\(t.changes.sorted().map(\.rawValue).joined(separator: ", "))]")
        }
        for r in c.removedTracks where r.reason != .superseded { print("  - \(r.record.usbPath)") }
    }
    print("\nANALYSIS\n\(s.toAnalyze) tracks to analyze")
    print("\nCOPY\n\(formatBytes(s.bytesToCopy))")
    if !s.drive.isEmpty { print("\nDRIVE\n" + driveLines(s).joined(separator: "\n")) }

    let ineligible = c.tracks.compactMap { t -> (String, String, String)? in
        if case .ineligible(let reason) = t.status { (t.playlist ?? "", t.display, reason) } else { nil }
    }
    if !ineligible.isEmpty {
        print("\nCannot sync \(ineligible.count) track(s)\n")
        for (playlist, items) in Dictionary(grouping: ineligible, by: \.0).sorted(by: { $0.key < $1.key }) {
            print(playlist)
            for (_, track, reason) in items { print("  ! \(track)\n    \(reason)") }
        }
    }
    let notes = noteLines(c).filter { !$0.contains("can't be synced") }
    if !notes.isEmpty { print("\n" + notes.joined(separator: "\n")) }
}

/// `deckhand status --json`.
struct StatusReport: Encodable {
    struct Track: Encodable {
        var id: String
        var title: String
        var artist: String?
        var status: String
        var changes: [String]?
        var reason: String?
    }

    struct Playlist: Encodable {
        var id: String
        var name: String
        var status: String
        var changes: [String]?
    }

    struct Removed: Encodable {
        var id: String
        var usbPath: String
        var reason: String
        var deletesFiles: Bool
    }

    var volume: String
    var generation: Int
    var lastSyncedAt: Date?
    var clean: Bool
    var complete: Bool
    var summary: ChangeSet.Summary
    var tracks: [Track]
    var playlists: [Playlist]
    var removedTracks: [Removed]
    var removedPlaylists: [String]

    init(_ c: ChangeSet, volume v: Volume) {
        volume = v.name
        generation = c.base.generationNumber
        lastSyncedAt = c.base.lastSyncedAt
        clean = c.isClean
        complete = c.isComplete
        summary = c.summary
        tracks = c.tracks.compactMap { t in
            var row = Track(id: t.id, title: t.source.title, artist: t.source.artist, status: "")
            switch t.status {
            case .clean: return nil
            case .pending(let changes):
                row.status = "pending"
                row.changes = changes.sorted().map(\.rawValue)
            case .ineligible(let r): row.status = "ineligible"; row.reason = r
            case .retained(let r): row.status = "retained"; row.reason = r
            case .failed(let r): row.status = "failed"; row.reason = r
            case .unknown: row.status = "unknown"
            }
            return row
        }
        playlists = c.playlists.compactMap { p in
            switch p.status {
            case .clean: nil
            case .pending(let changes):
                Playlist(id: p.source.id, name: p.source.name, status: "pending", changes: changes.map(\.rawValue).sorted())
            case .unknown: Playlist(id: p.source.id, name: p.source.name, status: "unknown")
            }
        }
        removedTracks = c.removedTracks.map {
            Removed(id: $0.id, usbPath: $0.record.usbPath, reason: $0.reason.rawValue, deletesFiles: $0.deletesFiles)
        }
        removedPlaylists = c.removedPlaylists.map(\.name)
    }
}
