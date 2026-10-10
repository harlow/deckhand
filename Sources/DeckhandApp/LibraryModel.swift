import AppKit
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

enum SyncState { case onDrive, pending, notOnDrive, noDrive }

enum PlaylistSync: Equatable { case synced, pending(Int), notOnDrive, noDrive }

struct Drive: Identifiable, Sendable {
    var volume: Volume
    var manifest: Manifest?
    var id: String { volume.url.path }
    var canSync: Bool { manifest.map { $0.entireLibrary == true || !$0.selectedPlaylistIds.isEmpty } ?? false }
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

@MainActor @Observable
final class LibraryModel {
    let cache: AnalysisCache? = try? AnalysisCache()

    private(set) var rows: [String: TrackRow] = [:] { didSet { invalidateSync(); contentVersion &+= 1 } }
    /// Library order: newest first.
    private(set) var allIds: [String] = [] { didSet { contentVersion &+= 1 } }
    private(set) var playlists: [SourcePlaylist] = [] { didSet { invalidateSync(); contentVersion &+= 1 } }
    /// Bumped whenever rows, allIds or playlists change; keys the memoized listing.
    private var contentVersion = 0
    private(set) var drives: [Drive] = [] { didSet { invalidateSync() } }
    private(set) var status: String?
    private(set) var artwork: (any ArtworkProvider)?
    var activeDriveId: String? {
        didSet {
            invalidateSync()
            if let name = activeDrive?.volume.name { UserDefaults.standard.set(name, forKey: "activeDrive") }
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

    private var scope: Set<String> = [] { didSet { invalidateSync() } }

    // Sync status is read for every visible row and every playlist badge on each redraw, so it's
    // memoized; any change to rows, playlists, drives or scope clears it.
    @ObservationIgnored private var syncCache: [String: SyncState] = [:]
    @ObservationIgnored private var playlistSyncCache: [String: PlaylistSync] = [:]
    @ObservationIgnored private var pendingCache: Int?
    @ObservationIgnored private var pendingBytesCache: Int64?
    @ObservationIgnored private var syncGeneration = 0

    private func invalidateSync() {
        syncCache.removeAll(keepingCapacity: true)
        playlistSyncCache.removeAll(keepingCapacity: true)
        pendingCache = nil
        pendingBytesCache = nil
        syncGeneration &+= 1
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

    func load() async {
        refreshDrives()
        observeMounts()
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
        let lib: SourceLibrary
        do {
            let start = Date()
            lib = try await Task.detached { try AppleMusicLibrary.load(allSongs: true) }.value
            Log.info("library", "Read Apple Music: \(lib.tracks.count) tracks, \(lib.playlists.count) playlists in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } catch {
            loadState = .failed("\(error)")
            Log.error("library", "Couldn't read Apple Music: \(error)")
            return
        }
        await apply(lib)
        backUpRatings()
        let start = Date()
        await loadAnalysis()
        Log.info("analysis", "Loaded cached analysis in \(String(format: "%.1f", Date().timeIntervalSince(start))) s; \(unanalyzedCount) tracks not analyzed")
    }

    /// Re-reads Apple Music. Touches nothing on the main thread when the library hasn't changed.
    func reloadLibrary() async {
        let start = Date()
        guard let (lib, signature) = try? await Task.detached(operation: { () throws -> (SourceLibrary, Int) in
            let lib = try AppleMusicLibrary.load(allSongs: true)
            return (lib, Self.signature(of: lib))
        }).value else { return }
        guard signature != librarySignature else {
            Log.info("library", "Apple Music unchanged (checked in \(Int(Date().timeIntervalSince(start) * 1000)) ms)")
            return
        }
        await apply(lib, signature: signature)
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
    private func apply(_ lib: SourceLibrary, signature: Int? = nil) async {
        let start = Date()
        let snapshot = rows, version = contentVersion
        let built = await Task.detached { (Self.merge(lib, into: snapshot), signature ?? Self.signature(of: lib)) }.value
        var merged = built.0
        // Rows changed meanwhile (analysis loaded, a rating set): merge into the current ones instead.
        if contentVersion != version { merged = Self.merge(lib, into: rows) }
        Log.measure("library", "Assigning rows") {
            if merged.changed { rows = merged.rows }
            if allIds != merged.allIds { allIds = merged.allIds }
            let named = Self.demoNamed(lib.playlists)
            if playlists != named { playlists = named }
            artwork = lib.artwork
            status = nil
            loadState = .loaded
            updateScope()
        }
        librarySignature = built.1
        Log.info("library", "Applied Apple Music in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(merged.changed ? "" : " (rows unchanged)")")
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

    /// Reads each track's cached analysis in the background (hashing files the cache hasn't seen).
    private func loadAnalysis() async {
        guard let cache else { return }
        let items = allIds.compactMap { rows[$0] }.filter { !$0.checked }.map { ($0.id, $0.location) }
        guard !items.isEmpty else { return }
        status = "Loading analysis…"
        await withTaskGroup(of: Loaded.self) { group in
            var pending = items.makeIterator()
            for _ in 0..<8 { if let (id, url) = pending.next() { group.addTask { Self.loadOne(id, url, cache) } } }
            var batch: [Loaded] = []
            var done = 0
            for await r in group {
                batch.append(r)
                done += 1
                if let (id, url) = pending.next() { group.addTask { Self.loadOne(id, url, cache) } }
                if batch.count >= 64 {
                    merge(batch)
                    batch = []
                    status = "Loading analysis… \(done) of \(items.count)"
                }
            }
            merge(batch)
        }
        try? cache.save()
        status = nil
    }

    nonisolated private static func loadOne(_ id: String, _ url: URL, _ cache: AnalysisCache) -> Loaded {
        guard let hash = try? cache.contentHash(of: url) else { return Loaded(id: id) }
        guard let s = cache.summary(forHash: hash) else { return Loaded(id: id, hash: hash) }
        let overview = Overview(s.overview, bins: AnalysisCache.Summary.overviewBins, cuesMs: s.cuesMs,
                                durationMs: s.durationSeconds * 1000)
        return Loaded(id: id, hash: hash, analysis: (s.bpm, s.key, s.energy, overview))
    }

    private func merge(_ batch: [Loaded]) {
        for r in batch {
            guard var row = rows[r.id] else { continue }
            row.checked = true
            row.hash = r.hash
            if let a = r.analysis {
                row.analyzed = true
                row.bpm = a.bpm
                row.key = a.key
                row.energy = a.energy
                row.overview = a.overview
            }
            rows[r.id] = row
        }
    }

    // MARK: Analysis

    /// The background sync or analysis run, shown in the right-hand pane. One at a time.
    let job = Job()

    /// Runs `deckhand analyze` for the whole library, then reloads what it produced.
    func analyzeLibrary() {
        guard !job.running else { flash("Wait for \(job.title.lowercased()) to finish"); return }
        job.run("Analyzing library", ["analyze"]) { [weak self] _ in self?.reloadUnanalyzed() }
    }

    /// Syncs a drive in the background (analyzing anything not yet analyzed), then re-reads its state.
    func sync(_ drive: Drive) {
        guard !job.running else { flash("Wait for \(job.title.lowercased()) to finish"); return }
        guard drive.canSync else {
            flash("Add a playlist to \(drive.volume.name) first (hover it in the sidebar and click Add)")
            return
        }
        job.run("Syncing \(drive.volume.name)", ["sync", drive.volume.url.path, "-y", "--analyze"]) { [weak self] _ in
            self?.refreshDrives()
            self?.reloadUnanalyzed()
        }
    }

    private func reloadUnanalyzed() {
        // One assignment: each write to `rows` clears the sync caches and rebuilds the listing.
        var updated = rows
        for (id, row) in rows where !row.analyzed && row.checked { updated[id]?.checked = false }
        rows = updated
        Task { await loadAnalysis() }
    }

    // MARK: Drive selection

    /// Bytes still to copy to the active drive: tracks it should hold but doesn't yet (Music's file sizes).
    var pendingBytes: Int64 {
        guard let m = activeDrive?.manifest else { return 0 }
        _ = rows.isEmpty
        if let cached = pendingBytesCache { return cached }
        let bytes = scope.reduce(Int64(0)) { sum, id in
            m.tracks[id] == nil ? sum + (rows[id]?.source.fileSize ?? 0) : sum
        }
        pendingBytesCache = bytes
        return bytes
    }

    /// True when what's waiting to copy is more than the active drive has free.
    var pendingWontFit: Bool {
        guard let drive = activeDrive else { return false }
        return pendingBytes > drive.volume.available
    }

    /// Whether the active drive holds every song (not only those in its playlists).
    var entireLibraryOnDrive: Bool { activeDrive?.manifest?.entireLibrary == true }

    /// Whether a playlist is on the active drive; a folder is when all the playlists in it are.
    func isOnDrive(_ p: SourcePlaylist) -> Bool {
        guard let m = activeDrive?.manifest else { return false }
        return isOnDrive(p, m)
    }

    private func isOnDrive(_ p: SourcePlaylist, _ m: Manifest) -> Bool {
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

    private func updateSelection(_ change: @escaping @Sendable (inout Manifest) -> Void) {
        guard let drive = activeDrive, drive.manifest != nil else { return }
        if job.running, job.title.hasSuffix(drive.volume.name) {
            flash("Wait for \(job.title.lowercased()) to finish")
            return
        }
        let volume = drive.volume
        Task {
            // Re-read first: the CLI may have saved a newer manifest since the drive was last read.
            let result: Result<Manifest, Error> = await Task.detached {
                Result {
                    guard var m = try Manifest.load(from: volume) else { throw SyncError.notInitialized(volume.name) }
                    change(&m)
                    try m.save(to: volume)
                    return try Manifest.load(from: volume) ?? m
                }
            }.value
            switch result {
            case .success(let m):
                guard let i = drives.firstIndex(where: { $0.id == drive.id }) else { return }
                drives[i].manifest = m
                updateScope()
                if pendingWontFit {
                    flash("That's \(Self.bytes(pendingBytes)) to copy, but \(volume.name) only has \(Self.bytes(volume.available)) free")
                }
            case .failure(let error):
                flash("Couldn't update \(volume.name): \(error)")
            }
        }
    }

    // MARK: Drives

    /// Re-reads mounted drives and their manifests off the main thread (USB reads can take seconds).
    func refreshDrives() {
        Task {
            let start = Date()
            let found = await Task.detached { Volume.removable().map { Drive(volume: $0, manifest: try? Manifest.load(from: $0)) } }.value
            Log.info("drives", "Read \(found.count) drive(s) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            setDrives(found)
        }
    }

    private func setDrives(_ found: [Drive]) {
        drives = found
        if activeDrive == nil {
            let saved = UserDefaults.standard.string(forKey: "activeDrive")
            activeDriveId = (drives.first { $0.manifest != nil && $0.volume.name == saved } ?? drives.first { $0.manifest != nil })?.id
        }
        updateScope()
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

    /// Tracks the active drive is meant to hold.
    private func updateScope() {
        guard let m = activeDrive?.manifest else { scope = []; return }
        if m.entireLibrary == true {
            scope = Set(allIds)
        } else {
            let selected = Set(m.selectedPlaylistIds)
            scope = Set(playlists.filter { selected.contains($0.id) }.flatMap(\.trackIds))
        }
    }

    func syncState(_ row: TrackRow) -> SyncState {
        guard let m = activeDrive?.manifest else { return .noDrive }
        if let cached = syncCache[row.id] { return cached }
        let state = computeSyncState(row, m)
        syncCache[row.id] = state
        return state
    }

    private func computeSyncState(_ row: TrackRow, _ m: Manifest) -> SyncState {
        if let t = m.tracks[row.id] {
            if let h = row.hash, h != t.contentHash { return .pending }
            if let f = t.metadataFingerprint, !Manifest.matches(f, SyncExecutor.metadataFingerprint(row.source)) { return .pending }
            if row.analyzed && t.analysisVersion != TrackAnalysis.currentVersion { return .pending }
            return scope.contains(row.id) ? .onDrive : .pending
        }
        return scope.contains(row.id) ? .pending : .notOnDrive
    }

    func playlistSync(_ p: SourcePlaylist) -> PlaylistSync {
        guard let m = activeDrive?.manifest else { return .noDrive }
        _ = rows.isEmpty  // keep observing rows when the answer comes from the cache
        if let cached = playlistSyncCache[p.id] { return cached }
        let state = computePlaylistSync(p, m)
        playlistSyncCache[p.id] = state
        return state
    }

    private func computePlaylistSync(_ p: SourcePlaylist, _ m: Manifest) -> PlaylistSync {
        guard isOnDrive(p, m) else { return .notOnDrive }
        let ids = trackIds(of: p)
        var changes = ids.filter { rows[$0].map { syncState($0) == .pending } ?? false }.count
        if !p.isFolder {
            let onDrive = ids.compactMap { m.tracks[$0]?.contentId }
            if m.playlists[p.id]?.contentIds != onDrive { changes = max(changes, 1) }
        }
        return changes == 0 ? .synced : .pending(changes)
    }

    /// Changes waiting for the active drive (tracks to copy or update, plus tracks no longer wanted).
    var pendingChanges: Int {
        guard let m = activeDrive?.manifest else { return 0 }
        _ = rows.isEmpty
        if let cached = pendingCache { return cached }
        let toWrite = scope.filter { id in rows[id].map { syncState($0) == .pending } ?? false }.count
        let toRemove = m.tracks.keys.filter { !scope.contains($0) }.count
        pendingCache = toWrite + toRemove
        return toWrite + toRemove
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

    func createPlaylist(named name: String) async {
        do {
            let id = try await Task.detached { try AppleMusicWriter.createPlaylist(named: name, isFolder: false, inFolder: nil) }.value
            playlists.append(SourcePlaylist(id: id, name: name))
            selection = .playlist(id)
        } catch {
            status = "Couldn't create playlist: \(error)"
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
            let missing = Set(try await Task.detached { try AppleMusicWriter.add(trackIds: fresh, toPlaylist: playlist.id) }.value)
            let added = fresh.filter { !missing.contains($0) }
            if let i = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[i].trackIds += added }
            updateScope()
            var text = "Added \(added.count) track\(added.count == 1 ? "" : "s") to \(playlist.name)"
            if already > 0 { text += " · \(already) already there" }
            if !missing.isEmpty { text += " · \(missing.count) not found in Music" }
            flash(text)
        } catch {
            flash("Couldn't add to \(playlist.name): \(error)")
        }
    }

    /// The playlist tracks were last added to, offered first in "Add to Playlist" menus.
    var lastPlaylistId: String? { recentPlaylistIds.first }

    /// Playlists tracks were recently added to, most recent first; offered first by the ⇧P picker.
    private(set) var recentPlaylistIds: [String] = UserDefaults.standard.stringArray(forKey: "recentPlaylists") ?? []

    /// Sets star ratings in Apple Music (0 clears). Updates the list right away; reverts if Music refuses.
    func setRating(_ stars: Int, for ids: [String]) {
        let before = ids.compactMap { id in rows[id].map { (id, $0.source.rating) } }
        for id in ids { rows[id]?.source.rating = stars == 0 ? nil : stars }
        Task {
            do {
                try await Task.detached { try AppleMusicWriter.setRating(stars, trackIds: ids) }.value
            } catch {
                for (id, old) in before { rows[id]?.source.rating = old }
                flash("Couldn't set rating in Music: \(error)")
            }
        }
    }

    /// Re-reads Apple Music (ratings, titles, playlists edited there), at most every 20 seconds.
    func refreshFromMusic() {
        guard Date().timeIntervalSince(lastRefresh) > 20, status == nil, loadState == .loaded else { return }
        lastRefresh = Date()
        Task { await reloadLibrary() }
    }

    @ObservationIgnored private var lastRefresh = Date()
    @ObservationIgnored private var loadAttempt = UUID()

    /// Removes tracks from an Apple Music playlist (never from the library). Updates the list right
    /// away and puts them back if Music refuses.
    func remove(_ ids: [String], from playlist: SourcePlaylist) async {
        guard !playlist.isFolder, let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let before = playlists[i].trackIds
        let drop = Set(ids)
        playlists[i].trackIds.removeAll { drop.contains($0) }
        updateScope()
        do {
            try await Task.detached { try AppleMusicWriter.remove(trackIds: ids, fromPlaylist: playlist.id) }.value
            flash("Removed \(ids.count) track\(ids.count == 1 ? "" : "s") from \(playlist.name)")
        } catch {
            if let j = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[j].trackIds = before }
            updateScope()
            flash("Couldn't remove from \(playlist.name): \(error)")
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

    /// Tracks in `listing`'s base that are on the active drive.
    func onDriveCount(_ listing: TrackListing) -> Int {
        guard activeDrive?.manifest != nil else { return 0 }
        let key = [baseVersion, syncGeneration, contentVersion]
        if let c = onDriveCache, c.key == key { return c.count }
        let n = listing.base.reduce(0) { $0 + (syncState($1) == .onDrive ? 1 : 0) }
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
