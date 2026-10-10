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
                Label("All Tracks", systemImage: "music.note.list")
                    .badge(library.allIds.count)
                    .tag(SidebarItem.all)
                Label("Needs Analysis", systemImage: "waveform")
                    .badge(library.unanalyzedCount)
                    .tag(SidebarItem.needsAnalysis)
            }

            Section {
                ForEach(library.playlistEntries) { e in
                    HStack(spacing: 6) {
                        Label(e.playlist.name, systemImage: e.playlist.isFolder ? "folder" : "music.note.list")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        PlaylistBadge(count: library.trackIds(of: e.playlist).count, state: library.playlistSync(e.playlist))
                    }
                    .padding(.leading, CGFloat(e.depth) * 14)
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
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New playlist in Apple Music")
                }
            }

            Section("Drives") {
                if library.drives.isEmpty {
                    Text("No USB drive connected").foregroundStyle(.secondary)
                }
                ForEach(library.drives) { d in
                    DriveRow(drive: d, active: d.id == library.activeDriveId)
                        .contentShape(Rectangle())
                        .onTapGesture { library.activeDriveId = d.id; library.refreshDrives() }
                }
            }
        }
        .listStyle(.sidebar)
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
}

private struct DriveRow: View {
    @Environment(LibraryModel.self) private var library
    var drive: Drive
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "mediastick")
                Text(drive.volume.name).fontWeight(active ? .semibold : .regular)
                Spacer()
                if library.ejecting.contains(drive.id) {
                    ProgressView().controlSize(.small).help("Ejecting…")
                } else {
                    Button { library.eject(drive) } label: { Image(systemName: "eject") }
                        .buttonStyle(.borderless)
                        .help("Eject \(drive.volume.name)")
                }
            }
            let used = Double(drive.volume.capacity - drive.volume.available)
            ProgressView(value: used, total: Double(max(drive.volume.capacity, 1)))
                .progressViewStyle(.linear)
                .tint(active ? .accentColor : .gray)
            Text("\(bytes(drive.volume.capacity - drive.volume.available)) of \(bytes(drive.volume.capacity))")
                .font(.caption).foregroundStyle(.secondary)
            if let m = drive.manifest {
                Text(m.lastSyncedAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Never synced")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not a Deckhand drive").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(drive.manifest == nil ? 0.6 : 1)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
