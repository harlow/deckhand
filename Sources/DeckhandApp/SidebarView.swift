import DeckhandAppCore
import DeckhandCore
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var library
    @State private var naming = false
    @State private var newName = ""
    @State private var namingFolder = false
    @State private var dropTarget: String?
    @State private var dropLocation: PlaylistDropLocation?
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var rootDropTarget = false
    @State private var pendingCopy: PlaylistCopy?
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Library").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        SettingsLink { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).help("Library Settings").accessibilityLabel("Library Settings")
                    }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                    AllTracksRow(selected: library.selection == .all)
                        .sidebarSelection(.all, library: library)
                        .onTapGesture { library.openSidebarItem(.all) }
                        .onDrop(of: PlaylistDropDelegate.types, delegate: dropDelegate(into: nil, targeted: { _ in }))
                    HStack {
                        Label("Needs Analysis", systemImage: "waveform")
                        Spacer()
                        Text(library.unanalyzedCount.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .sidebarSelection(.needsAnalysis, library: library)
                    .onTapGesture { library.openSidebarItem(.needsAnalysis) }
                    playlistsHeader("Playlists").font(.headline).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 4)
                    if let drive = library.activeDrive, library.canPreviewDrive(drive) {
                        Text(library.driveMatchesSource(drive) ? "Check to sync to \(drive.volume.name)" : "Selected on \(drive.volume.name)")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.bottom, 5)
                    }
                    ForEach(library.playlistEntries) { e in
                        row(e, onDrive: library.activeDrive.map { library.canPreviewDrive($0) } == true ? library.isOnDrive(e.playlist) : nil)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
                .onPreferenceChange(PlaylistRowHeights.self) { rowHeights = $0 }
            }
            .onChange(of: library.selection) { _, item in if let item { proxy.scrollTo(item) } }
        }
        .focusable()
        .focused($sidebarFocused)
        .focusEffectDisabled()
        .simultaneousGesture(TapGesture().onEnded { sidebarFocused = true })
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebar)) { _ in sidebarFocused = true }
        .onChange(of: library.draggedItems) { _, items in
            if items.isEmpty { clearDropFeedback() }
        }
        .onKeyPress(.tab, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            library.focusTrackList()
            return .handled
        }
        .onKeyPress(.upArrow) { library.selectAdjacentSidebarItem(-1); return .handled }
        .onKeyPress(.downArrow) { library.selectAdjacentSidebarItem(1); return .handled }
        .safeAreaInset(edge: .bottom, spacing: 0) { DriveFooter() }
        .alert(namingFolder ? "New Folder" : "New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await library.createPlaylist(named: name, isFolder: namingFolder) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates the \(namingFolder ? "folder" : "playlist") in \(library.playlistDestination).")
        }
        .alert(copyTitle, isPresented: Binding(get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } })) {
            Button("Add Tracks") {
                if let copy = pendingCopy { Task { await library.applyPlaylistDrop(.copy(copy)) } }
                pendingCopy = nil
            }
            Button("Cancel", role: .cancel) { pendingCopy = nil }
        } message: {
            Text(copyMessage)
        }
    }

    private var copyTitle: String {
        guard let copy = pendingCopy else { return "Add tracks?" }
        let name = library.playlists.first { $0.id == copy.targetID }?.name ?? "playlist"
        return "Add \(copy.trackIDs.count.formatted()) \(copy.trackIDs.count == 1 ? "track" : "tracks") to “\(name)”?"
    }

    private var copyMessage: String {
        guard let copy = pendingCopy else { return "" }
        let source = copy.sourceID.flatMap { id in library.playlists.first { $0.id == id }?.name }
        let retained = source.map { "The tracks stay in “\($0)”. " } ?? ""
        return retained + (copy.skipped > 0
            ? "\(copy.skipped.formatted()) duplicate \(copy.skipped == 1 ? "entry will" : "entries will") be skipped."
            : "Tracks already in this playlist are skipped automatically.")
    }

    private func dropDelegate(into id: String?, targeted: @escaping (PlaylistDropLocation?) -> Void) -> PlaylistDropDelegate {
        PlaylistDropDelegate(library: library, targetID: id, rowHeight: id.flatMap { rowHeights[$0] }, targeted: targeted) { plan in
            library.draggedItems = []
            clearDropFeedback()
            if let copy = plan.copy, copy.sourceID != nil {
                pendingCopy = copy
            } else {
                Task { await library.applyPlaylistDrop(plan) }
            }
        }
    }

    private func clearDropFeedback() {
        dropTarget = nil
        dropLocation = nil
        rootDropTarget = false
    }

    private func playlistsHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                Button("New Playlist") { newName = ""; namingFolder = false; naming = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Folder") { newName = ""; namingFolder = true; naming = true }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New playlist or folder in \(library.playlistDestination)")
                .accessibilityLabel("New Playlist or Folder")
                .disabled(!library.sourceAvailable)
        }
        .contentShape(Rectangle())
        .background { if rootDropTarget && !library.draggedItems.isEmpty { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.25)) } }
        .help("Drop a playlist here to move it out of a folder")
        .onDrop(of: PlaylistDropDelegate.types, delegate: dropDelegate(into: nil, targeted: { rootDropTarget = $0 != nil }))
    }

    private func row(_ e: PlaylistEntry, onDrive: Bool?) -> some View {
        let over = !library.draggedItems.isEmpty && dropTarget == e.playlist.id ? dropLocation : nil
        let plan = over == .on ? library.playlistDrop(library.draggedItems, into: e.playlist.id) : nil
        return PlaylistRow(entry: e, onDrive: onDrive, selected: library.selection == .playlist(e.playlist.id), dropCopy: plan?.copy)
            .sidebarSelection(.playlist(e.playlist.id), library: library, dropTarget: plan != nil)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PlaylistRowHeights.self, value: [e.playlist.id: geometry.size.height])
            })
            .overlay(alignment: over == .before ? .top : .bottom) {
                if over == .before || over == .after {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                        .padding(.leading, 8 + CGFloat(e.depth + (over == .after && e.playlist.isFolder && library.isFolderExpanded(e.playlist.id) ? 1 : 0)) * 14)
                        .allowsHitTesting(false)
                }
            }
            .onDrag {
                clearDropFeedback()
                let payload = PlaylistDrag.encode(e.playlist.id)
                library.draggedItems = [payload]
                let provider = NSItemProvider(object: payload as NSString)
                provider.registerDataRepresentation(forTypeIdentifier: PlaylistDrag.type.identifier, visibility: .all) { completion in
                    completion(Data(payload.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                HStack(spacing: 8) {
                    Label(e.playlist.name, systemImage: e.playlist.isFolder ? "folder" : "music.note.list")
                    Text(library.trackCount(of: e.playlist).formatted()).font(.caption.monospacedDigit())
                }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .onDrop(of: PlaylistDropDelegate.types, delegate: dropDelegate(into: e.playlist.id, targeted: { over in
                if let over { dropTarget = e.playlist.id; dropLocation = over }
                else if dropTarget == e.playlist.id { dropTarget = nil; dropLocation = nil }
            }))
            .accessibilityLabel(e.playlist.name)
            .accessibilityValue("\(library.trackCount(of: e.playlist)) tracks")
            .accessibilityAction {
                library.openSidebarItem(.playlist(e.playlist.id))
                if e.playlist.isFolder { library.togglePlaylistFolder(e.playlist.id) }
            }
    }
}

private struct PlaylistRowHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func sidebarSelection(_ item: SidebarItem, library: LibraryModel, dropTarget: Bool = false) -> some View {
        self.padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dropTarget ? Color.accentColor.opacity(0.3) : (library.selection == item ? Color.accentColor : Color.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .id(item)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { library.openSidebarItem(item) }
    }
}

/// All Tracks, which can also go on the drive: every song, whichever playlists are chosen.
private struct AllTracksRow: View {
    @Environment(LibraryModel.self) private var library
    var selected: Bool

    var body: some View {
        let hasDrive = library.activeDrive.map { library.canPreviewDrive($0) } ?? false
        let on = library.entireLibraryOnDrive
        let status = library.driveStatus
        let pending = status?.pendingCount ?? 0
        let drive = library.activeDrive?.volume.name ?? "the drive"
        HStack(spacing: 6) {
            Image(systemName: "music.note.list").frame(width: 16)
            Text("All Tracks").lineLimit(1)
            Spacer(minLength: 4)
            if on, status != nil {
                Circle().fill(pending == 0 ? Color.synced : Color.pending)
                    .frame(width: 6, height: 6)
                    .help(pending == 0 ? "All tracks up to date on \(drive)" : "\(pending.formatted()) changes to sync")
            }
            Text(library.allIds.count.formatted())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if hasDrive {
                USBSelectionButton(on: on, selected: selected, help: "\(on ? "Exclude" : "Include") All Tracks on \(drive)") {
                    library.setEntireLibraryOnDrive(!on)
                }
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .contextMenu {
            if hasDrive {
                Button(on ? "Remove All Tracks from \(drive)" : "Add All Tracks to \(drive)") {
                    library.setEntireLibraryOnDrive(!on)
                }
            }
        }
    }
}

/// The playlist's position and text stay fixed; USB selection is indicated beside its count.
private struct PlaylistRow: View {
    @Environment(LibraryModel.self) private var library
    var entry: PlaylistEntry
    /// Nil without a Deckhand drive.
    var onDrive: Bool?
    var selected: Bool
    var dropCopy: PlaylistCopy? = nil
    @State private var confirmingDelete = false

    var body: some View {
        let p = entry.playlist
        let state = library.playlistSync(p)
        let drive = library.activeDrive?.volume.name ?? "the drive"
        HStack(spacing: 6) {
            if p.isFolder {
                HStack(spacing: 6) {
                        Image(systemName: library.isFolderExpanded(p.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold)).frame(width: 10)
                        Image(systemName: "folder").frame(width: 16)
                        Text(p.name).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    library.openSidebarItem(.playlist(p.id))
                    library.togglePlaylistFolder(p.id)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(library.isFolderExpanded(p.id) ? "Collapse" : "Expand") \(p.name)")
            } else {
                Color.clear.frame(width: 10)
                Image(systemName: "music.note.list").frame(width: 16)
                Text(p.name).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onDrive, onDrive, let state, state != .unknown {
                Circle().fill(state == .synced ? Color.synced : Color.pending)
                    .frame(width: 6, height: 6).help(statusHelp(state))
            }
            if let dropCopy {
                Text(dropCopy.trackIDs.isEmpty ? "Included" : "+\(dropCopy.trackIDs.count.formatted())")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .help(dropCopy.trackIDs.isEmpty ? "These tracks are already in this playlist" : "Add \(dropCopy.trackIDs.count.formatted()) tracks; skip \(dropCopy.skipped.formatted()) duplicates")
            } else {
                Text(library.trackCount(of: p).formatted())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let onDrive {
                USBSelectionButton(on: onDrive, mixed: !onDrive && library.hasAnyPlaylistOnDrive(p), selected: selected,
                                   help: "\(onDrive ? "Exclude" : "Include") \(p.name) on \(drive)") {
                    library.setOnDrive(!onDrive, p)
                }
            }
        }
        .frame(minHeight: 22)
        .padding(.leading, CGFloat(entry.depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture { if !p.isFolder { library.openSidebarItem(.playlist(p.id)) } }
        .contextMenu {
            let destinations = library.playlists.filter { $0.isFolder && library.canMovePlaylist(p.id, toFolder: $0.id) }
            if !destinations.isEmpty {
                Menu("Move to Folder") {
                    ForEach(destinations) { folder in
                        Button(folder.name) { Task { await library.movePlaylist(p.id, toFolder: folder.id) } }
                    }
                }
            }
            if p.parentId != nil {
                Button("Move to Top Level") { Task { await library.movePlaylist(p.id, toFolder: nil) } }
                    .disabled(!library.sourceAvailable)
            }
            if onDrive != nil, library.hasAnyPlaylistOnDrive(p) {
                Button("Remove from \(drive)") { library.setOnDrive(false, p) }
            }
            if onDrive == false {
                Button("Add to \(drive)") { library.setOnDrive(true, p) }
            }
            if !p.isFolder {
                Divider()
                Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                    .disabled(!library.sourceAvailable)
            }
        }
        .alert("Delete “\(p.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Playlist", role: .destructive) { Task { await library.deletePlaylist(p.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tracks stay in your Deckhand library. Playlists in other apps are unchanged. USB changes apply the next time you sync.")
        }
    }

    private func statusHelp(_ state: DriveStatus.Playlist) -> String {
        switch state {
        case .pending(let n): "\(n.formatted()) change\(n == 1 ? "" : "s") to sync"
        default: "Up to date on \(library.activeDrive?.volume.name ?? "the drive")"
        }
    }
}

/// The active drive, pinned under the playlists: its sync status and space, with a menu to switch drives or
/// eject. Playlist positions above remain fixed when a drive connects.
private struct DriveFooter: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let drive = library.activeDrive ?? library.drives.first {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                    Text(drive.volume.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    if library.syncingDriveId == nil,
                       library.driveMatchesSource(drive) || drive.isReading || drive.readError != nil || library.ejecting.contains(drive.id) {
                        status(drive)
                    }
                    Menu {
                        Picker("Drive", selection: Binding(get: { library.activeDriveId },
                                                           set: { library.activeDriveId = $0; library.refreshDrives() })) {
                            ForEach(library.drives) { d in
                                Text(d.manifest == nil ? "\(d.volume.name) (not a Deckhand drive)" : d.volume.name).tag(Optional(d.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button("Eject \(drive.volume.name)") { library.eject(drive) }
                            .disabled(library.job.running || library.ejecting.contains(drive.id))
                    } label: {
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(library.drives.count > 1 ? "Switch drives, or eject" : "Drive options")
                }
                let used = drive.volume.capacity - drive.volume.available
                DriveCapacityBar(used: used, capacity: drive.volume.capacity)
                HStack {
                    Text("\(LibraryModel.bytes(used)) / \(LibraryModel.bytes(drive.volume.capacity))")
                    Spacer()
                    if let m = drive.manifest {
                        Text(m.lastSyncedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never synced")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("No USB drive connected", systemImage: "externaldrive").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // The native sidebar card has an eight-point bottom inset that the player column doesn't.
        .modifier(WorkspaceFooterSurface(bottomInset: 8))
        .overlay(alignment: .top) {
            if let message = library.notice ?? library.status ?? player.error {
                SidebarNotice(text: message)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    // Anchor above the footer, with the sidebar's width as the wrapping constraint.
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
    }

    @ViewBuilder private func status(_ drive: Drive) -> some View {
        let (text, color): (String, Color) = {
            if library.ejecting.contains(drive.id) { return ("Ejecting", .secondary) }
            if drive.isReading { return ("Checking…", .secondary) }
            if drive.readError != nil { return ("Unavailable", .secondary) }
            if library.checkingStatus { return ("Checking…", .secondary) }
            if library.pendingWontFit { return ("Won't fit", .red) }
            if library.pendingChanges > 0 { return ("\(library.pendingChanges.formatted()) to sync", Color.pending) }
            // Not hashed yet (or unreadable): neither synced nor pending, so not "Up to date" either.
            if let n = library.driveStatus?.summary.unknown, n > 0 { return ("\(n.formatted()) not checked", .secondary) }
            if library.driveStatus?.complete != true { return ("Checking…", .secondary) }
            return (library.usbStatusText, Color.synced)
        }()
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Persistent inclusion control; audio and playlist removals happen only on an explicit Sync USB.
private struct USBSelectionButton: View {
    var on: Bool
    var mixed = false
    var selected = false
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15)).frame(width: 18, height: 22)
                // The row uses the accent color too; keep every checkbox state visible when selected.
                .foregroundStyle(selected ? Color.white.opacity(on || mixed ? 1 : 0.65)
                                 : on || mixed ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(mixed ? "Some selected" : on ? "Selected" : "Not selected")
    }
}
