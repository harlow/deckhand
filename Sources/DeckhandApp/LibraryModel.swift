import AppKit
import DeckhandAppCore
import DeckhandCore
import DeckhandLibrary
import Foundation
import MusicSource
import Observation
import Sync
import UniformTypeIdentifiers

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
    var isReading = false
    var readError: String?
    var id: String { volume.url.path }
    var canSync: Bool {
        manifest.map { $0.entireLibrary == true || !$0.selectedPlaylistIds.isEmpty || !$0.tracks.isEmpty || !$0.playlists.isEmpty } ?? false
    }

    /// Reads a mounted drive's manifest and files. Off the main thread: USB reads can take seconds.
    nonisolated static func read(_ volume: Volume) -> Drive {
        do {
            let manifest = try Manifest.load(from: volume)
            return Drive(volume: volume, manifest: manifest, probe: manifest.map { DriveProbe.scan(volume, manifest: $0) })
        } catch {
            // An unreadable existing manifest is not an empty USB available for initialization.
            return Drive(volume: volume, readError: error.localizedDescription)
        }
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
    case leftover(driveId: String, drive: String, count: Int, details: [String])
    /// The sync stopped before writing because Music couldn't be read live.
}

@MainActor @Observable
final class LibraryModel {
    let cache: AnalysisCache?
    private(set) var source: SourceConnection?
    var choosingSource = false
    private(set) var connectingSource = false
    private(set) var recentSources: [SourceConnection] = []
    private(set) var hasLibrary = false
    private(set) var libraryID: String?
    private(set) var sourceError: String?
    private(set) var connections: [LibraryConnection] = []
    private(set) var sourceConflicts = 0
    var showingDestinations = false
    var showingUSBConnection = false
    var showingUSBChanges = false
    private(set) var exportingMusic = false
    private(set) var musicExportResult: String?
    @ObservationIgnored private var localStore: DeckhandLibraryStore?
    @ObservationIgnored private var appliedLibraryRevision: UInt64 = 0
    @ObservationIgnored private let libraryDirectory: URL
    @ObservationIgnored private let legacyDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let observesChanges: Bool
    @ObservationIgnored private let musicImport: (@Sendable () async throws -> SourceLibrary)?
    @ObservationIgnored private let driveReader: (@Sendable () -> [Drive])?
    private(set) var pendingSourceEdits = 0

    var playlistDestination: String { "Deckhand" }
    var sourceAvailable: Bool { hasLibrary && loadState == .loaded }
    var sourceCanChange: Bool { !job.running && !startingSync && !exportingMusic && !connectingSource && pendingSourceEdits == 0 }
    var canEditLibrary: Bool { sourceAvailable && !associatingUSB }
    private(set) var associatingUSB = false
    private(set) var usbAssociationError: String?
    var importConnections: [LibraryConnection] { connections.filter(\.isConnected) }
    private(set) var unavailableAudioIssues: [UnavailableAudioIssue] = []
    var unavailableTracks: Int { unavailableAudioIssues.count }

    func driveMatchesSource(_ drive: Drive) -> Bool {
        sourceAvailable && (drive.manifest?.acceptsSource(libraryID) ?? false)
    }

    func canAdoptDrive(_ drive: Drive) -> Bool {
        guard sourceAvailable, !drive.isReading, drive.readError == nil, let library else { return false }
        return drive.manifest?.canAdoptLibrary(library) == true
    }

    /// A proven older library can be previewed without writing its USB manifest. Execution still requires
    /// explicit reassociation; the CLI's owner check continues to reject an unassociated drive.
    func canPreviewDrive(_ drive: Drive) -> Bool { driveMatchesSource(drive) || canAdoptDrive(drive) }

    var selectedUSBPlaylists: [SourcePlaylist] {
        guard let drive = activeDrive, canPreviewDrive(drive), let manifest = drive.manifest else { return [] }
        let ids = Set(manifest.selectedPlaylistIds)
        return playlists.filter { !$0.isFolder && ids.contains($0.id) }
    }

    var wouldClearUSB: Bool {
        guard let drive = activeDrive, canPreviewDrive(drive), let m = drive.manifest else { return false }
        return m.entireLibrary != true && selectedUSBPlaylists.isEmpty && (!m.tracks.isEmpty || !m.playlists.isEmpty)
    }

    var usbIsUpToDate: Bool {
        guard let drive = activeDrive, !drive.isReading, drive.readError == nil,
              driveMatchesSource(drive), drive.canSync, let status = driveStatus else { return false }
        return status.complete && !status.wontFit && status.pendingCount == 0 && status.summary.unknown == 0
    }

    /// Opening the app checks the USB before offering an action. A different saved library identity
    /// requires explicit confirmation, even when the evaluator finds no music or playlist changes.
    var usbSyncEnabled: Bool {
        guard let drive = activeDrive else { return false }
        return sourceCanChange && sourceAvailable && !drive.isReading && !checkingStatus && !usbIsUpToDate
    }

    var usbPrimaryActionTitle: String {
        guard let drive = activeDrive, drive.readError == nil else { return "Sync" }
        if driveMatchesSource(drive) { return "Sync" }
        // A safe earlier-library preview already has a concrete sync plan. Its ownership
        // confirmation is part of Sync, rather than another setup operation.
        if canPreviewDrive(drive), pendingChanges > 0 { return "Sync" }
        return "Setup"
    }

    var usbToolbarStatusText: String? {
        guard let drive = activeDrive, !job.running, !drive.isReading, !checkingStatus, !usbIsUpToDate else { return nil }
        if drive.readError != nil { return "USB unavailable" }
        if drive.manifest == nil { return "Set up USB" }
        if !canPreviewDrive(drive) { return "Different library" }
        return usbStatusText
    }

    var usbToolbarNeedsAction: Bool {
        guard let drive = activeDrive, usbToolbarStatusText != nil else { return false }
        return !driveMatchesSource(drive) || pendingChanges > 0 || pendingWontFit
    }

    func usbLibraryMissingItems(for drive: Drive) -> String? {
        guard let manifest = drive.manifest, let library else { return nil }
        let tracks = Set(manifest.tracks.keys).subtracting(library.tracks.keys).count
        let playlists = Set(manifest.playlists.keys).union(manifest.selectedPlaylistIds)
            .subtracting(library.playlists.map(\.id)).count
        var items: [String] = []
        if tracks > 0 { items.append("\(tracks.formatted()) \(tracks == 1 ? "track" : "tracks")") }
        if playlists > 0 { items.append("\(playlists.formatted()) \(playlists == 1 ? "playlist" : "playlists")") }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: " and ") + " from this USB \(tracks + playlists == 1 ? "isn't" : "aren't") in this Deckhand library."
    }

    var usbStatusText: String {
        guard let drive = activeDrive else { return "No USB connected" }
        if drive.isReading { return "Checking USB…" }
        if drive.readError != nil { return "USB unavailable" }
        if drive.manifest == nil { return "Not set up" }
        guard canPreviewDrive(drive) else { return "Needs attention" }
        guard let status = driveStatus else { return "Checking changes…" }
        if status.wontFit { return "Won't fit" }
        if status.pendingCount > 0 {
            return "\(status.pendingCount.formatted()) \(status.pendingCount == 1 ? "change" : "changes") to sync"
        }
        if status.summary.unknown > 0 { return "\(status.summary.unknown.formatted()) tracks to check" }
        if !status.complete { return "Check sync details" }
        if !driveMatchesSource(drive) { return "Link library" }
        if !drive.canSync { return "Choose playlists" }
        return "Up to date"
    }

    func adoptDrive(_ drive: Drive, showNotice: Bool = true) async {
        guard sourceCanChange, let library, let id = libraryID, canAdoptDrive(drive) else { return }
        let expectedOwner = drive.manifest?.sourceID
        let expectedGeneration = drive.manifest?.generationNumber
        let expectedDevice = drive.manifest?.deviceId
        let expectedRevision = appliedLibraryRevision
        let draft = selectionDraft(for: drive)
        let draftKey = selectionDraftKey(for: drive)
        let previousDeckhand = expectedOwner?.hasPrefix("deckhand:") == true
        let cache = cache
        pendingSourceEdits += 1
        associatingUSB = true
        usbAssociationError = nil
        defer { pendingSourceEdits -= 1; associatingUSB = false }
        do {
            // An older local library needs audio continuity proof as well as IDs. Only the USB's saved
            // tracks are checked, on explicit association; opening the library never hashes all music.
            if previousDeckhand, let saved = drive.manifest {
                try await Task.detached {
                    guard let cache else { throw DeckhandLibraryError.invalid("Couldn't check this USB's music. Try again.") }
                    for (trackID, record) in saved.tracks {
                        guard let track = library.tracks[trackID], let location = track.location,
                              (try? cache.contentHash(of: location)) == record.contentHash else {
                            throw DeckhandLibraryError.invalid("Couldn't verify “\(library.tracks[trackID]?.title ?? trackID)” against the USB. Its audio is unavailable or doesn't match. The USB was unchanged; restore the matching file and try again.")
                        }
                    }
                }.value
            }
            guard appliedLibraryRevision == expectedRevision else {
                throw DeckhandLibraryError.invalid("Your library changed while checking this USB. Review its changes again.")
            }
            let manifest = try await Task.detached {
                try Manifest.edit(on: drive.volume) { manifest in
                    guard manifest.sourceID == expectedOwner, manifest.deviceId == expectedDevice,
                          manifest.generationNumber == expectedGeneration, manifest.canAdoptLibrary(library) else {
                        throw DeckhandLibraryError.invalid("This USB changed while you were reviewing it. Review its changes again.")
                    }
                    manifest.sourceID = id
                    manifest.format = Manifest.currentFormat
                    if let draft {
                        manifest.selectedPlaylistIds = draft.playlistIDs
                        manifest.entireLibrary = draft.entireLibrary
                    }
                }
            }.value
            if let draftKey { defaults.removeObject(forKey: draftKey) }
            setManifest(manifest, for: drive.id)
            if showNotice { flash("\(drive.volume.name) is ready. Its playlist selection was kept.") }
        } catch {
            usbAssociationError = error.localizedDescription
            flash("Couldn't use this library: \(error.localizedDescription)")
            await refreshDrive(drive.id)
        }
    }

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
            if let name = activeDrive?.volume.name { defaults.set(name, forKey: "activeDrive") }
            evaluateStatus()
        }
    }
    var selection: SidebarItem? = .all {
        didSet {
            let value: String? = switch selection {
            case .playlist(let id): id
            case .needsAnalysis: "needsAnalysis"
            default: nil
            }
            defaults.set(value, forKey: "selection")
            Log.info("ui", "Selected \(title)")
        }
    }

    private static func savedSelection(in defaults: UserDefaults) -> SidebarItem {
        switch defaults.string(forKey: "selection") {
        case nil: .all
        case "needsAnalysis": .needsAnalysis
        case "suggestions": .all   // a sidebar item that no longer exists
        case let id?: .playlist(id)
        }
    }
    var filter = TrackFilter()
    var sort: TrackSort?

    /// The saved Deckhand library shared by the UI, analysis, and USB sync.
    @ObservationIgnored private var library: SourceLibrary?
    /// Every Apple Event the app sends goes through this one serial queue.
    @ObservationIgnored private var bridge: MusicBridge!
    @ObservationIgnored private var driveReads = ReadLedger()

    init(libraryDirectory: URL = DeckhandLibraryStore.defaultDirectory,
         legacyDirectory: URL? = nil, defaults: UserDefaults = .standard,
         observesChanges: Bool = true, cache: AnalysisCache? = try? AnalysisCache(),
         musicImport: (@Sendable () async throws -> SourceLibrary)? = nil,
         driveReader: (@Sendable () -> [Drive])? = nil) {
        self.cache = cache
        self.libraryDirectory = libraryDirectory
        self.legacyDirectory = legacyDirectory ?? (ProcessInfo.processInfo.environment["DECKHAND_LIBRARY_DIR"] == nil
            ? LocalLibraryStore.directory : libraryDirectory.appendingPathComponent("LegacyLibraries"))
        self.defaults = defaults
        self.observesChanges = observesChanges
        self.musicImport = musicImport
        self.driveReader = driveReader
        if let data = defaults.data(forKey: "librarySources") {
            recentSources = (try? JSONDecoder().decode([SourceConnection].self, from: data)) ?? []
        }
        selection = Self.savedSelection(in: defaults)
        recentPlaylistIds = defaults.stringArray(forKey: "recentPlaylists") ?? []
        collapsedPlaylistFolders = Set(defaults.stringArray(forKey: folderExpansionKey) ?? [])
        snoozes = defaults.dictionary(forKey: "reviewSnoozes") as? [String: Double] ?? [:]
        bridge = MusicBridge { _ in } // Import reads only; local edits never enqueue Music writes.
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
    enum StartupScreen: Equatable {
        case loading, sourceChooser, workspace
        case failed(String)
    }

    /// An unopened library is unknown, not a first launch. Wait for the saved-library read before onboarding.
    var startupScreen: StartupScreen {
        switch loadState {
        case .loading, .slow: .loading
        case .failed(let error): .failed(error)
        case .loaded: hasLibrary ? .workspace : .sourceChooser
        }
    }
    /// Whether Music could be read live on the last library read.
    private(set) var live = LiveState.unknown

    func load() async {
        if observesChanges { refreshDrives(); observeMounts() }
        do {
            localStore = try DeckhandLibraryStore(directory: libraryDirectory)
            if !CommandLine.arguments.contains("--choose-source") {
                try await localStore?.migrateLegacy(recentSources, directory: legacyDirectory)
            }
            if let snapshot = await localStore?.snapshot(checkAvailability: true) { applyLocal(snapshot) }
            if CommandLine.arguments.contains("--choose-source"), hasLibrary { choosingSource = true }
        } catch {
            loadState = .failed(error.localizedDescription)
            sourceError = error.localizedDescription
        }
    }

    func retryLoad() async {
        await closeLibrary()
        loadState = .loading
        sourceError = nil
        await load()
    }

    func startEmptyLibrary() async {
        guard let localStore, sourceCanChange else { return }
        do { applyLocal(try await localStore.startEmpty()); choosingSource = false }
        catch { flash(error.localizedDescription) }
    }

    func disconnectSource() async {
        guard let localStore, sourceCanChange else { return }
        scheduledReload?.cancel()
        do { applyLocal(try await localStore.disconnectSource()) }
        catch { flash(error.localizedDescription) }
    }

    /// Changing the update default never imports again or changes the saved library.
    func setPrimaryImport(_ id: String?) async {
        guard let localStore, sourceCanChange else { return }
        do { applyLocal(try await localStore.selectSource(id)) }
        catch { flash("Couldn't change the default import: \(error.localizedDescription)") }
    }

    func removeImport(_ id: String) async {
        guard let localStore, sourceCanChange else { return }
        do { applyLocal(try await localStore.removeConnection(id)) }
        catch { flash("Couldn't remove the import connection: \(error.localizedDescription)") }
    }

    /// Test teardown releases the single-writer lock before reopening the same library.
    func closeLibrary() async { scheduledReload?.cancel(); await localStore?.close(); localStore = nil }

    /// Selecting a folder/XML never imports files into Music or modifies the source file.
    func chooseSource(_ kind: SourceConnection.Kind) {
        guard sourceCanChange else { flash("Wait for the current operation to finish before importing music"); return }
        if kind == .music { Task { await connect(SourceConnection(kind: .music)) }; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind == .rekordbox
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Music"
        panel.message = kind == .folder ? "Audio files stay in this folder. Playlists and ratings are saved in Deckhand."
            : "In Rekordbox, choose File → Export Collection in xml format, then select that XML file."
        if kind == .rekordbox { panel.allowedContentTypes = [.xml] }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let connection = self.recentSources.first { $0.kind == kind && $0.location == url.standardizedFileURL }
                ?? SourceConnection(kind: kind, location: url)
            Task { await self.connect(connection) }
        }
    }

    func connect(_ connection: SourceConnection, makePrimary: Bool? = nil) async {
        guard sourceCanChange, let localStore else { return }
        let setPrimary = makePrimary ?? (source?.id == connection.id || importConnections.allSatisfy { $0.lastImported == nil })
        connectingSource = true
        scheduledReload?.cancel()
        sourceError = nil
        defer { connectingSource = false }
        do {
            let snapshot: DeckhandLibrarySnapshot
            if connection.kind == .music {
                let imported: SourceLibrary
                if let musicImport { imported = try await musicImport() }
                else {
                    var read = try await Task.detached { try AppleMusicLibrary.load(allSongs: true) }.value
                    let liveRead = await readLive()
                    if let fields = liveRead.fields { MusicLive.overlay(fields, onto: &read) }
                    live = liveRead.state
                    imported = read
                }
                snapshot = try await localStore.importLibrary(imported, from: connection, makePrimary: setPrimary)
            } else { snapshot = try await localStore.refresh(connection, makePrimary: setPrimary) }
            applyLocal(snapshot)
            choosingSource = false
        } catch {
            try? await localStore.recordFailure(connection, error: error.localizedDescription)
            applyLocal(await localStore.snapshot(checkAvailability: true))
            sourceError = "Couldn't import \(connection.name): \(error.localizedDescription). Your Deckhand playlists are still saved."
            if !hasLibrary { loadState = .loaded }
            Log.error("library", sourceError ?? error.localizedDescription)
        }
    }

    /// Import history names the exact input; re-importing never relies on an update default.
    func reimport(_ connection: SourceConnection) async {
        await connect(connection, makePrimary: false)
    }

    /// The one-time confirmation verifies ownership before continuing the requested sync.
    func syncWithCurrentLibrary(_ drive: Drive) async {
        await adoptDrive(drive, showNotice: false)
        guard let current = activeDrive, current.id == drive.id,
              driveMatchesSource(current), usbAssociationError == nil else { return }
        showingUSBChanges = false
        if !usbIsUpToDate { requestSync() }
    }

    /// The same primary action handles a new USB, a legacy USB, and everyday syncing.
    func requestSync() {
        guard let drive = activeDrive, sourceAvailable, sourceCanChange else { return }
        if driveMatchesSource(drive) {
            if wouldClearUSB { showingUSBChanges = true } else { sync(drive) }
        }
        else if canAdoptDrive(drive) { showingUSBChanges = true }
        else { showingUSBConnection = true }
    }

    func initializeDrive(_ drive: Drive) {
        guard sourceAvailable, sourceCanChange, drive.manifest == nil, drive.readError == nil, !drive.isReading else { return }
        job.run("Setting up \(drive.volume.name)", ["init", drive.volume.url.path]) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.showingUSBConnection = false
                Task { await self.refreshDrive(drive.id) }
                self.flash("Check the playlists you want on USB in the sidebar, then Sync.")
            }
        }
    }

    func exportRekordbox(sourceID: String? = nil) {
        guard let localStore, sourceAvailable, pendingSourceEdits == 0 else { return }
        guard let id = sourceID ?? connections.first(where: { $0.connection.kind == .rekordbox })?.id else { return }
        Task {
            do {
                let export = try await localStore.rekordboxExport(for: id)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.xml]
                panel.nameFieldStringValue = "Deckhand.xml"
                panel.message = "Export your Deckhand library. Select the saved XML as the Imported Library in Rekordbox."
                panel.begin { [weak self] response in
                    guard response == .OK, let destination = panel.url else { return }
                    Task {
                        do {
                            try await Task.detached { try export.write(to: destination) }.value
                            self?.flash("Exported Deckhand playlists to XML. Import the XML playlists in Rekordbox.")
                        } catch { self?.flash("Couldn't export playlists: \(error.localizedDescription)") }
                    }
                }
            } catch { flash(error.localizedDescription) }
        }
    }

    func exportMusic(playlistIDs: [String], includeRatings: Bool = false, destination: any MusicDestination = AppleMusicDestination()) async {
        guard let localStore, sourceAvailable, sourceCanChange else { return }
        exportingMusic = true
        musicExportResult = nil
        defer { exportingMusic = false }
        do {
            var plan = try await localStore.musicExport(playlistIDs: playlistIDs)
            if !includeRatings { plan.ratingIDs = [] }
            _ = try await MusicExport.execute(plan, destination: destination) { receipt in
                try await localStore.saveMusicReceipt(receipt)
            }
            musicExportResult = "Saved \(plan.playlists.count) playlist(s) to the Deckhand folder in Music."
        } catch { musicExportResult = "Music export stopped: \(error.localizedDescription)" }
    }

    private func sourceArguments() throws -> [String] {
        guard sourceAvailable, let library else { throw LibrarySourceError.unavailable("Reconnect your library before continuing.") }
        guard pendingSourceEdits == 0 else { throw LibrarySourceError.unavailable("Wait for playlist and rating changes to finish saving.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-source-\(UUID().uuidString).json")
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
        return ["--source-library", url.path]
    }

    private func removeSnapshot(_ args: [String]) {
        if args.count == 2 { try? FileManager.default.removeItem(atPath: args[1]) }
    }

    /// Reads the saved library only. External changes arrive through Add Music or an explicit re-import.
    func readLibrary() async {
        guard sourceCanChange else { return }
        if let snapshot = await localStore?.snapshot(checkAvailability: true) { applyLocal(snapshot) }
    }

    func chooseAudioFile(for issue: UnavailableAudioIssue, completion: @escaping (String?) -> Void) {
        guard sourceCanChange else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Use Audio File"
        panel.message = "Choose the audio for “\(issue.track.title)”. Its playlists and rating will be kept."
        if let url = issue.track.location { panel.directoryURL = url.deletingLastPathComponent() }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do { try await self.locateAudioFile(for: issue.id, at: url); completion(nil) }
                catch { completion(error.localizedDescription) }
            }
        }
    }

    func locateAudioFile(for id: String, at url: URL) async throws {
        guard sourceCanChange, let localStore else { throw DeckhandLibraryError.invalid("Wait for the current operation to finish.") }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        let snapshot = try await localStore.locateAudioFile(for: id, at: url)
        noteEdit()
        applyLocal(snapshot)
    }

    func reloadLibrary(_ reason: String) async throws {
        // USB status and execution use the saved Deckhand library, never an implicit external import.
        if let snapshot = await localStore?.snapshot(checkAvailability: true) { applyLocal(snapshot) }
    }

    @ObservationIgnored private var askingAccess = false

    /// Music's live fields, unless they can't be read. Access is checked first without sending anything; if the
    /// user hasn't been asked yet, the prompt is shown off the Music queue (it can sit unanswered behind other
    /// windows, and rating writes and Sync mustn't wait on it) and the library is read again once it's answered.
    private func readLive() async -> (fields: [String: LiveTrack]?, sequence: Int?, state: LiveState) {
        switch await Task.detached(operation: { MusicEvents.access(ask: false) }).value {
        case .notRunning: return (nil, nil, .notRunning)
        case .denied: return (nil, nil, .unavailable(MusicEvents.Failure(MusicEvents.Failure.notPermitted)))
        case .undecided:
            askForAccess()
            return (nil, nil, .unknown)
        case .granted, .other: break
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

    private func askForAccess() {
        guard !askingAccess else { return }
        askingAccess = true
        Task {
            let answer = await withCheckedContinuation { (c: CheckedContinuation<MusicEvents.Access, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: MusicEvents.access(ask: true)) }
            }
            askingAccess = false
            Log.info("library", "Music access: \(answer)")
            scheduleReload("Music access answered", after: 0)
        }
    }

    nonisolated private static func merge(_ lib: SourceLibrary, into old: [String: TrackRow])
        -> (rows: [String: TrackRow], allIds: [String], changed: Bool) {
        var rows = old.filter { lib.tracks[$0.key]?.location != nil }
        var changed = rows.count != old.count
        for t in lib.tracks.values {
            guard let url = t.location else { continue }
            if var row = rows[t.id] {
                // Refresh what may have been edited in Music; keep the loaded analysis.
                let fileChanged = row.location != url || row.source.fileSize != t.fileSize || row.source.modifiedDate != t.modifiedDate
                row.source = t
                row.title = t.title
                row.artist = t.artist ?? ""
                row.genre = t.genre ?? ""
                row.duration = t.durationSeconds ?? 0
                // A moved or rewritten file (Music rewrites tags) has a new hash key: hash it again.
                if fileChanged {
                    row.location = url
                    row.checked = false
                    row.hash = nil
                    row.analyzed = false
                    row.bpm = nil
                    row.key = nil
                    row.energy = nil
                    row.overview = nil
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
        var location: URL
        var hash: String?
        var analysis: (bpm: Double, key: MusicalKey?, energy: Int?, overview: Overview)?
    }

    @ObservationIgnored private var loadingAnalysis = false

    /// Opening the workspace reads cached results only. Audio reads belong to explicit Analyze/Sync actions,
    /// so a permission prompt or inaccessible file cannot stall all the other cached results at startup.
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
        guard let hash = cache.cachedContentHash(of: url) else { return Loaded(id: id, location: url) }
        guard let s = cache.summary(forHash: hash) else { return Loaded(id: id, location: url, hash: hash) }
        let overview = Overview(s.overview, bins: AnalysisCache.Summary.overviewBins, cuesMs: s.cuesMs,
                                durationMs: s.durationSeconds * 1000)
        return Loaded(id: id, location: url, hash: hash, analysis: (s.bpm, s.key, s.energy, overview))
    }

    private func merge(_ batch: [Loaded]) {
        guard !batch.isEmpty else { return }
        var updated = rows
        for r in batch {
            guard var row = updated[r.id], row.location == r.location else { continue }
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
        let args: [String]
        do { args = try sourceArguments() } catch { flash(error.localizedDescription); return }
        job.run("Analyzing library", ["analyze"] + args) { [weak self] _ in
            self?.removeSnapshot(args)
            let cache = self?.cache
            Task {
                await Task.detached { cache?.reloadFromDisk() }.value
                self?.reloadUnanalyzed()
            }
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
        guard let s = shownStatus, s.driveId == activeDriveId, let drive = activeDrive,
              drive.manifest != nil, canPreviewDrive(drive) else { return nil }
        return s
    }
    /// The active drive's status hasn't been evaluated yet ("Checking…").
    var checkingStatus: Bool { activeDrive.map { canPreviewDrive($0) && driveStatus == nil } ?? false }
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
        guard sourceAvailable, let cache, let library, let drive = activeDrive, canPreviewDrive(drive), var manifest = drive.manifest, let probe = drive.probe else {
            // Nothing to evaluate: don't leave a sync's verification holding back later results.
            if verifyNext, statusStore.awaitingVerification {
                statusStore.reset()
                publishStatus()
                endSyncFlow()
            }
            verifyNext = false
            return
        }
        if !driveMatchesSource(drive) { manifest.sourceID = libraryID }
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
            if outcome != .stale { hashUnknown(result) }
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
            if warnOnLeftover && !editedDuringSync {
                syncNotice = .leftover(driveId: drive.id, drive: drive.volume.name, count: s.pendingCount, details: s.details)
            }
            endSyncFlow()
        case .verified:
            Log.info("sync", "\(drive.volume.name) verified up to date after syncing")
            endSyncFlow()
        case .applied, .stale:
            break
        }
    }

    /// Tracks whose hash isn't known at their file's current size and date are hashed again in the background
    /// (once each until the library changes), then evaluated again.
    @ObservationIgnored private var rehashTried = Set<String>()

    private func hashUnknown(_ result: DriveStatus) {
        guard result.summary.unknown > 0 else { return }
        let ids = result.tracks.compactMap { $0.value == .unknown && rows[$0.key]?.checked == true && !rehashTried.contains($0.key) ? $0.key : nil }
        guard !ids.isEmpty else { return }
        rehashTried.formUnion(ids)
        var updated = rows
        for id in ids { updated[id]?.checked = false }
        rows = updated
        Task { await loadAnalysis() }
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
    func sync(_ drive: Drive) {
        guard !job.running, !startingSync else { flash("Wait for \(job.title.lowercased()) to finish"); return }
        guard pendingSourceEdits == 0 else { flash("Wait for playlist and rating changes to finish saving"); return }
        guard driveMatchesSource(drive) else { flash(sourceAvailable ? SyncError.sourceMismatch.description : "Reconnect your library before syncing"); return }
        guard drive.canSync else {
            flash("Check a playlist in the sidebar to include it on \(drive.volume.name)")
            return
        }
        syncNotice = nil
        syncSerial += 1
        syncFlowActive = true
        editedDuringSync = false
        startingSync = true
        Task {
            // Ratings still being written go first, so the sync reads them.
            defer { startingSync = false }
            guard !job.running else {
                flash("Wait for \(job.title.lowercased()) to finish")
                endSyncFlow()
                return
            }
            var args = ["sync", drive.volume.url.path, "-y", "--analyze"]
            let sourceArgs: [String]
            do {
                try await reloadLibrary("before syncing")
                sourceArgs = try sourceArguments()
            } catch { flash("Couldn't read source: \(error.localizedDescription)"); endSyncFlow(); return }
            args += sourceArgs
            syncingDriveId = drive.id
            job.run("Syncing \(drive.volume.name)", args, kind: .sync(driveID: drive.id, driveName: drive.volume.name)) { [weak self] ok in
                self?.removeSnapshot(sourceArgs)
                self?.syncFinished(drive, ok: ok)
            }
        }
    }

    /// The drive the app's sync is writing, while it runs.
    private(set) var syncingDriveId: String?
    @ObservationIgnored private var startingSync = false
    /// Whether the verification after the current sync should warn about anything still pending.
    @ObservationIgnored private var warnOnLeftover = false
    /// From clicking Sync until its verification lands. Edits meanwhile (here or in Music) explain work left after
    /// the sync, so they don't get a warning.
    @ObservationIgnored private var syncFlowActive = false
    @ObservationIgnored private var editedDuringSync = false
    /// Numbers syncs, so a re-read still running for an earlier sync can't issue a later one's verification.
    @ObservationIgnored private var syncSerial = 0

    private func noteEdit() {
        if syncFlowActive { editedDuringSync = true }
    }

    private func endSyncFlow() {
        syncFlowActive = false
        warnOnLeftover = false
    }

    private func syncFinished(_ drive: Drive, ok: Bool) {
        syncingDriveId = nil
        let serial = syncSerial
        let verifying = drive.id == activeDriveId
        if verifying {
            statusStore.syncFinished(driveId: drive.id, report: job.report)
            publishStatus()
        }
        let edits = queuedEdits.removeValue(forKey: drive.id) ?? []
        // Leftovers are worth a warning only when nothing explains them: the sync succeeded (a failure's error is
        // in the job card) and nothing was edited meanwhile (checked again when the verification lands).
        warnOnLeftover = verifying && ok && edits.isEmpty
        let cache = cache
        Task {
            if !edits.isEmpty { await write(edits, to: drive) }
            await Task.detached { cache?.reloadFromDisk() }.value
            async let reloaded: Void? = try? reloadLibrary("after syncing")
            async let refreshed: Void = refreshDrive(drive.id)
            _ = await (reloaded, refreshed)
            reloadUnanalyzed()
            guard serial == syncSerial else { return }
            if drive.id == activeDriveId {
                evaluateStatus(verify: true)
            } else {
                endSyncFlow()
            }
        }
    }

    // MARK: Sidebar navigation

    private(set) var trackFocusRequest = 0

    func focusTrackList() { trackFocusRequest &+= 1 }

    func openSidebarItem(_ item: SidebarItem) {
        selection = item
        focusTrackList()
    }

    /// Sidebar order stays the same regardless of USB selection or connection.
    var sidebarOrder: [SidebarItem] {
        let entries = playlistEntries
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
    var entireLibraryOnDrive: Bool { activeDrive.map { canPreviewDrive($0) && $0.manifest?.entireLibrary == true } ?? false }

    /// Whether a playlist is on the active drive; a folder is when all the playlists in it are.
    func isOnDrive(_ p: SourcePlaylist) -> Bool {
        guard let drive = activeDrive, canPreviewDrive(drive), let m = drive.manifest else { return false }
        let leaves = leafPlaylistIds(of: p)
        return !leaves.isEmpty && Set(leaves).isSubset(of: m.selectedPlaylistIds)
    }

    func hasAnyPlaylistOnDrive(_ p: SourcePlaylist) -> Bool {
        guard let drive = activeDrive, canPreviewDrive(drive), let m = drive.manifest else { return false }
        return leafPlaylistIds(of: p).contains(where: m.selectedPlaylistIds.contains)
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

    /// Choices for a USB from an earlier library stay on this computer until the user links it.
    /// Keyed by this library and the USB's stable device identity, so a remount or restart keeps them.
    private struct USBSelectionDraft: Codable, Sendable {
        var owner: String?
        var playlistIDs: [String]
        var entireLibrary: Bool
    }

    private func selectionDraftKey(for drive: Drive) -> String? {
        guard let libraryID, let manifest = drive.manifest else { return nil }
        return "usbSelectionDraft:\(libraryID):\(manifest.deviceId)"
    }

    private func selectionDraft(for drive: Drive) -> USBSelectionDraft? {
        guard let key = selectionDraftKey(for: drive), let data = defaults.data(forKey: key),
              let draft = try? JSONDecoder().decode(USBSelectionDraft.self, from: data),
              draft.owner == drive.manifest?.sourceID else { return nil }
        return draft
    }

    /// Selection edits made while the app's sync holds a drive, saved when it finishes.
    @ObservationIgnored private var queuedEdits: [String: [SelectionEdit]] = [:]

    /// Applies a selection edit: shown right away, saved to the drive's newest manifest with `Manifest.edit`, then the
    /// view takes what was saved. While this app syncs the drive the edit waits for the sync (the CLI holds its lock).
    private func updateSelection(_ change: @escaping SelectionEdit) {
        guard !associatingUSB else { return }
        guard let drive = activeDrive, var m = drive.manifest else { return }
        guard driveMatchesSource(drive) else {
            guard canAdoptDrive(drive), let key = selectionDraftKey(for: drive) else { return }
            change(&m)
            let draft = USBSelectionDraft(owner: m.sourceID, playlistIDs: m.selectedPlaylistIds,
                                          entireLibrary: m.entireLibrary == true)
            guard let data = try? JSONEncoder().encode(draft) else { return }
            defaults.set(data, forKey: key)
            setManifest(m, for: drive.id)
            noteEdit()
            return
        }
        let sourceID = libraryID ?? "deckhand"
        let originalChange = change
        let change: SelectionEdit = { m in
            m.sourceID = sourceID
            m.format = Manifest.currentFormat
            originalChange(&m)
        }
        change(&m)
        setManifest(m, for: drive.id)
        noteEdit()
        if syncingDriveId == drive.id {
            queuedEdits[drive.id, default: []].append(change)
            flash("Saved to \(drive.volume.name) when the sync finishes")
            return
        }
        Task { await write([change], to: drive, expectedSource: sourceID) }
    }

    private func write(_ edits: [SelectionEdit], to drive: Drive, expectedSource: String? = nil) async {
        let volume = drive.volume
        let expectedSource = expectedSource ?? libraryID
        let result: Result<Manifest, Error> = await Task.detached {
            Result { try Manifest.edit(on: volume) { m in
                guard m.acceptsSource(expectedSource) else { throw SyncError.sourceMismatch }
                edits.forEach { $0(&m) }
            } }
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

    /// Replaces a drive's manifest with one this app just made or saved; reads begun before can't overwrite it (they
    /// can still bring newer files and free space: see `merged`).
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
            let reader = driveReader
            // Publish mounted volumes first. A slow manifest or permission prompt on one USB
            // mustn't hide every other drive; each detailed read applies independently.
            let found = await Task.detached {
                reader?() ?? Volume.removable().filter { !$0.isReadOnly }.map { Drive(volume: $0, isReading: true) }
            }.value
            Log.info("drives", "Read \(found.count) drive(s) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            setDrives(found, token: token)
            if reader == nil {
                for drive in found { Task { await self.refreshDrive(drive.id) } }
            }
        }
    }

    /// Re-reads one drive; returns once applied (or superseded by a newer read).
    func refreshDrive(_ id: String) async {
        guard let volume = drives.first(where: { $0.id == id })?.volume else { return }
        let token = driveReads.begin()
        let reader = driveReader
        let drive = await Task.detached {
            if let reader { return reader().first { $0.id == id } }
            return (try? Volume(url: volume.url)).map(Drive.read)
        }.value
        guard let drive else {
            if let i = drives.firstIndex(where: { $0.id == id }), driveReads.accept(id, token) {
                drives[i].isReading = false
                drives[i].readError = "This USB is no longer available. Reconnect it and try again."
                drives[i].manifest = nil
                drives[i].probe = nil
                evaluateStatus()
            }
            return
        }
        guard let i = drives.firstIndex(where: { $0.id == id }), let d = merged(drive, onto: drives[i], token: token) else { return }
        drives[i] = d
        if id == activeDriveId { evaluateStatus() }
    }

    private func setDrives(_ found: [Drive], token: Int) {
        let current = Dictionary(drives.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Drive] = []
        if driveReads.accept("", token) {
            // The newest list of mounted drives; a drive read more recently on its own keeps that read.
            for d in found { next.append(merged(d, onto: current[d.id], token: token) ?? current[d.id] ?? d) }
        } else {
            // An older list: only update drives it read more recently than what's shown.
            next = drives.map { d in found.first { $0.id == d.id }.flatMap { merged($0, onto: d, token: token) } ?? d }
        }
        drives = next
        if activeDrive == nil {
            let saved = defaults.string(forKey: "activeDrive")
            activeDriveId = (drives.first { $0.volume.name == saved } ?? drives.first { $0.manifest != nil } ?? drives.first)?.id
        }
        evaluateStatus()
    }

    /// A drive read begun with `token`, applied onto what's shown: its files and free space unless a newer read of
    /// them was applied, its manifest unless a newer read or a local change was. Nil if it's older on both counts.
    private func merged(_ read: Drive, onto current: Drive?, token: Int) -> Drive? {
        let files = driveReads.accept(read.id + "#files", token)
        let manifest = driveReads.accept(read.id, token)
        guard var d = current else { return withQueuedEdits(read) }
        guard files || manifest else { return nil }
        if files {
            d.volume = read.volume
            d.probe = read.probe
        }
        if manifest, !read.isReading { d.manifest = withQueuedEdits(read).manifest }
        if read.isReading, let current { d.manifest = current.manifest; d.probe = current.probe }
        d.isReading = read.isReading && d.manifest == nil
        if !read.isReading { d.readError = read.readError }
        return d
    }

    /// A drive as read, with selection edits still waiting for a sync to finish shown applied.
    private func withQueuedEdits(_ d: Drive) -> Drive {
        guard var m = d.manifest else { return d }
        if let draft = selectionDraft(for: d) {
            m.selectedPlaylistIds = draft.playlistIDs
            m.entireLibrary = draft.entireLibrary
        }
        queuedEdits[d.id]?.forEach { $0(&m) }
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

    @ObservationIgnored private var scheduledReload: Task<Void, Never>?

    /// Reloads the library after `delay` seconds, replacing a reload already scheduled.
    func scheduleReload(_ reason: String, after delay: Double) {
        guard loadState == .loaded else { return }
        scheduledReload?.cancel()
        scheduledReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.readLibrary()

        }
    }

    /// Drives being ejected (by id), for the sidebar spinner.
    private(set) var ejecting: Set<String> = []

    /// Ejects in the background (flushing a stick can take a few seconds) and reports the outcome.
    func eject(_ drive: Drive) {
        let name = drive.volume.name, id = drive.id
        if syncingDriveId == id {
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

    private(set) var collapsedPlaylistFolders: Set<String> = []
    private var folderExpansionKey: String { "collapsedPlaylistFolders:\(libraryDirectory.path)" }

    func isFolderExpanded(_ id: String) -> Bool { !collapsedPlaylistFolders.contains(id) }

    func togglePlaylistFolder(_ id: String) {
        guard playlists.contains(where: { $0.id == id && $0.isFolder }) else { return }
        if collapsedPlaylistFolders.remove(id) == nil {
            collapsedPlaylistFolders.insert(id)
            if case .playlist(let selected) = selection, isPlaylist(selected, inside: id) { selection = .playlist(id) }
        }
        defaults.set(collapsedPlaylistFolders.sorted(), forKey: folderExpansionKey)
    }

    private func isPlaylist(_ id: String, inside folderID: String) -> Bool {
        var parent = playlists.first { $0.id == id }?.parentId
        while let current = parent {
            if current == folderID { return true }
            parent = playlists.first { $0.id == current }?.parentId
        }
        return false
    }

    func canMovePlaylist(_ id: String, toFolder parentID: String?) -> Bool {
        guard canEditLibrary, let playlist = playlists.first(where: { $0.id == id }), playlist.parentId != parentID else { return false }
        guard let parentID else { return true }
        return playlists.contains { $0.id == parentID && $0.isFolder }
            && parentID != id && !isPlaylist(parentID, inside: id)
    }

    /// Only used for immediate hover feedback. A drop always reads and validates its actual payload.
    var draggedItems: [String] = []

    func playlistDrop(_ items: [String], into targetID: String?, at location: PlaylistDropLocation = .on) -> PlaylistDrop? {
        guard canEditLibrary else { return nil }
        let target = targetID.flatMap { id in playlists.first { $0.id == id } }
        guard targetID == nil || target != nil else { return nil }
        if location != .on, let target {
            if location == .before { return playlistInsertion(items, parentID: target.parentId, before: target.id) }
            if target.isFolder && isFolderExpanded(target.id) {
                return playlistInsertion(items, parentID: target.id, before: playlists.first { $0.parentId == target.id }?.id)
            }
            let siblings = playlists.filter { $0.parentId == target.parentId }
            let next = siblings.firstIndex(where: { $0.id == target.id }).flatMap { index in
                index + 1 < siblings.count ? siblings[index + 1].id : nil
            }
            return playlistInsertion(items, parentID: target.parentId, before: next)
        }
        let sourceID = PlaylistDrag.decode(items)
        var ids: [String]
        if let sourceID {
            guard let source = playlists.first(where: { $0.id == sourceID }), sourceID != targetID else { return nil }
            if target == nil || target?.isFolder == true {
                return canMovePlaylist(sourceID, toFolder: targetID) ? .move(sourceID, targetID) : nil
            }
            guard !source.isFolder else { return nil }
            // Keep playlist members even when their audio is temporarily unavailable.
            ids = source.trackIds
        } else {
            ids = TrackDrag.decode(items)
        }
        guard let target, !target.isFolder, !ids.isEmpty else { return nil }
        ids = ids.filter { library?.tracks[$0] != nil }
        guard !ids.isEmpty else { return nil }
        var seen = Set(target.trackIds)
        let additions = ids.filter { seen.insert($0).inserted }
        return .copy(PlaylistCopy(targetID: target.id, sourceID: sourceID,
                                  trackIDs: additions, skipped: ids.count - additions.count))
    }

    func applyPlaylistDrop(_ drop: PlaylistDrop) async {
        switch drop {
        case .move(let id, let folder): await movePlaylist(id, toFolder: folder)
        case .position(let position):
            guard playlistInsertion([PlaylistDrag.encode(position.playlistID)],
                                    parentID: position.parentID, before: position.beforeID) != nil else { return }
            pendingSourceEdits += 1
            defer { pendingSourceEdits -= 1 }
            if await editLocal({ try await $0.positionPlaylist(position.playlistID, toFolder: position.parentID, before: position.beforeID) }) {
                revealPlaylistFolder(position.parentID)
            }
        case .copy(let copy):
            guard !copy.trackIDs.isEmpty,
                  let target = playlists.first(where: { $0.id == copy.targetID && !$0.isFolder }) else { return }
            await add(copy.trackIDs, to: target)
        }
    }

    func playlistInsertion(_ items: [String], parentID: String?, before anchorID: String?) -> PlaylistDrop? {
        guard canEditLibrary, let id = PlaylistDrag.decode(items),
              let source = playlists.first(where: { $0.id == id }), id != parentID,
              parentID == nil || playlists.contains(where: { $0.id == parentID && $0.isFolder }),
              parentID.map({ !isPlaylist($0, inside: id) }) ?? true else { return nil }
        let siblings = playlists.filter { $0.parentId == parentID }.map(\.id)
        guard anchorID == nil || (anchorID != id && siblings.contains(anchorID!)) else { return nil }
        var proposed = siblings.filter { $0 != id }
        let index = anchorID.flatMap { proposed.firstIndex(of: $0) } ?? proposed.endIndex
        proposed.insert(id, at: index)
        guard source.parentId != parentID || proposed != siblings else { return nil }
        return .position(PlaylistPosition(playlistID: id, parentID: parentID, beforeID: anchorID))
    }

    func movePlaylist(_ id: String, toFolder parentID: String?) async {
        guard canMovePlaylist(id, toFolder: parentID) else { return }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        if await editLocal({ try await $0.movePlaylist(id, toFolder: parentID) }) {
            revealPlaylistFolder(parentID)
        }
    }

    private func revealPlaylistFolder(_ parentID: String?) {
        if let parentID {
            // Reveal the destination and its ancestors so a successful drop never hides the item.
            var ancestor: String? = parentID
            while let current = ancestor {
                collapsedPlaylistFolders.remove(current)
                ancestor = playlists.first { $0.id == current }?.parentId
            }
            defaults.set(collapsedPlaylistFolders.sorted(), forKey: folderExpansionKey)
        }
    }

    var playlistEntries: [PlaylistEntry] {
        let byParent = Dictionary(grouping: playlists, by: { $0.parentId ?? "" })
        var out: [PlaylistEntry] = []
        func walk(_ parent: String, _ depth: Int) {
            for p in byParent[parent] ?? [] {
                out.append(PlaylistEntry(playlist: p, depth: depth))
                if p.isFolder, isFolderExpanded(p.id) { walk(p.id, depth + 1) }
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

    func createPlaylist(named name: String, isFolder: Bool = false) async {
        guard canEditLibrary else { return }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        let before = Set(playlists.map(\.id))
        await editLocal { try await $0.createPlaylist(named: name, isFolder: isFolder) }
        if let p = playlists.last(where: { !before.contains($0.id) }) { selection = .playlist(p.id) }
    }

    func add(_ trackIDs: [String], to playlist: SourcePlaylist) async {
        guard canEditLibrary else { return }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        await editLocal { try await $0.add(trackIDs: trackIDs, to: playlist.id) }
        recentPlaylistIds = [playlist.id] + recentPlaylistIds.filter { $0 != playlist.id }.prefix(9)
        defaults.set(recentPlaylistIds, forKey: "recentPlaylists")
    }

    func deletePlaylist(_ id: String) async {
        guard canEditLibrary, playlists.contains(where: { $0.id == id && !$0.isFolder }) else { return }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        guard await editLocal({ try await $0.deletePlaylist(id) }) else { return }
        if selection == .playlist(id) { selection = .all }
        recentPlaylistIds.removeAll { $0 == id }
        defaults.set(recentPlaylistIds, forKey: "recentPlaylists")
    }

    var lastPlaylistId: String? { recentPlaylistIds.first }
    private(set) var recentPlaylistIds: [String] = []

    func setRating(_ stars: Int, for ids: [String]) {
        guard canEditLibrary else { return }
        let ids = ids.filter { rows[$0] != nil }
        guard !ids.isEmpty else { return }
        pendingSourceEdits += 1
        Task {
            defer { pendingSourceEdits -= 1 }
            await editLocal { try await $0.setRating(stars, ids: ids) }
        }
    }

    /// Foregrounding the app checks saved audio availability and USB state, without replacing imports.
    func refreshFromMusic() {
        guard loadState == .loaded, observesChanges else { return }
        Task {
            try? await reloadLibrary("app became active")
            let cache = cache
            await Task.detached { cache?.reloadFromDisk() }.value
            if let id = activeDriveId { await refreshDrive(id) } else { evaluateStatus() }
        }
    }

    func remove(_ ids: [String], from playlist: SourcePlaylist) async {
        guard canEditLibrary else { return }
        pendingSourceEdits += 1
        defer { pendingSourceEdits -= 1 }
        await editLocal { try await $0.remove(trackIDs: ids, from: playlist.id) }
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
    @ObservationIgnored private var snoozes: [String: Double] = [:]

    func snoozedUntil(_ id: String) -> Date? { snoozes[id].map(Date.init(timeIntervalSince1970:)) }

    func snooze(_ id: String, days: Int) {
        snoozes[id] = Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970
        defaults.set(snoozes, forKey: "reviewSnoozes")
    }

    func unsnooze(_ id: String) {
        snoozes[id] = nil
        defaults.set(snoozes, forKey: "reviewSnoozes")
    }

    @discardableResult
    private func editLocal(_ work: (DeckhandLibraryStore) async throws -> DeckhandLibrarySnapshot) async -> Bool {
        guard let localStore else { return false }
        noteEdit()
        do { applyLocal(try await work(localStore)); return true }
        catch { flash("Couldn't save changes in Deckhand: \(error.localizedDescription)"); return false }
    }

    private func applyLocal(_ snapshot: DeckhandLibrarySnapshot) {
        guard snapshot.revision >= appliedLibraryRevision else { return }
        appliedLibraryRevision = snapshot.revision
        let lib = snapshot.library
        let built = Self.merge(lib, into: rows)
        if built.changed { rows = built.rows }
        if allIds != built.allIds { allIds = built.allIds }
        if playlists != lib.playlists { playlists = lib.playlists }
        artwork = lib.artwork
        library = lib
        libraryID = lib.sourceID
        hasLibrary = snapshot.initialized
        connections = snapshot.connections
        recentSources = connections.map(\.connection)
        source = connections.first(where: { $0.id == snapshot.selectedSourceID })?.connection
        sourceError = connections.first(where: { $0.id == snapshot.selectedSourceID })?.error
        sourceConflicts = snapshot.conflicts.count
        unavailableAudioIssues = lib.tracks.values.filter { $0.unavailableReason != nil || $0.location == nil }
            .map { UnavailableAudioIssue(track: $0) }
            .sorted { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        loadState = .loaded
        evaluateStatus()
        if rows.values.contains(where: { !$0.checked }), !loadingAnalysis { Task { await loadAnalysis() } }
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
