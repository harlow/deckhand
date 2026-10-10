import DeckhandAppCore
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var library
    @State private var naming = false
    @State private var newName = ""
    @State private var dropTarget: String?

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            Section("Library") {
                AllTracksRow(selected: library.selection == .all)
                    .tag(SidebarItem.all)
                Label("Needs Analysis", systemImage: "waveform")
                    .badge(library.unanalyzedCount)
                    .tag(SidebarItem.needsAnalysis)
            }

            if let groups = library.drivePlaylistGroups, let drive = library.activeDrive?.volume.name {
                Section {
                    ForEach(groups.on) { e in row(e, onDrive: true) }
                } header: {
                    playlistsHeader(library.entireLibraryOnDrive ? "On \(drive) · All Tracks" : "On \(drive)")
                }
                if !groups.off.isEmpty {
                    Section("Not on \(drive)") {
                        ForEach(groups.off) { e in row(e, onDrive: false) }
                    }
                }
            } else {
                Section {
                    ForEach(library.playlistEntries) { e in row(e, onDrive: nil) }
                } header: {
                    playlistsHeader("Playlists")
                }
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DriveFooter() }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await library.createPlaylist(named: name) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates the playlist in Apple Music.")
        }
    }

    private func playlistsHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New playlist in Apple Music")
        }
    }

    private func row(_ e: PlaylistEntry, onDrive: Bool?) -> some View {
        PlaylistRow(entry: e, onDrive: onDrive, selected: library.selection == .playlist(e.playlist.id))
            .background {
                if dropTarget == e.playlist.id {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = TrackDrag.decode(items)
                guard !ids.isEmpty, !e.playlist.isFolder else { return false }
                Task { await library.add(ids, to: e.playlist) }
                return true
            } isTargeted: { over in
                if over, !e.playlist.isFolder { dropTarget = e.playlist.id } else if dropTarget == e.playlist.id { dropTarget = nil }
            }
            .tag(SidebarItem.playlist(e.playlist.id))
    }
}

/// All Tracks, which can also go on the drive: every song, whichever playlists are chosen.
private struct AllTracksRow: View {
    @Environment(LibraryModel.self) private var library
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        let hasDrive = library.activeDrive?.manifest != nil
        let on = library.entireLibraryOnDrive
        let status = library.driveStatus
        let pending = status?.pendingCount ?? 0
        let drive = library.activeDrive?.volume.name ?? "the drive"
        HStack(spacing: 6) {
            Image(systemName: "music.note.list").frame(width: 16)
            Text("All Tracks").lineLimit(1)
            Spacer(minLength: 4)
            if hasDrive, !on, hovering {
                DriveActionButton(help: "Put every song on \(drive), not just those in its playlists") {
                    library.setEntireLibraryOnDrive(true)
                }
            } else {
                if on, status != nil {
                    Circle().fill(pending == 0 ? Color.synced : Color.pending)
                        .frame(width: 6, height: 6)
                        .help(pending == 0 ? "All tracks up to date on \(drive)" : "\(pending.formatted()) change\(pending == 1 ? "" : "s") to sync")
                }
                Text(library.allIds.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if hasDrive {
                Button(on ? "Remove All Tracks from \(drive)" : "Add All Tracks to \(drive)") {
                    library.setEntireLibraryOnDrive(!on)
                }
            }
        }
    }
}

/// A playlist in the sidebar. On the drive: a sync-status dot by the count; removed from the drive with the context
/// menu. Not on the drive: dimmed, with an Add button on hover.
private struct PlaylistRow: View {
    @Environment(LibraryModel.self) private var library
    var entry: PlaylistEntry
    /// Nil without a Deckhand drive.
    var onDrive: Bool?
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        let p = entry.playlist
        let state = library.playlistSync(p)
        let drive = library.activeDrive?.volume.name ?? "the drive"
        HStack(spacing: 6) {
            Image(systemName: p.isFolder ? "folder" : "music.note.list")
                .foregroundStyle(onDrive == false && !selected ? .secondary : .primary)
                .frame(width: 16)
            Text(p.name)
                .lineLimit(1)
                .foregroundStyle(onDrive == false && !selected ? .secondary : .primary)
            Spacer(minLength: 4)
            if onDrive == false, hovering {
                DriveActionButton(help: "Sync \(p.name) to \(drive)") { library.setOnDrive(true, p) }
            } else {
                if onDrive == true, let state, state != .unknown {
                    Circle().fill(state == .synced ? Color.synced : Color.pending)
                        .frame(width: 6, height: 6)
                        .help(statusHelp(state))
                }
                Text(library.trackCount(of: p).formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 22)
        .padding(.leading, CGFloat(entry.depth) * 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if onDrive == true {
                Button("Remove from \(drive)") { library.setOnDrive(false, p) }
            } else if onDrive == false {
                Button("Add to \(drive)") { library.setOnDrive(true, p) }
            }
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
/// eject. The playlist groups above follow whichever drive is active.
private struct DriveFooter: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let drive = library.activeDrive ?? library.drives.first {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                    Text(drive.volume.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    status(drive)
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
                            .disabled(library.ejecting.contains(drive.id))
                    } label: {
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(library.drives.count > 1 ? "Switch drives, or eject" : "Drive options")
                }
                let used = drive.volume.capacity - drive.volume.available
                ProgressView(value: Double(used), total: Double(max(drive.volume.capacity, 1)))
                    .progressViewStyle(.linear)
                    .tint(library.pendingWontFit ? .red : .accentColor)
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
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private func status(_ drive: Drive) -> some View {
        let (text, color): (String, Color) = {
            if library.ejecting.contains(drive.id) { return ("Ejecting", .secondary) }
            if drive.manifest == nil { return ("Not set up", .secondary) }
            if library.syncingDriveId == drive.id { return ("Syncing", .accentColor) }
            if library.checkingStatus { return ("Checking…", .secondary) }
            if library.pendingWontFit { return ("Won't fit", .red) }
            if library.pendingChanges > 0 { return ("\(library.pendingChanges.formatted()) to sync", Color.pending) }
            // Not hashed yet (or unreadable): neither synced nor pending, so not "Up to date" either.
            if let n = library.driveStatus?.summary.unknown, n > 0 { return ("\(n.formatted()) not checked", .secondary) }
            return ("Up to date", Color.synced)
        }()
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// "+ Add" at a sidebar row's right edge on hover, in place of its count. Removing is in the row's context menu,
/// so selecting a playlist never puts a destructive button under the pointer.
private struct DriveActionButton: View {
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
