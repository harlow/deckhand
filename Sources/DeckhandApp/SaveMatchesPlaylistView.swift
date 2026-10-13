import SwiftUI

struct SaveMatchesPlaylistView: View {
    var library: LibraryModel
    let session: MatchSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Playlist").font(.headline)
            Text("Includes the seed song first, followed by all \(session.tracks.count) matches in ranked order.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .disabled(saving)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save") {
                    saving = true; error = nil
                    Task {
                        if await library.saveMatchesPlaylist(named: name, session: session) { dismiss() }
                        else {
                            error = library.notice ?? "Couldn't save the playlist. Try again."
                            saving = false
                            nameFocused = true
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 420)
        .interactiveDismissDisabled(saving)
        .onAppear { name = "Matches — \(session.seed.title)"; nameFocused = true }
    }
}
