import DeckhandAppCore
import DeckhandCore
import MusicSource
import SwiftUI

struct TrackListView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player
    @State private var selection = Set<String>()
    /// Tracks waiting for "Remove from playlist?" confirmation.
    @State private var removing: [String] = []
    @State private var showKeys = false
    /// Tracks waiting in the ⇧P "Add to playlist" picker.
    @State private var picking: [String] = []

    var body: some View {
        // Memoized in the model: cheap unless rows, selection, filter or sort changed.
        let listing = library.listing(playing: player.current)
        let rows = listing.rows
        VStack(spacing: 0) {
            header(listing)
            FilterBar(shown: rows.count, total: listing.base.count, genres: listing.genres)
            SyncNoticeBanner(library: library)
            LiveDataBanner(library: library)
            AnalysisBanner(library: library)
            Divider()
            if library.loadState == .loaded {
                table(listing)
            } else {
                LibraryLoading(library: library)
            }
        }
        .toolbar { driveToolbar }
        // When Up Next moves on (next button, ⌘→, or a track ending), select the new track and scroll
        // it into view if it's in this list.
        .onChange(of: player.current?.id) { _, id in
            guard let id, !selection.contains(id), rows.contains(where: { $0.id == id }) else { return }
            selection = [id]
        }
    }

    /// Drive status and Sync, right-aligned in this column's part of the toolbar.
    @ToolbarContentBuilder private var driveToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            // With the window title hidden, items pack toward the logo; the spacer pushes these right.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) { DriveControls(library: library) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .primaryAction) { DriveControls(library: library) }
        }
    }

    /// One row: title, summary, then search on the right.
    private func header(_ listing: TrackListing) -> some View {
        @Bindable var library = library
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(library.title).font(.title3.bold()).lineLimit(1)
                if library.loadState == .loaded {
                    Text(summary(listing)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Button { library.startReview(player: player) } label: {
                Label("Quick Rate", systemImage: "star.leadinghalf.filled")
            }
            .help("Rate this list's unrated tracks one by one (r)")
            SearchField(text: $library.filter.search)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var removeTitle: String {
        let n = removing.count
        let what = n == 1 ? (library.rows[removing[0]]?.title).map { "“\($0)”" } ?? "1 track" : "\(n) tracks"
        return "Remove \(what) from \(library.selectedPlaylist?.name ?? "this playlist")?"
    }

    private func summary(_ listing: TrackListing) -> String {
        let minutes = listing.minutes
        var s = "\(listing.base.count.formatted()) tracks · \(minutes / 60) h \(minutes % 60) min"
        if let drive = library.activeDrive, drive.manifest != nil {
            s += " · \(library.onDriveCount(listing).formatted()) on \(drive.volume.name)"
            // For a playlist, what's waiting (the drive box on the right covers the whole drive).
            if let p = library.selectedPlaylist, case .pending(let n)? = library.playlistSync(p) {
                s += " · \(n.formatted()) waiting to sync"
            }
        }
        return s
    }

    private func table(_ listing: TrackListing) -> some View {
        @Bindable var library = library
        let rows = listing.rows
        return TrackTable(
            rows: rows,
            version: listing.version,
            selection: $selection,
            sort: $library.sort,
            cell: { column, r in cell(column, r) },
            menu: { ids in menu(ids, rows: rows) },
            onOpen: { player.play($0, artwork: library.artwork) },
            onCommand: { command, ids in perform(command, ids, rows: rows) }
        )
        // The Track menu's rating shortcuts work wherever focus is (the sidebar, the search field).
        .focusedSceneValue(\.rateSelection, selection.isEmpty ? nil : RateSelection { [selection] stars in
            library.setRating(stars, for: Array(selection))
        })
        .sheet(isPresented: $showKeys) { KeyboardHelp() }
        .sheet(isPresented: Binding(get: { !picking.isEmpty }, set: { if !$0 { picking = [] } }),
               onDismiss: { NotificationCenter.default.post(name: .focusTracks, object: nil) }) {
            PlaylistPicker(library: library, ids: picking) { picking = [] }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })) {
            Button("Remove", role: .destructive) {
                let ids = removing
                if let p = library.selectedPlaylist { Task { await library.remove(ids, from: p) } }
                selection.subtract(ids)
                removing = []
            }
            Button("Cancel", role: .cancel) { removing = [] }
        } message: {
            Text("They stay in your library.")
        }
    }

    private func perform(_ command: TrackCommand, _ ids: [String], rows: [TrackRow]) {
        let wanted = Set(ids)
        let picked = rows.filter { wanted.contains($0.id) }
        switch command {
        case .play(let fromMixIn):
            guard let r = picked.first else { return }
            if fromMixIn { player.play(from: .mixIn, r, artwork: library.artwork) } else { player.play(r, artwork: library.artwork) }
        case .preview:
            guard let r = picked.first else { return }
            player.play(from: .preview, r, artwork: library.artwork)
        case .togglePlay:
            if player.current == nil, let r = picked.first { player.play(r, artwork: library.artwork) } else { player.toggle() }
        case .queue(let next):
            player.enqueue(picked, next: next)
            if !picked.isEmpty { library.flash(next ? "Playing next: \(picked[0].title)\(picked.count > 1 ? " +\(picked.count - 1)" : "")" : "Added \(picked.count) to Up Next") }
        case .hotCue(let slot): if !player.jumpToHotCue(slot) { NSSound.beep() }
        case .beats(let n): player.jumpBeats(n)
        case .section(let d): player.jumpSection(d)
        case .rate(let n): if !ids.isEmpty { library.setRating(n, for: ids) }
        case .toggleMixes:
            if player.current != nil { library.filter.mixesWithPlaying.toggle() } else { NSSound.beep() }
        case .search: NotificationCenter.default.post(name: .focusSearch, object: nil)
        case .revealPlaying:
            guard let id = player.current?.id else { NSSound.beep(); return }
            if !rows.contains(where: { $0.id == id }) { library.selection = .all; library.filter = TrackFilter() }
            selection = [id]
        case .help: showKeys = true
        case .review: library.startReview(player: player)
        case .addToPlaylist:
            if ids.isEmpty { NSSound.beep() } else { picking = ids }
        case .delete:
            // Delete removes from the open playlist only; it never deletes songs from the library.
            guard let p = library.selectedPlaylist, !p.isFolder, !ids.isEmpty else { NSSound.beep(); return }
            removing = ids
        }
    }

    /// One cell's SwiftUI content. Objects are passed explicitly: hosted cells don't inherit the
    /// window's environment.
    private func cell(_ column: TrackColumn, _ r: TrackRow) -> AnyView {
        switch column {
        case .status:
            AnyView(NowPlayingOrSync(row: r, player: player, library: library).frame(maxWidth: .infinity))
        case .title:
            AnyView(VStack(alignment: .leading, spacing: 1) {
                PlayingTitle(row: r, player: player)
                Text(r.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            })
        case .overview:
            AnyView(OverviewCell(row: r, player: player) {
                selection = [r.id]
                player.play(r, at: $0, artwork: library.artwork)
            })
        case .bpm: AnyView(Text(r.bpmText).monospacedDigit())
        case .key: AnyView(KeyChip(key: r.key))
        case .energy: AnyView(EnergyBar(energy: r.energy))
        case .rating: AnyView(StarRating(rating: r.rating) { library.setRating($0, for: [r.id]) })
        case .genre: AnyView(Text(r.genre).lineLimit(1).foregroundStyle(.secondary))
        case .time: AnyView(Text(formatTime(r.duration)).monospacedDigit().foregroundStyle(.secondary))
        }
    }

    private func menu(_ ids: [String], rows: [TrackRow]) -> [TrackMenuItem] {
        let wanted = Set(ids)
        let picked = rows.filter { wanted.contains($0.id) }
        var items: [TrackMenuItem] = [
            TrackMenuItem(title: "Play") { if let f = picked.first { player.play(f, artwork: library.artwork) } },
            TrackMenuItem(title: "Play Next") { player.enqueue(picked, next: true) },
            TrackMenuItem(title: "Add to Up Next") { player.enqueue(picked) },
            .divider,
            TrackMenuItem(title: "Rating", children: (0..<6).map { n in
                TrackMenuItem(title: n == 0 ? "None" : String(repeating: "★", count: n)) { library.setRating(n, for: ids) }
            }),
            TrackMenuItem(title: "Add to Playlist", children: library.playlists.filter { !$0.isFolder }.map { p in
                TrackMenuItem(title: p.name) { Task { await library.add(ids, to: p) } }
            }),
        ]
        if let p = library.selectedPlaylist, !p.isFolder {
            items.append(TrackMenuItem(title: "Remove from Playlist") { removing = ids })
        }
        items += [.divider, TrackMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.location)) }]
        return items
    }
}

/// Drive status and Sync. Its own view so job progress (up to 10 Hz) redraws only this, not the list.
private struct DriveControls: View {
    var library: LibraryModel

    var body: some View {
        if let drive = library.activeDrive {
            let job = library.job
            Color.clear.frame(width: 4)
            Menu {
                Picker("Drive", selection: Binding(get: { library.activeDriveId },
                                                   set: { library.activeDriveId = $0; library.refreshDrives() })) {
                    ForEach(library.drives) { d in
                        Text(d.manifest == nil ? "\(d.volume.name) (not a Deckhand drive)" : d.volume.name)
                            .tag(Optional(d.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Eject \(drive.volume.name)") { library.eject(drive) }
                    .disabled(job.running || library.ejecting.contains(drive.id))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mediastick")
                    Text(drive.volume.name).fontWeight(.semibold)
                    if job.running, let total = job.total, total > 0 {
                        Text("\(job.phase) \(Int(Double(job.done) / Double(total) * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else if job.running {
                        Text(job.phase).foregroundStyle(.secondary).lineLimit(1)
                    } else if library.checkingStatus {
                        Text("Checking…").foregroundStyle(.secondary)
                    } else if library.pendingChanges > 0 {
                        let size = library.pendingBytes > 0 ? " · \(LibraryModel.bytes(library.pendingBytes))" : ""
                        Text("\(library.pendingChanges.formatted()) to sync\(size)\(library.pendingWontFit ? " · won't fit" : "")")
                            .foregroundStyle(library.pendingWontFit ? Color.red : Color.pending)
                    } else if let n = library.driveStatus?.summary.unknown, n > 0 {
                        Text("\(n.formatted()) not checked").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
            .help("Changes waiting for \(drive.volume.name). Click to switch drives.")
            // Blue only when there's something to sync; with nothing pending it stays a quiet button you can still press.
            let prominent = job.running || library.pendingChanges > 0
            Button { library.sync(drive) } label: {
                HStack(spacing: 6) {
                    if job.running { ProgressView().controlSize(.mini).tint(.white) }
                    Text(job.running ? "Syncing" : "Sync").fontWeight(.semibold)
                }
                .foregroundStyle(prominent ? Color.white : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(prominent ? Color.accentColor.opacity(job.running ? 0.5 : 1) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(prominent ? 0 : 0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(job.running)
            .help("Sync \(drive.volume.name)")
        }
    }
}

private struct AnalysisBanner: View {
    var library: LibraryModel

    var body: some View {
        if library.unanalyzedCount > 0 && !library.job.running {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Color.pending)
                Text("\(library.unanalyzedCount.formatted()) tracks need analysis for key, tempo, energy and waveforms (about 9 min per 1,000).")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Analyze Library") { library.analyzeLibrary() }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.pending.opacity(0.08))
        }
    }
}

/// After a sync: what's still pending once the library and drive were read again, or (when the sync stopped because
/// Music couldn't be read live) the offer to sync from the snapshot anyway.
private struct SyncNoticeBanner: View {
    var library: LibraryModel
    @State private var showDetails = false

    var body: some View {
        if let notice = library.syncNotice, !library.job.running {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.pending)
                switch notice {
                case .leftover(let id, let drive, let count, let details):
                    Text("\(drive) still has \(count.formatted()) change\(count == 1 ? "" : "s") to sync after syncing.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Details") { showDetails = true }
                        .popover(isPresented: $showDetails, arrowEdge: .bottom) { NoticeDetails(lines: details) }
                    Button("Sync Again") { if let d = library.drives.first(where: { $0.id == id }) { library.sync(d) } }
                case .staleLibrary(let id, let drive, let reason):
                    Text("Didn't sync \(drive): couldn't read Music's current data (\(reason)), and the library snapshot can trail recent edits.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Anyway (May Be Stale)") {
                        if let d = library.drives.first(where: { $0.id == id }) { library.sync(d, requireLive: false) }
                    }
                }
                Button { library.syncNotice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.pending.opacity(0.08))
        }
    }
}

private struct NoticeDetails: View {
    var lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .frame(width: 460, height: min(320, CGFloat(lines.count) * 22 + 24))
    }
}

/// Shown when Music is running but can't be read live: rows and sync status come from iTunesLibrary's snapshot,
/// which can trail recent edits.
private struct LiveDataBanner: View {
    var library: LibraryModel

    var body: some View {
        if case .unavailable(let failure) = library.live {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(Color.pending)
                Text("Can't read Apple Music's current data: \(failure.description). Edits made in Music may take a while to show here and in sync status.")
                    .foregroundStyle(.secondary)
                Spacer()
                if failure.status == MusicEvents.Failure.notPermitted {
                    Button("Open Settings") { library.openAutomationSettings() }
                }
                Button("Try Again") { library.scheduleReload("trying Music again", after: 0) }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.pending.opacity(0.08))
        }
    }
}

/// The in-list waveform: click anywhere to preview from that point.
private struct OverviewCell: View {
    var row: TrackRow
    /// Read inside this cell, not the table builder, so the 20 Hz playhead redraws one cell
    /// instead of rebuilding the whole list.
    var player: Player
    var preview: (Double) -> Void

    private var progress: Double? { player.current?.id == row.id ? player.progress : nil }

    var body: some View {
        Group {
            if let o = row.overview {
                WaveformView(overview: o, progress: progress)
                    .onClickPosition(preview)
                    .help("Click to preview from here")
            } else if !row.checked {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Not analyzed").font(.caption).foregroundStyle(Color.pending)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 30)
    }
}

struct FilterBar: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player
    var shown: Int
    var total: Int
    var genres: [String]
    @State private var showKeys = false
    @State private var showBpm = false

    var body: some View {
        @Bindable var library = library
        HStack(spacing: 6) {
            chip("Key", value: keySummary, on: !library.filter.keys.isEmpty) { showKeys.toggle() }
                .popover(isPresented: $showKeys, arrowEdge: .bottom) { KeyWheel().padding().environment(library).environment(player) }
            chip("BPM", value: bpmSummary, on: library.filter.bpmMin != nil || library.filter.bpmMax != nil) { showBpm.toggle() }
                .popover(isPresented: $showBpm, arrowEdge: .bottom) { BpmRange().padding().environment(library) }
            Menu {
                Picker("Minimum energy", selection: $library.filter.minEnergy) {
                    Text("Any").tag(Int?.none)
                    ForEach(1..<11) { e in Text("\(e)+").tag(Int?.some(e)) }
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel("Energy", value: library.filter.minEnergy.map { "\($0)+" } ?? "any", on: library.filter.minEnergy != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            Menu {
                Picker("Minimum rating", selection: $library.filter.minRating) {
                    Text("Any").tag(Int?.none)
                    ForEach(1..<6) { n in Text(String(repeating: "★", count: n) + (n < 5 ? "+" : "")).tag(Int?.some(n)) }
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel("Rating", value: library.filter.minRating.map { "\($0)★+" } ?? "any", on: library.filter.minRating != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            Menu {
                Button("Any genre") { library.filter.genres = [] }
                Divider()
                ForEach(genres, id: \.self) { g in
                    Toggle(g, isOn: Binding(
                        get: { library.filter.genres.contains(g) },
                        set: { on in if on { library.filter.genres.insert(g) } else { library.filter.genres.remove(g) } }
                    ))
                }
            } label: {
                chipLabel("Genre", value: genreSummary, on: !library.filter.genres.isEmpty)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            chip(nil, value: "Mixes with playing", on: library.filter.mixesWithPlaying, icon: "circle.circle") {
                library.filter.mixesWithPlaying.toggle()
            }
            .disabled(player.current == nil)
            .help(player.current == nil ? "Play a track first" : "Compatible keys and tempo within ±6%")
            if !library.filter.isEmpty {
                Button("Clear") { library.filter = TrackFilter() }.buttonStyle(.link)
            }
            Spacer()
            if shown != total {
                Text("\(shown.formatted()) of \(total.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var keySummary: String {
        let keys = library.filter.keys.sorted { (Int($0.dropLast()) ?? 0, $0.last!) < (Int($1.dropLast()) ?? 0, $1.last!) }
        return keys.isEmpty ? "any" : keys.joined(separator: ", ")
    }

    private var bpmSummary: String {
        switch (library.filter.bpmMin, library.filter.bpmMax) {
        case (nil, nil): "any"
        case (let lo?, nil): "\(Int(lo))+"
        case (nil, let hi?): "≤ \(Int(hi))"
        case (let lo?, let hi?): "\(Int(lo))–\(Int(hi))"
        }
    }

    private var genreSummary: String {
        let g = library.filter.genres
        return g.isEmpty ? "any" : g.count == 1 ? g.first! : "\(g.count) genres"
    }

    private func chip(_ title: String?, value: String, on: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, value: value, on: on, icon: icon) }.buttonStyle(.plain)
    }

    /// A filter chip: just its name and a chevron until set, then its value too.
    private func chipLabel(_ title: String?, value: String, on: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            if let title { Text(title) }
            if title == nil {
                Text(value)
            } else if on {
                Text(value).fontWeight(.semibold)
            } else {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(on ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.white.opacity(0.12)))
        .contentShape(Capsule())
    }
}

/// Camelot wheel: minor keys (A) inside, major (B) outside.
struct KeyWheel: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Key").font(.headline)
                Spacer()
                Text(library.filter.keys.isEmpty ? "Any key" : "\(library.filter.keys.count) selected")
                    .foregroundStyle(.secondary)
            }
            ZStack {
                Circle().fill(Color.white.opacity(0.05)).frame(width: 280, height: 280)
                Circle().fill(Color.white.opacity(0.04)).frame(width: 160, height: 160)
                ForEach(["B", "A"], id: \.self) { ring in
                    ForEach(1...12, id: \.self) { n in
                        keyButton(n: n, ring: ring)
                    }
                }
                VStack(spacing: 2) {
                    Text("Playing").font(.caption2).foregroundStyle(.secondary)
                    Text(player.current?.key?.alphanumeric ?? "—").font(.title2.bold())
                    Text(player.current?.key?.longName ?? "").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, height: 300)
            HStack {
                Button("Mixes with playing") {
                    if let k = player.current?.key { library.filter.keys = Harmony.compatible(k) }
                }
                .disabled(player.current?.key == nil)
                Button("Energy boost") {
                    if let k = player.current?.key {
                        library.filter.keys = ["\((k.camelotNumber + 1) % 12 + 1)\(k.mode == .minor ? "A" : "B")"]
                    }
                }
                .disabled(player.current?.key == nil)
                Spacer()
                Button("Clear") { library.filter.keys = [] }
            }
        }
        .frame(width: 300)
    }

    private func keyButton(n: Int, ring: String) -> some View {
        let code = "\(n)\(ring)"
        let on = library.filter.keys.contains(code)
        let radius: Double = ring == "B" ? 120 : 80
        let angle = Double(n - 1) * .pi / 6
        let key = MusicalKey(parsing: code)
        return Button {
            if on { library.filter.keys.remove(code) } else { library.filter.keys.insert(code) }
        } label: {
            Text(code)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(on ? Color.black : Color.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(on ? (key.map(Color.camelot) ?? .gray) : Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(on ? Color.white : Color.white.opacity(0.1), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(key?.longName ?? code)
        .offset(x: radius * sin(angle), y: -radius * cos(angle))
    }
}

private struct BpmRange: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 10) {
            Text("Tempo").font(.headline)
            HStack {
                TextField("Min", value: $library.filter.bpmMin, format: .number).frame(width: 70)
                Text("–")
                TextField("Max", value: $library.filter.bpmMax, format: .number).frame(width: 70)
                Text("BPM").foregroundStyle(.secondary)
            }
            HStack {
                ForEach([(118.0, 124.0), (124, 128), (128, 132), (132, 140)], id: \.0) { lo, hi in
                    Button("\(Int(lo))–\(Int(hi))") { library.filter.bpmMin = lo; library.filter.bpmMax = hi }
                }
            }
            Button("Any tempo") { library.filter.bpmMin = nil; library.filter.bpmMax = nil }
        }
    }
}

/// Search box for the track list. ⌘F focuses it; Escape clears it.
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { focused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("f")
                .help("Search (⌘F)")
            TextField("Search", text: $text, prompt: Text("Title, artist, genre or key (8A)"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand {
                    text = ""
                    focused = false
                    NotificationCenter.default.post(name: .focusTracks, object: nil)
                }
                .onSubmit { NotificationCenter.default.post(name: .focusTracks, object: nil) }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 24)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor : Color.white.opacity(0.12)))
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
    }
}

/// The keyboard cheat sheet (press ? in the track list).
private struct KeyboardHelp: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Moving around", [
            ("j  k   ↓  ↑", "Next / previous track"),
            ("⌘⇧]  ⌘⇧[", "Next / previous playlist"),
            ("J  K", "Extend the selection"),
            ("⌘↑  ⌘↓", "Top / bottom of the list"),
            ("/", "Search (Escape or Return goes back to the list)"),
            ("⌘L", "Show the playing track"),
        ]),
        ("Playing", [
            ("l  (or p)", "Preview: from just before the first drop"),
            ("Return", "Play from the start"),
            ("⇧ Return", "Play from Mix In (cue A)"),
            ("Space", "Play / pause"),
            ("q  ⇧Q", "Add to Up Next / play next"),
            ("⇧P", "Add to playlist (j k, Space in/out, Return, / filters)"),
            ("⌘→  ⌘←", "Next / previous in Up Next"),
        ]),
        ("In the playing track", [
            ("1 – 8", "Hot cue A – H"),
            (",  .", "Back / forward 4 beats"),
            ("<  >", "Back / forward 16 beats"),
            ("[  ]", "Previous / next section"),
        ]),
        ("Other", [
            ("⌥1 – ⌥5   ⌥0", "Rate / clear rating"),
            ("m", "Mixes with now playing"),
            ("r", "Quick Rate: ⌥1–⌥5 rate, j next, k back, o order, g groove"),
            ("Delete", "Remove from playlist"),
            ("?", "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            HStack(alignment: .top, spacing: 32) {
                ForEach([0, 2], id: \.self) { start in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groups[start..<start + 2], id: \.0) { title, keys in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title).font(.headline)
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                                    ForEach(keys, id: \.0) { key, what in
                                        GridRow {
                                            Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(Color.accentColor)
                                            Text(what)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}

/// The playing track shows a speaker instead of its sync dot. Reads the player inside the cell so
/// playback changes redraw only this cell.
private struct NowPlayingOrSync: View {
    var row: TrackRow
    var player: Player
    var library: LibraryModel
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if player.current?.id == row.id {
            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(prominence == .increased ? Color.primary : Color.accentColor)
                .help("Now playing")
        } else {
            SyncDot(state: library.syncState(row))
        }
    }
}

private struct PlayingTitle: View {
    var row: TrackRow
    var player: Player
    /// `.increased` on a selected (blue) row, where accent-colored text wouldn't read.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(row.title)
            .fontWeight(.medium)
            .lineLimit(1)
            .foregroundStyle(player.current?.id == row.id && prominence != .increased ? Color.accentColor : Color.primary)
    }
}

/// Shown in place of the track list until the Apple Music library has been read.
private struct LibraryLoading: View {
    var library: LibraryModel

    var body: some View {
        VStack(spacing: 14) {
            switch library.loadState {
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Color.pending)
                Text("Couldn't read your Apple Music library").font(.title3.bold())
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Try Again") { Task { await library.readLibrary() } }
                    .keyboardShortcut(.defaultAction)
            default:
                PlatterMark().frame(width: 56, height: 56)
                    .opacity(0.9)
                ProgressView().controlSize(.small)
                Text("Reading your Apple Music library…").font(.title3.weight(.semibold))
                if library.loadState == .slow {
                    Text("This is taking longer than usual. If macOS is asking whether Deckhand may access Apple Music, click Allow; the prompt can be hidden behind other windows.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
