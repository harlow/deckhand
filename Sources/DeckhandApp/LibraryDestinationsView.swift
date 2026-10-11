import SwiftUI

/// Sending changes to another app is always an explicit action.
struct LibraryDestinationsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var selected = Set<String>()
    @State private var includeRatings = false
    @State private var rekordbox = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Playlists").font(.title2.weight(.semibold))
            Picker("Send to", selection: $rekordbox) {
                Text("Apple Music / iTunes").tag(false)
                Text("Rekordbox XML").tag(true)
            }.pickerStyle(.segmented).disabled(library.exportingMusic)
            if rekordbox {
                Text("Export your Deckhand playlists as XML, then import them in Rekordbox.")
                    .foregroundStyle(.secondary)
                let imports = library.connections.filter { $0.connection.kind == .rekordbox && $0.lastImported != nil }
                if imports.isEmpty {
                    Text("Add a Rekordbox collection XML first so Deckhand can preserve its track IDs and cues.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Includes all Deckhand playlists. Your original XML stays unchanged.").font(.caption).foregroundStyle(.secondary)
                    ForEach(imports) { item in
                        Button(imports.count == 1 ? "Export XML…" : "Export XML · \(item.connection.location?.lastPathComponent ?? "Rekordbox")…") {
                            library.exportRekordbox(sourceID: item.id)
                        }.disabled(!library.sourceCanChange)
                    }
                }
            } else {
                Text("Creates or updates copies in the Deckhand folder in Music.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(library.playlists.filter { !$0.isFolder }) { playlist in
                            Toggle(isOn: Binding(get: { selected.contains(playlist.id) }, set: { on in
                                if on { selected.insert(playlist.id) } else { selected.remove(playlist.id) }
                            })) { Text("\(playlist.name) · \(playlist.trackIds.count)").lineLimit(1) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180).disabled(library.exportingMusic)
                Toggle("Also update ratings in Music", isOn: $includeRatings).font(.callout).disabled(library.exportingMusic)
                Button(library.exportingMusic ? "Exporting…" : "Export Selected Playlists") {
                    let ids = Array(selected)
                    Task { await library.exportMusic(playlistIDs: ids, includeRatings: includeRatings) }
                }.disabled(selected.isEmpty || !library.sourceCanChange)
                if let result = library.musicExportResult { Text(result).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Spacer()
                Button("Done") { library.showingDestinations = false }.keyboardShortcut(.cancelAction)
                    .disabled(library.exportingMusic)
            }
        }.padding(24)
        .onAppear {
            if let playlist = library.selectedPlaylist, !playlist.isFolder { selected = [playlist.id] }
        }
    }
}
