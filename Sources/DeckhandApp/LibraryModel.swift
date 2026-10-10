import AppKit
import DeckhandAppCore
import DeckhandCore
import Foundation
import MusicSource
import Observation
import Sync

/// A downsampled three-band waveform for drawing, normalized per band to the track's loudest frame.
struct Overview: Equatable, Sendable {
    var low: [Float]
    var mid: [Float]
    var high: [Float]
    /// Detected cue positions as fractions of the track.
    var cues: [Double]

    init(_ w: TrackAnalysis.Waveforms, bins: Int, cuesMs: [Int] = [], durationMs: Double) {
        func reduce(_ a: [Float], scale: Float) -> [Float] {
            guard !a.isEmpty else { return [] }
            let peak = max(a.max() ?? 1, 1e-6)
            let n = min(bins, a.count)
            return (0..<n).map { i in
                let lo = i * a.count / n, hi = max(lo + 1, (i + 1) * a.count / n)
                return (a[lo..<hi].max() ?? 0) / peak * scale
            }
        }
        low = reduce(w.low, scale: 1)
        mid = reduce(w.mid, scale: 0.8)
        high = reduce(w.high, scale: 0.55)
        cues = durationMs > 0 ? cuesMs.map { Double($0) / durationMs } : []
    }
}

struct TrackRow: Identifiable, Equatable, Sendable {
    let id: String
    var source: SourceTrack
    var title: String
    var artist: String
    var genre: String
    var duration: Double
    var location: URL
    var dateAdded: Date
    var hash: String?
    /// False until the cache has been checked for this track.
    var checked = false
    var analyzed = false
    var bpm: Double?
    var key: MusicalKey?
    var energy: Int?
    var overview: Overview?

    var bpmSort: Double { bpm ?? 0 }
    var keySort: Int { key.map { $0.camelotNumber * 2 + ($0.mode == .minor ? 0 : 1) } ?? 99 }
    var energySort: Int { energy ?? 0 }
    var rating: Int { source.rating ?? 0 }
    var bpmText: String { bpm.map { String(format: "%.2f", $0) } ?? "—" }
}

enum SidebarItem: Hashable {
    case all, needsAnalysis
    case playlist(String)
}

struct Drive: Identifiable, Sendable {
    var volume: Volume
    var manifest: Manifest?
    /// The drive's files, read with the manifest (Deckhand drives only).
    var probe: DriveProbe?
    var id: String { volume.url.path }
    var canSync: Bool { manifest.map { $0.entireLibrary == true || !$0.selectedPlaylistIds.isEmpty } ?? false }

    /// Reads a mounted drive's manifest and files. Off the main thread: USB reads can take seconds.
    nonisolated static func read(_ volume: Volume) -> Drive {
        let manifest = try? Manifest.load(from: volume)
        return Drive(volume: volume, manifest: manifest, probe: manifest.map { DriveProbe.scan(volume, manifest: $0) })
    }
}

struct PlaylistEntry: Identifiable {
    var playlist: SourcePlaylist
    var depth: Int
    var id: String { playlist.id }
}

struct TrackFilter: Equatable {
    var search = ""
    /// Camelot codes, e.g. "8A".
    var keys: Set<String> = []
    var bpmMin: Double?
    var bpmMax: Double?
    var minEnergy: Int?
    var minRating: Int?
    var genres: Set<String> = []
    var mixesWithPlaying = false

    var isEmpty: Bool { self == TrackFilter() }
}

/// Whether the library could be read live from Music (see `MusicLive`).
enum LiveState: Equatable {
    case unknown
    case live
    /// Music isn't running: the snapshot is current.
    case notRunning
    /// Music is running but couldn't be read: rows and sync status may trail recent edits.
    case unavailable(MusicEvents.Failure)
}

/// A non-modal note above the track list about the last sync.
enum SyncNotice: Equatable {
    /// Reading everything again after the sync still found work to do.
    case leftover(drive: String, count: Int, details: [String])
    /// The sync stopped before writing because Music couldn't be read live.
    case staleLibrary(driveId: String, drive: String, reason: String)
}

@MainActor @Observable
final class LibraryModel {
    let cache: AnalysisCache? = try? AnalysisCache()

    private(set) var rows: [String: TrackRow] = [:] { didSet { contentVersion &+= 1 } }
    /// Library order: newest first.
    private(set) var allIds: [String] = [] { didSet { contentVersion &+= 1 } }
    private(set) var playlists: [SourcePlaylist] = [] { didSet { contentVersion &+= 1 } }
    /// Bumped whenever rows, allIds or playlists change; keys the memoized listing.
    private var contentVersion = 0
    private(set) var drives: [Drive] = []
    private(set) var status: String?
    private(set) var artwork: (any ArtworkProvider)?
    var activeDriveId: String? {
        didSet {
            guard activeDriveId != oldValue else { return }
            statusStore.reset()
            publishStatus()
            if let name = activeDrive?.volume.name { UserDefaults.standard.set(name, forKey: "activeDrive") }
            evaluateStatus()
        }
    }
    var selection: SidebarItem? = LibraryModel.savedSelection {
        didSet {
            let value: String? = switch selection {
            case .playlist(let id): id
            case .needsAnalysis: "needsAnalysis"
            default: nil
            }
            UserDefaults.standard.set(value, forKey: "selection")
            Log.info("ui", "Selected \(title)")
        }
    }

    private static var savedSelection: SidebarItem {
        switch UserDefaults.standard.string(forKey: "selection") {
        case nil: .all
        case "needsAnalysis": .needsAnalysis
        case "suggestions": .all   // a sidebar item that no longer exists
        case let id?: .playlist(id)
        }
    }
    var filter = TrackFilter()
    var sort: TrackSort?

    /// The library as the engine sees it: iTunesLibrary's snapshot, Music's live fields and ratings still being
    /// written. Sync status is evaluated from this; rows show the same values.
    @ObservationIgnored private var library: SourceLibrary?
    /// Every Apple Event the app sends goes through this one serial queue.
    @ObservationIgnored private var bridge: MusicBridge!
    @ObservationIgnored private var ratings = RatingOverlay()
    @ObservationIgnored private var driveReads = ReadLedger()

    init() {
        bridge = MusicBridge { [weak self] result in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ratingFinished(result) } }
        }
    }

    var activeDrive: Drive? { drives.first { $0.id == activeDriveId } }

    // MARK: Loading

    enum LoadState: Equatable {
        case loading
        /// Still waiting after 10 s: usually macOS's "allow access to Apple Music" prompt, which can
        /// be hidden behind other windows.
        case slow
        case failed(String)
        case loaded
    }

    /// Progress of the first library read; the track list shows a loading panel until `.loaded`.
    private(set) var loadState = LoadState.loading
    /// Whether Music could be read live on the last library read.
    private(set) var live = LiveState.unknown

    func load() async {
        refreshDrives()
        observeMounts()
        observeMusic()
        await readLibrary()
    }

    /// Reads the Apple Music library (again, after a failure: the loading panel's Try Again).
    func readLibrary() async {
        loadState = .loading
        let attempt = UUID()
        loadAttempt = attempt
        Task {
            try? await Task.sleep(for: .seconds(10))
            if loadAttempt == attempt, loadState == .loading { loadState = .slow }
        }
        // Not asked yet whether Deckhand may control Music: ask (the prompt can sit unanswered, so the first read
        // goes ahead from the snapshot) and read again once answered.
        if (try? await bridge.run({ $0.access(ask: false) }))?.value == .undecided {
            awaitingAccess = true
            Task {
                _ = try? await bridge.run { $0.access(ask: true) }
                awaitingAccess = false
                scheduleReload("Music access answered", after: 0)
            }
        }
        do {
            try await reloadLibrary("launch")
        } catch {
            loadState = .failed("\(error)")
            Log.error("library", "Couldn't read Apple Music: \(error)")
            return
        }
        backUpRatings()
    }

    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false
    @ObservationIgnored private var reloadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Reads Apple Music again: iTunesLibrary's snapshot, then Music's live fields (behind any rating writes still
    /// queued). Returns once a read begun after the call has been applied; calls during a read share the next one.
    func reloadLibrary(_ reason: String) async throws {
        if reloading {
            reloadAgain = true
            await withCheckedContinuation { reloadWaiters.append($0) }
            return
        }
        reloading = true
        defer { reloading = false }
        repeat {
            reloadAgain = false
            let waiters = reloadWaiters
            reloadWaiters = []
            defer { waiters.forEach { $0.resume() } }
            try await readMusic(reason)
        } while reloadAgain
    }

    /// One library read, applied. Touches nothing on the main thread when nothing changed.
    private func readMusic(_ reason: String) async throws {
        let start = Date()
        let snapshot = try await Task.detached { try AppleMusicLibrary.load(allSongs: true) }.value
        let snapshotMs = Int(Date().timeIntervalSince(start) * 1000)
        let read = await readLive()
        let (lib, signature) = await Task.detached { () -> (SourceLibrary, Int) in
            var lib = snapshot
            if let fields = read.fields { MusicLive.overlay(fields, onto: &lib) }
            return (lib, Self.signature(of: lib))
        }.value
        var merged = lib
        ratings.apply(to: &merged, readAt: read.sequence)
        if live != read.state { live = read.state }
        let total = Int(Date().timeIntervalSince(start) * 1000)
        if !ratings.isEmpty || signature != librarySignature || library == nil {
            await apply(merged, signature: signature)
            Log.info("library", "Read Apple Music (\(reason)): \(lib.tracks.count) tracks in \(total) ms (snapshot \(snapshotMs) ms, live: \(read.state))")
        } else {
            Log.info("library", "Apple Music unchanged (\(reason), checked in \(total) ms, live: \(read.state))")
        }
    }

    @ObservationIgnored private var awaitingAccess = false

    /// Music's live fields, unless it's known that they can't be read.
    private func readLive() async -> (fields: [String: LiveTrack]?, sequence: Int?, state: LiveState) {
        if awaitingAccess { return (nil, nil, .unknown) }
        if case .unavailable(let f) = live, f.status == MusicEvents.Failure.notPermitted {
            // Refused before: check again without sending anything (it's off until the user allows it).
            let access = (try? await bridge.run { $0.access(ask: false) })?.value
            if access == .denied { return (nil, nil, live) }
        }
        do {
            let r = try await bridge.run { try $0.readLive() }
            return (r.value, r.sequence, .live)
        } catch {
            let f = MusicBridge.failure(error)
            if !f.isNotRunning { Log.warning("library", "Couldn't read Music live: \(f)") }
            return (nil, nil, f.isNotRunning ? .notRunning : .unavailable(f))
        }
    }

    @ObservationIgnored private var librarySignature: Int?

    nonisolated private static func signature(of lib: SourceLibrary) -> Int {
        var h = Hasher()
        h.combine(lib.tracks)
        h.combine(lib.playlists)
        h.combine(lib.allTrackIds)
        return h.finalize()
    }

    /// Builds rows off the main thread; only assigns them on it.
    private func apply(_ lib: SourceLibrary, signature: Int) async {
        let start = Date()
        let snapshot = rows, version = contentVersion
        var merged = await Task.detached { Self.merge(lib, into: snapshot) }.value
        // Ratings set meanwhile stay shown.
        var lib = lib
        ratings.apply(to: &lib, readAt: nil)
        // Rows changed meanwhile (analysis loaded, a rating set): merge into the current ones instead.
        if contentVersion != version { merged = Self.merge(lib, into: rows) }
        Log.measure("library", "Assigning rows") {
            if merged.changed { rows = merged.rows }
            if allIds != merged.allIds { allIds = merged.allIds }
            let named = Self.demoNamed(lib.playlists)
            if playlists != named { playlists = named }
            artwork = lib.artwork
            loadState = .loaded
        }
        library = lib
        librarySignature = signature
        Log.info("library", "Applied Apple Music in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(merged.changed ? "" : " (rows unchanged)")")
        evaluateStatus()
        if rows.values.contains(where: { !$0.checked }) { Task { await loadAnalysis() } }
    }

    nonisolated private static func merge(_ lib: SourceLibrary, into old: [String: TrackRow])
        -> (rows: [String: TrackRow], allIds: [String], changed: Bool) {
        var rows = old
        var changed = false
        for t in lib.tracks.values {
            guard let url = t.location else { continue }
            if var row = rows[t.id] {
                // Refresh what may have been edited in Music; keep the loaded analysis.
                row.source = t
                row.title = t.title
                row.artist = t.artist ?? ""
                row.genre = t.genre ?? ""
                if row.location != url {
                    row.location = url
                    row.checked = false
                }
                if rows[t.id] != row { rows[t.id] = row; changed = true }
                continue
            }
            rows[t.id] = TrackRow(id: t.id, source: t, title: t.title, artist: t.artist ?? "", genre: t.genre ?? "",
                                  duration: t.durationSeconds ?? 0, location: url, dateAdded: t.dateAdded ?? .distantPast)
            changed = true
        }
        let allIds = (lib.allTrackIds ?? Array(lib.tracks.keys)).filter { rows[$0] != nil }
            .sorted { rows[$0]!.dateAdded > rows[$1]!.dateAdded }
        return (rows, allIds, changed)
    }

    /// With `DECKHAND_DEMO=1`, shows placeholder playlist names (for screenshots). Display only: Music and
    /// drives are addressed by playlist ID, so these names are never written anywhere.
    private static func demoNamed(_ playlists: [SourcePlaylist]) -> [SourcePlaylist] {
        guard ProcessInfo.processInfo.environment["DECKHAND_DEMO"] == "1" else { return playlists }
        let names = ["Friday Warmup", "Peak Time", "Deep House", "Disco Edits", "Afterhours", "Sunday Sessions", "Rooftop", "Open Format",
                     "Garage Classics", "Breaks", "Italo", "Closing Tracks", "Edits & Bootlegs", "Balearic"]
        return playlists.enumerated().map { i, p in
            var p = p
            p.name = names[i % names.count]
            return p
        }
    }

    private struct Loaded: Sendable {
        var id: String
        var hash: String?
        var analysis: (bpm: Double, key: MusicalKey?, energy: Int?, overview: Overview)?
    }

    @ObservationIgnored private var loadingAnalysis = false

    /// Reads each track's cached analysis in the background (hashing files the cache hasn't seen), then evaluates
    /// sync status again: tracks it hashed were unknown until now.
    private func loadAnalysis() async {
        guard let cache, !loadingAnalysis else { return }
        loadingAnalysis = true
        defer { loadingAnalysis = false }
        let start = Date()
        while true {
            let items = allIds.compactMap { rows[$0] }.filter { !$0.checked }.map { ($0.id, $0.location) }
            guard !items.isEmpty else { break }
            status = "Loading analysis…"
            await withTaskGroup(of: Loaded.self) { group in
                var pending = items.makeIterator()
                for _ in 0..<8 { if let (id, url) = pending.next() { group.addTask { Self.loadOne(id, url, cache) } } }
                var batch: [Loaded] = []
                var done = 0
                var lastEvaluation = Date()
                for await r in group {
                    batch.append(r)
                    done += 1
                    if let (id, url) = pending.next() { group.addTask { Self.loadOne(id, url, cache) } }
                    if batch.count >= 64 {
                        merge(batch)
                        batch = []
                        status = "Loading analysis… \(done) of \(items.count)"
                        if Date().timeIntervalSince(lastEvaluation) > 2 {
                            lastEvaluation = Date()
                            evaluateStatus()
                        }
                    }
                }
                merge(batch)
            }
        }
        try? cache.save()
        status = nil
        evaluateStatus()
        Log.info("analysis", "Loaded cached analysis in \(String(format: "%.1f", Date().timeIntervalSince(start))) s; \(unanalyzedCount) tracks not analyzed")
    }

    nonisolated private static func loadOne(_ id: String, _ url: URL, _ cache: AnalysisCache) -> Loaded {
        guard let hash = try? cache.contentHash(of: url) else { return Loaded(id: id) }
        guard let s = cache.summary(forHash: hash) else { return Loaded(id: id, hash: hash) }
        let overview = Overview(s.overview, bins: AnalysisCache.Summary.overviewBins, cuesMs: s.cuesMs,
                                durationMs: s.durationSeconds * 1000)
        return Loaded(id: id, hash: hash, analysis: (s.bpm, s.key, s.energy, overview))
    }

    private func merge(_ batch: [Loaded]) {
        guard !batch.isEmpty else { return }
        var updated = rows
        for r in batch {
            guard var row = updated[r.id] else { continue }
            row.checked = true
            row.hash = r.hash
            row.analyzed = r.analysis != nil
            row.bpm = r.analysis?.bpm
            row.key = r.analysis?.key
            row.energy = r.analysis?.energy
            row.overview = r.analysis?.overview
            updated[r.id] = row
        }
        rows = updated
    }

    // MARK: Analysis

    /// The background sync or analysis run, shown in the right-hand pane. One at a time.
    let job = Job()

    /// Runs `deckhand analyze` for the whole library, then reloads what it produced.
    func analyzeLibrary() {
        guard !job.running else { flash("Wait for \(job.title.lowercased()) to finish"); return }
        job.run("Analyzing library", ["analyze"]) { [weak self] _ in
            self?.cache?.reloadFromDisk()
            self?.reloadUnanalyzed()
        }
    }

    private func reloadUnanalyzed() {
        // One assignment: each write to `rows` rebuilds the listing.
        var updated = rows
        for (id, row) in rows where !row.analyzed && row.checked { updated[id]?.checked = false }
        rows = updated
        Task { await loadAnalysis() }
    }

    // MARK: Sync status

    /// Decides which evaluation the views show; see `StatusStore`. Not observed: views observe `shownStatus`, which
    /// changes only when the status does (not each time an evaluation starts).
    @ObservationIgnored private var statusStore = StatusStore()
    private var shownStatus: DriveStatus?
    /// Bumped whenever `shownStatus` changes; keys memoized counts.
    @ObservationIgnored private var statusVersion = 0

    private func publishStatus() {
        guard shownStatus != statusStore.status else { return }
        shownStatus = statusStore.status
        statusVersion &+= 1
    }

    /// What a sync would change on the active drive; nil while it's being checked (and without a Deckhand drive).
    var driveStatus: DriveStatus? {
        guard let s = shownStatus, s.driveId == activeDriveId, activeDrive?.manifest != nil else { return nil }
        return s
    }
    /// The active drive's status hasn't been evaluated yet ("Checking…").
    var checkingStatus: Bool { activeDrive?.manifest != nil && driveStatus == nil }
    /// A note about the last sync, shown above the track list until dismissed.
    var syncNotice: SyncNotice?

    @ObservationIgnored private var evaluating = false
    @ObservationIgnored private var evaluateAgain = false
    @ObservationIgnored private var verifyNext = false

    /// Evaluates the active drive's sync status off the main thread with the engine's decision function. One at a
    /// time; calls meanwhile run once more with the latest library and drive. `verify`: the evaluation after a sync.
    func evaluateStatus(verify: Bool = false) {
        if verify { verifyNext = true }
        if evaluating {
            evaluateAgain = true
            return
        }
        guard let cache, let library, let drive = activeDrive, let manifest = drive.manifest, let probe = drive.probe else {
            // Nothing to evaluate: don't leave a sync's verification holding back later results.
            if verifyNext, statusStore.awaitingVerification {
                statusStore.reset()
                publishStatus()
            }
            verifyNext = false
            return
        }
        let verifying = verifyNext
        verifyNext = false
        let request = verifying ? statusStore.beginVerification() : statusStore.begin()
        let inputs = StatusInputs(library: library, driveId: drive.id, volume: drive.volume, manifest: manifest, probe: probe)
        evaluating = true
        Task {
            let start = Date()
            let result = await Task.detached { StatusEvaluator.evaluate(inputs, cache: cache) }.value
            evaluating = false
            let outcome = statusStore.finish(result, request: request)
            publishStatus()
            Log.info("status", "Evaluated \(drive.volume.name) in \(Int(Date().timeIntervalSince(start) * 1000)) ms: "
                     + "\(result.pendingCount) pending, \(result.summary.unknown) unknown\(outcome == .stale ? " (stale, dropped)" : "")")
            handle(outcome, drive: drive)
            if evaluateAgain {
                evaluateAgain = false
                evaluateStatus()
            }
        }
    }

    private func handle(_ outcome: StatusStore.Outcome, drive: Drive) {
        switch outcome {
        case .leftover(let s):
            for line in s.details.prefix(20) { Log.warning("sync", "Still pending on \(drive.volume.name) after syncing: \(line)") }
            if warnOnLeftover { syncNotice = .leftover(drive: drive.volume.name, count: s.pendingCount, details: s.details) }
            warnOnLeftover = false
        case .verified:
            Log.info("sync", "\(drive.volume.name) verified up to date after syncing")
            warnOnLeftover = false
        case .applied, .stale:
            break
        }
    }

    /// Changes waiting for the active drive (tracks to copy, update or remove, playlists, drive changes).
    var pendingChanges: Int { driveStatus?.pendingCount ?? 0 }

    /// Bytes still to copy to the active drive.
    var pendingBytes: Int64 { driveStatus?.bytesToCopy ?? 0 }

    /// True when the next sync wouldn't fit on the active drive (the same check the sync makes).
    var pendingWontFit: Bool { driveStatus?.wontFit ?? false }

    /// A track's status on the active drive; nil without a drive status (none, or still checking) or when the drive
    /// doesn't take the track.
    func syncState(_ row: TrackRow) -> DriveStatus.Track? { driveStatus?.tracks[row.id] }

    /// A playlist's status on the active drive; nil when it isn't on the drive or status is still being checked.
    func playlistSync(_ p: SourcePlaylist) -> DriveStatus.Playlist? { driveStatus?.playlists[p.id] }

    // MARK: Syncing

    /// Syncs a drive in the background (analyzing anything not yet analyzed), then reads everything again.
    /// `requireLive`: stop if Music is running but can't be read live (the default); the app offers to sync anyway.
    func sync(_ drive: Drive, requireLive: Bool = true) {
        guard !job.running else { flash("Wait for \(job.title.lowercased()) to finish"); return }
        guard drive.canSync else {
            flash("Add a playlist to \(drive.volume.name) first (hover it in the sidebar and click Add)")
            return
        }
        syncNotice = nil
        editedDuringSync = false
        Task {
            // Ratings still being written go first, so the sync reads them.
            if bridge.hasQueuedRatings { status = "Saving ratings to Music…" }
            await bridge.drain()
            if status == "Saving ratings to Music…" { status = nil }
            var args = ["sync", drive.volume.url.path, "-y", "--analyze"]
            if requireLive { args.append("--require-live") }
            job.run("Syncing \(drive.volume.name)", args) { [weak self] ok in self?.syncFinished(drive, ok: ok) }
        }
    }

    /// Whether the verification after the current sync should warn about anything still pending.
    @ObservationIgnored private var warnOnLeftover = false
    /// Something was edited (here or in Music) while the sync ran, so work left afterwards is expected.
    @ObservationIgnored private var editedDuringSync = false

    private var syncing: Bool { job.running && job.title.hasPrefix("Syncing") }

    private func syncFinished(_ drive: Drive, ok: Bool) {
        // With `--require-live`, the CLI stops before writing when Music is running but can't be read.
        let stale = job.liveWarning
        if let stale { syncNotice = .staleLibrary(driveId: drive.id, drive: drive.volume.name, reason: stale.reason) }
        if stale == nil, drive.id == activeDriveId {
            statusStore.syncFinished(driveId: drive.id, report: job.report)
            publishStatus()
        }
        cache?.reloadFromDisk()
        let edits = queuedEdits.removeValue(forKey: drive.id) ?? []
        // Leftovers are worth a warning only when nothing explains them: the sync succeeded (a failure's error is
        // in the job card) and nothing was edited meanwhile.
        warnOnLeftover = stale == nil && ok && edits.isEmpty && !editedDuringSync
        Task {
            if !edits.isEmpty { await write(edits, to: drive) }
            guard stale == nil else { return }
            async let reloaded: Void? = try? reloadLibrary("after syncing")
            async let refreshed: Void = refreshDrive(drive.id)
            _ = await (reloaded, refreshed)
            reloadUnanalyzed()
            if drive.id == activeDriveId { evaluateStatus(verify: true) }
        }
    }

    // MARK: Sidebar navigation

    /// Sidebar items in the order shown: library items, then playlists (grouped by the active drive when there is one).
    var sidebarOrder: [SidebarItem] {
        let entries = drivePlaylistGroups.map { $0.on + $0.off } ?? playlistEntries
        var seen = Set<String>()
        return [.all, .needsAnalysis] + entries.filter { seen.insert($0.id).inserted }.map { .playlist($0.id) }
    }

    /// Moves the sidebar selection to the next (1) or previous (-1) item, wrapping around.
    func selectAdjacentSidebarItem(_ delta: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let i = selection.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        selection = order[(i + delta + order.count) % order.count]
    }

    // MARK: Drive selection

    /// Whether the active drive holds every song (not only those in its playlists).
    var entireLibraryOnDrive: Bool { activeDrive?.manifest?.entireLibrary == true }

    /// Whether a playlist is on the active drive; a folder is when all the playlists in it are.
    func isOnDrive(_ p: SourcePlaylist) -> Bool {
        guard let m = activeDrive?.manifest else { return false }
        let leaves = leafPlaylistIds(of: p)
        return !leaves.isEmpty && Set(leaves).isSubset(of: m.selectedPlaylistIds)
    }

    /// Sidebar playlists split by whether they're on the active drive. A folder shows in a group when any playlist
    /// inside it does. Nil without a Deckhand drive.
    var drivePlaylistGroups: (on: [PlaylistEntry], off: [PlaylistEntry])? {
        guard let m = activeDrive?.manifest else { return nil }
        var on: [PlaylistEntry] = [], off: [PlaylistEntry] = []
        for e in playlistEntries {
            let leaves = leafPlaylistIds(of: e.playlist)
            let onCount = leaves.filter(m.selectedPlaylistIds.contains).count
            if onCount > 0 { on.append(e) }
            if onCount < leaves.count || (e.playlist.isFolder && leaves.isEmpty) { off.append(e) }
        }
        return (on, off)
    }

    private func leafPlaylistIds(of p: SourcePlaylist) -> [String] {
        p.isFolder ? playlists.filter { $0.parentId == p.id }.flatMap { leafPlaylistIds(of: $0) } : [p.id]
    }

    /// Puts a playlist (or every playlist in a folder) on the active drive or takes it off. Saved to the drive
    /// right away; the next sync copies or removes the tracks.
    func setOnDrive(_ on: Bool, _ p: SourcePlaylist) {
        let ids = leafPlaylistIds(of: p)
        updateSelection { m in
            var selected = m.selectedPlaylistIds.filter { !ids.contains($0) }
            if on { selected += ids }
            m.selectedPlaylistIds = selected
        }
    }

    /// Puts every song on the active drive, or only those in its playlists. Playlists stay as chosen either way.
    func setEntireLibraryOnDrive(_ on: Bool) {
        updateSelection { m in m.entireLibrary = on }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    typealias SelectionEdit = @Sendable (inout Manifest) -> Void

    /// Selection edits made while the app's sync holds a drive, saved when it finishes.
    @ObservationIgnored private var queuedEdits: [String: [SelectionEdit]] = [:]

    /// Applies a selection edit: shown right away, saved to the drive's newest manifest with `Manifest.edit`, then the
    /// view takes what was saved. While this app syncs the drive the edit waits for the sync (the CLI holds its lock).
    private func updateSelection(_ change: @escaping SelectionEdit) {
        guard let drive = activeDrive, var m = drive.manifest else { return }
        change(&m)
        setManifest(m, for: drive.id)
        if syncing { editedDuringSync = true }
        if job.running, job.title.hasSuffix(drive.volume.name) {
            queuedEdits[drive.id, default: []].append(change)
            flash("Saved to \(drive.volume.name) when the sync finishes")
            return
        }
        Task { await write([change], to: drive) }
    }

    private func write(_ edits: [SelectionEdit], to drive: Drive) async {
        let volume = drive.volume
        let result: Result<Manifest, Error> = await Task.detached {
            Result { try Manifest.edit(on: volume) { m in edits.forEach { $0(&m) } } }
        }.value
        switch result {
        case .success(let m):
            setManifest(m, for: drive.id)
            if drive.id == activeDriveId, let s = driveStatus, s.wontFit {
                flash("That's \(Self.bytes(s.bytesToCopy)) to copy, but \(volume.name) only has \(Self.bytes(volume.available)) free")
            }
        case .failure(SyncError.driveBusy(_, let holder)):
            flash("\(volume.name) is being synced by another Deckhand (pid \(holder.pid)); change it when that sync finishes")
            await refreshDrive(drive.id)
        case .failure(let error):
            flash("Couldn't update \(volume.name): \(error)")
            await refreshDrive(drive.id)
        }
    }

    /// Replaces a drive's manifest with one this app just made or saved; reads begun before can't overwrite it.
    private func setManifest(_ m: Manifest, for id: String) {
        guard let i = drives.firstIndex(where: { $0.id == id }) else { return }
        _ = driveReads.accept(id, driveReads.begin())
        drives[i].manifest = m
        if id == activeDriveId { evaluateStatus() }
    }

    // MARK: Drives

    /// Re-reads mounted drives, their manifests and files off the main thread (USB reads can take seconds).
    func refreshDrives() {
        let token = driveReads.begin()
        Task {
            let start = Date()
            let found = await Task.detached { Volume.removable().map(Drive.read) }.value
            Log.info("drives", "Read \(found.count) drive(s) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            setDrives(found, token: token)
        }
    }

    /// Re-reads one drive; returns once applied (or superseded by a newer read).
    func refreshDrive(_ id: String) async {
        guard let volume = drives.first(where: { $0.id == id })?.volume else { return }
        let token = driveReads.begin()
        let drive = await Task.detached { (try? Volume(url: volume.url)).map(Drive.read) }.value
        guard let drive, let i = drives.firstIndex(where: { $0.id == id }) else { return }
        guard driveReads.accept(id, token) else { return }
        drives[i] = withQueuedEdits(drive)
        if id == activeDriveId { evaluateStatus() }
    }

    private func setDrives(_ found: [Drive], token: Int) {
        let current = Dictionary(drives.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Drive] = []
        if driveReads.accept("", token) {
            // The newest list of mounted drives; a drive read more recently on its own keeps that read.
            for d in found { next.append(driveReads.accept(d.id, token) ? withQueuedEdits(d) : current[d.id] ?? d) }
        } else {
            // An older list: only update drives it read more recently than what's shown.
            next = drives.map { d in found.first { $0.id == d.id }.flatMap { driveReads.accept(d.id, token) ? withQueuedEdits($0) : nil } ?? d }
        }
        drives = next
        if activeDrive == nil {
            let saved = UserDefaults.standard.string(forKey: "activeDrive")
            activeDriveId = (drives.first { $0.manifest != nil && $0.volume.name == saved } ?? drives.first { $0.manifest != nil })?.id
        }
        evaluateStatus()
    }

    /// A drive as read, with selection edits still waiting for a sync to finish shown applied.
    private func withQueuedEdits(_ d: Drive) -> Drive {
        guard var m = d.manifest, let edits = queuedEdits[d.id], !edits.isEmpty else { return d }
        edits.forEach { $0(&m) }
        var d = d
        d.manifest = m
        return d
    }

    private var observing = false
    private func observeMounts() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrives() }
            }
        }
    }

    /// Music's agent posts this when it has applied edits from Music (what iTunesLibrary reads). Bursts are common,
    /// so reloads are debounced.
    private func observeMusic() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.AMPLibraryAgent.libraryChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.syncing { self.editedDuringSync = true }
                self.scheduleReload("Music changed", after: 1)
            }
        }
    }

    @ObservationIgnored private var scheduledReload: Task<Void, Never>?

    /// Reloads the library after `delay` seconds, replacing a reload already scheduled.
    func scheduleReload(_ reason: String, after delay: Double) {
        guard loadState == .loaded else { return }
        scheduledReload?.cancel()
        scheduledReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self?.reloadLibrary(reason)
        }
    }

    /// Drives being ejected (by id), for the sidebar spinner.
    private(set) var ejecting: Set<String> = []

    /// Ejects in the background (flushing a stick can take a few seconds) and reports the outcome.
    func eject(_ drive: Drive) {
        let name = drive.volume.name, id = drive.id
        if job.running, job.title.hasSuffix(name) {
            flash("Wait for \(job.title.lowercased()) to finish before ejecting")
            return
        }
        ejecting.insert(id)
        Log.info("drives", "Ejecting \(name)")
        Task {
            let error: String? = await Task.detached {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: drive.volume.url)
                    return nil
                } catch {
                    return (error as NSError).localizedFailureReason ?? error.localizedDescription
                }
            }.value
            ejecting.remove(id)
            if let error {
                Log.error("drives", "Couldn't eject \(name): \(error)")
                flash("Couldn't eject \(name): \(error)")
            } else {
                flash("\(name) ejected; safe to remove")
            }
            refreshDrives()
        }
    }

    // MARK: Playlists

    var playlistEntries: [PlaylistEntry] {
        let byParent = Dictionary(grouping: playlists, by: { $0.parentId ?? "" })
        var out: [PlaylistEntry] = []
        func walk(_ parent: String, _ depth: Int) {
            for p in byParent[parent] ?? [] {
                out.append(PlaylistEntry(playlist: p, depth: depth))
                if p.isFolder { walk(p.id, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    /// `trackIds(of:).count`, memoized for the sidebar's badges.
    func trackCount(of p: SourcePlaylist) -> Int {
        if trackCountVersion != contentVersion {
            trackCountVersion = contentVersion
            trackCounts.removeAll(keepingCapacity: true)
        }
        if let n = trackCounts[p.id] { return n }
        let n = trackIds(of: p).count
        trackCounts[p.id] = n
        return n
    }

    @ObservationIgnored private var trackCounts: [String: Int] = [:]
    @ObservationIgnored private var trackCountVersion = -1

    func trackIds(of p: SourcePlaylist) -> [String] {
        guard p.isFolder else { return p.trackIds.filter { rows[$0] != nil } }
        var seen = Set<String>()
        return playlists.filter { $0.parentId == p.id }.flatMap { trackIds(of: $0) }.filter { seen.insert($0).inserted }
    }

    /// Changes a playlist in the rows and in the library sync status is evaluated from (names there stay real in
    /// demo mode).
    private func editPlaylist(_ id: String, _ change: (inout SourcePlaylist) -> Void) {
        if syncing { editedDuringSync = true }
        if let i = playlists.firstIndex(where: { $0.id == id }) { change(&playlists[i]) }
        if let i = library?.playlists.firstIndex(where: { $0.id == id }) {
            let name = library!.playlists[i].name
            change(&library!.playlists[i])
            library!.playlists[i].name = name
        }
        evaluateStatus()
    }

    func createPlaylist(named name: String) async {
        do {
            let id = try await bridge.run { _ in try AppleMusicWriter.createPlaylist(named: name, isFolder: false, inFolder: nil) }.value
            let p = SourcePlaylist(id: id, name: name)
            playlists.append(p)
            library?.playlists.append(p)
            selection = .playlist(id)
            scheduleReload("after creating a playlist", after: 2)
        } catch {
            flash("Couldn't create playlist: \(error)")
        }
    }

    /// Appends tracks to an Apple Music playlist, skipping ones it already has.
    func add(_ trackIds: [String], to playlist: SourcePlaylist) async {
        guard !playlist.isFolder, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        recentPlaylistIds = [playlist.id] + recentPlaylistIds.filter { $0 != playlist.id }.prefix(9)
        UserDefaults.standard.set(recentPlaylistIds, forKey: "recentPlaylists")
        var seen = Set(playlists[index].trackIds)
        let fresh = trackIds.filter { seen.insert($0).inserted }
        let already = trackIds.count - fresh.count
        guard !fresh.isEmpty else {
            flash("Already in \(playlist.name)")
            return
        }
        do {
            let missing = Set(try await bridge.run { _ in try AppleMusicWriter.add(trackIds: fresh, toPlaylist: playlist.id) }.value)
            let added = fresh.filter { !missing.contains($0) }
            editPlaylist(playlist.id) { $0.trackIds += added }
            var text = "Added \(added.count) track\(added.count == 1 ? "" : "s") to \(playlist.name)"
            if already > 0 { text += " · \(already) already there" }
            if !missing.isEmpty { text += " · \(missing.count) not found in Music" }
            flash(text)
            scheduleReload("after adding to a playlist", after: 2)
        } catch {
            flash("Couldn't add to \(playlist.name): \(error)")
        }
    }

    /// The playlist tracks were last added to, offered first in "Add to Playlist" menus.
    var lastPlaylistId: String? { recentPlaylistIds.first }

    /// Playlists tracks were recently added to, most recent first; offered first by the ⇧P picker.
    private(set) var recentPlaylistIds: [String] = UserDefaults.standard.stringArray(forKey: "recentPlaylists") ?? []

    /// Sets star ratings in Apple Music (0 clears). The list and sync status show it right away; Music's answer
    /// (read back after writing) replaces it, and an error is reported rather than ignored.
    func setRating(_ stars: Int, for ids: [String]) {
        let ids = ids.filter { rows[$0] != nil }
        guard !ids.isEmpty else { return }
        let generation = ratings.begin(stars, ids: ids)
        if syncing { editedDuringSync = true }
        showRating(stars, for: ids)
        bridge.setRating(stars, ids: ids, generation: generation)
    }

    private func showRating(_ stars: Int, for ids: [String]) {
        let value = stars == 0 ? nil : stars
        var updated = rows
        var changed = false
        for id in ids where updated[id] != nil && updated[id]!.source.rating != value {
            updated[id]!.source.rating = value
            library?.tracks[id]?.rating = value
            changed = true
        }
        guard changed else { return }
        rows = updated
        evaluateStatus()
    }

    private func ratingFinished(_ r: MusicBridge.RatingResult) {
        if let stars = ratings.finish(r) { showRating(stars, for: [r.id]) }
        // Music's value is unknown: the next read must be applied even if the library looks unchanged.
        if r.confirmed == nil { librarySignature = nil }
        if let error = r.error {
            Log.error("ratings", "Setting \(r.requested)★ on \(r.id) failed: \(error) (\(error.status))")
            flash("Couldn't set the rating in Music: \(error)")
        }
        // Read Music again: right away if the write's outcome is unknown, else once the burst of ratings is over.
        scheduleReload("after setting ratings", after: r.confirmed == nil ? 0 : 3)
    }

    /// Re-reads Apple Music (ratings, titles, playlists edited there) and the active drive when the app becomes active.
    func refreshFromMusic() {
        guard loadState == .loaded else { return }
        scheduleReload("app became active", after: 0.3)
        if let id = activeDriveId, !job.running { Task { await refreshDrive(id) } }
    }

    @ObservationIgnored private var loadAttempt = UUID()

    /// Removes tracks from an Apple Music playlist (never from the library). Updates the list right
    /// away and puts them back if Music refuses.
    func remove(_ ids: [String], from playlist: SourcePlaylist) async {
        guard !playlist.isFolder, let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let before = playlists[i].trackIds
        let drop = Set(ids)
        editPlaylist(playlist.id) { $0.trackIds.removeAll { drop.contains($0) } }
        do {
            _ = try await bridge.run { _ in try AppleMusicWriter.remove(trackIds: ids, fromPlaylist: playlist.id) }
            flash("Removed \(ids.count) track\(ids.count == 1 ? "" : "s") from \(playlist.name)")
            scheduleReload("after removing from a playlist", after: 2)
        } catch {
            editPlaylist(playlist.id) { $0.trackIds = before }
            flash("Couldn't remove from \(playlist.name): \(error)")
        }
    }

    /// Opens System Settings at Automation, where Deckhand's access to Music is switched on.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Suggestions

    /// `candidates` ranked best guess first by what your ratings so far say you like (see
    /// `Suggestions`).
    func rankForReview(_ candidates: [TrackRow]) -> [Suggestion] {
        let rated = rows.values.filter { $0.rating > 0 }
        return Log.measure("suggest", "Ranking \(candidates.count) unrated tracks from \(rated.count) rated") {
            Suggestions.rank(candidates: candidates, rated: rated, playlists: playlists)
        }
    }

    // MARK: Quick Rate

    /// The running Quick Rate session, if any; the main column shows it instead of the track list.
    var review: Review?

    /// Tracks skipped ("not now") in Quick Rate, with when they may be offered again. Kept by
    /// Deckhand only: nothing is written to Music.
    @ObservationIgnored private var snoozes: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "reviewSnoozes") as? [String: Double] ?? [:]

    func snoozedUntil(_ id: String) -> Date? { snoozes[id].map(Date.init(timeIntervalSince1970:)) }

    func snooze(_ id: String, days: Int) {
        snoozes[id] = Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970
        UserDefaults.standard.set(snoozes, forKey: "reviewSnoozes")
    }

    func unsnooze(_ id: String) {
        snoozes[id] = nil
        UserDefaults.standard.set(snoozes, forKey: "reviewSnoozes")
    }

    /// Saves every star rating to Deckhand's backup folder (only when they've changed since the
    /// last backup). Runs at launch and when a Quick Rate session ends.
    func backUpRatings() {
        let tracks = rows.values.map(\.source)
        Task.detached {
            do {
                let backup = RatingsBackup(tracks: tracks)
                if let url = try backup.save() { Log.info("ratings", "Backed up \(backup.entries.count) ratings to \(url.lastPathComponent)") }
            } catch {
                Log.error("ratings", "Couldn't back up ratings: \(error)")
            }
        }
    }

    /// A short-lived message shown at the bottom of the window.
    private(set) var notice: String?

    func flash(_ text: String) {
        Log.info("notice", text)
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }

    // MARK: Listing

    var title: String {
        switch selection {
        case .playlist(let id): playlists.first { $0.id == id }?.name ?? "Playlist"
        case .needsAnalysis: "Needs Analysis"
        default: "All Tracks"
        }
    }

    var selectedPlaylist: SourcePlaylist? {
        if case .playlist(let id) = selection { return playlists.first { $0.id == id } }
        return nil
    }

    // Read on every track-list redraw (each selection change, each row update), so memoized: the
    // base by content and sidebar selection, the shown rows by filter and sort as well.
    private struct BaseKey: Equatable { var content: Int; var selection: SidebarItem? }
    private struct ShownKey: Equatable { var base: Int; var filter: TrackFilter; var sort: TrackSort?; var playing: TrackRow? }
    @ObservationIgnored private var baseKey: BaseKey?
    @ObservationIgnored private var shownKey: ShownKey?
    @ObservationIgnored private var baseVersion = 0
    @ObservationIgnored private var cachedListing = TrackListing()
    @ObservationIgnored private var unanalyzedCache: (content: Int, count: Int)?
    @ObservationIgnored private var onDriveCache: (key: [Int], count: Int)?

    /// The track list for the sidebar selection, filter and sort. `playing` matters only for
    /// "Mixes with playing".
    func listing(playing: TrackRow?) -> TrackListing {
        let bk = BaseKey(content: contentVersion, selection: selection)
        if bk != baseKey {
            baseKey = bk
            baseVersion &+= 1
            Log.measure("ui", "Listing \(title)") {
                let base = baseRows
                cachedListing.base = base
                cachedListing.minutes = Int(base.reduce(0) { $0 + $1.duration } / 60)
                cachedListing.genres = Array(Set(base.map(\.genre).filter { !$0.isEmpty })).sorted()
            }
        }
        let sk = ShownKey(base: baseVersion, filter: filter, sort: sort, playing: filter.mixesWithPlaying ? playing : nil)
        if sk != shownKey {
            let previous = shownKey?.sort == sort ? cachedListing.rows : []
            shownKey = sk
            Log.measure("ui", "Filtering and sorting \(title)") {
                let shown = TrackListing.filter(cachedListing.base, by: filter, playing: playing)
                cachedListing.rows = TrackListing.sort(shown, by: sort, previous: previous)
            }
            cachedListing.version &+= 1
        }
        return cachedListing
    }

    /// Tracks of the current sidebar selection, before filtering. Builds them; use `listing`.
    private var baseRows: [TrackRow] {
        switch selection {
        case .playlist:
            return selectedPlaylist.map { trackIds(of: $0).compactMap { rows[$0] } } ?? []
        case .needsAnalysis:
            return allIds.compactMap { rows[$0] }.filter { $0.checked && !$0.analyzed }
        default:
            return allIds.compactMap { rows[$0] }
        }
    }

    var unanalyzedCount: Int {
        if let c = unanalyzedCache, c.content == contentVersion { return c.count }
        let n = rows.values.reduce(0) { $0 + ($1.checked && !$1.analyzed ? 1 : 0) }
        unanalyzedCache = (contentVersion, n)
        return n
    }

    /// Tracks in `listing`'s base that are on the active drive now.
    func onDriveCount(_ listing: TrackListing) -> Int {
        guard let s = driveStatus else { return 0 }
        let key = [baseVersion, statusVersion, contentVersion]
        if let c = onDriveCache, c.key == key { return c.count }
        let n = listing.base.reduce(0) { $0 + (s.onDrive.contains($1.id) ? 1 : 0) }
        onDriveCache = (key, n)
        return n
    }

    /// Analyzed tracks that mix well out of `row`, closest in tempo and energy first.
    func suggestions(after row: TrackRow?, excluding: Set<String>, limit: Int = 6) -> [TrackRow] {
        guard let row, let key = row.key, let bpm = row.bpm else { return [] }
        let keys = Harmony.compatible(key)
        return rows.values
            .filter { !excluding.contains($0.id) && $0.id != row.id }
            .filter { r in r.key.map { keys.contains($0.alphanumeric) } ?? false }
            .filter { r in r.bpm.map { abs($0 / bpm - 1) <= Harmony.pitchRange } ?? false }
            .sorted { a, b in
                let da = abs((a.bpm ?? 0) - bpm) + Double(abs((a.energy ?? 5) - (row.energy ?? 5)))
                let db = abs((b.bpm ?? 0) - bpm) + Double(abs((b.energy ?? 5) - (row.energy ?? 5)))
                return da < db
            }
            .prefix(limit).map { $0 }
    }
}

/// Camelot-wheel mixing rules.
enum Harmony {
    /// Tempo difference a deck's pitch fader comfortably covers.
    static let pitchRange = 0.06

    /// Same key, ±1 on the wheel, and the relative major/minor.
    static func compatible(_ k: MusicalKey) -> Set<String> {
        let n = k.camelotNumber, letter = k.mode == .minor ? "A" : "B", other = k.mode == .minor ? "B" : "A"
        let up = n % 12 + 1, down = (n + 10) % 12 + 1
        return ["\(n)\(letter)", "\(up)\(letter)", "\(down)\(letter)", "\(n)\(other)"]
    }

    /// How a transition from `a` to `b` sounds, for the queue.
    static func transition(from a: TrackRow, to b: TrackRow) -> (text: String, good: Bool) {
        var parts: [String] = []
        var good = true
        if let ka = a.key, let kb = b.key {
            let step = (kb.camelotNumber - ka.camelotNumber + 12) % 12
            let relation: String
            switch (step, ka.mode == kb.mode) {
            case (0, true): relation = "same key"
            case (1, true), (11, true): relation = step == 1 ? "+1" : "−1"
            case (0, false): relation = "relative"
            case (2, true): relation = "energy boost"
            default: relation = "key clash"; good = false
            }
            parts.append("\(ka.alphanumeric) → \(kb.alphanumeric) · \(relation)")
        }
        if let ba = a.bpm, let bb = b.bpm {
            let d = bb - ba
            if abs(bb / ba - 1) > pitchRange { good = false }
            parts.append(abs(d) < 0.05 ? "same tempo" : String(format: "%+.1f BPM", d))
        }
        if let ea = a.energy, let eb = b.energy, ea != eb { parts.append(eb > ea ? "energy ↑" : "energy ↓") }
        return (parts.joined(separator: " · "), good)
    }
}
