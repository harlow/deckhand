import SwiftUI

/// Occasional audio repairs, opened from the library notice or settings.
struct UnavailableAudioView: View {
    var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unavailable Audio").font(.title2.bold())
            if library.unavailableAudioIssues.isEmpty {
                Label("All audio files are available.", systemImage: "checkmark.circle")
            } else {
                if library.unavailableAudioIssues.contains(where: { $0.kind == .protected }) {
                    Text("Apple Music marks protected tracks as unavailable for export. Choose an unprotected audio file to use each track in Deckhand.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if library.unavailableAudioIssues.contains(where: { $0.kind == .fileUnavailable }) {
                    Text("Locate missing audio using the saved paths below. If files are on a disconnected disk, reconnect it and recheck.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if library.unavailableAudioIssues.contains(where: { $0.kind == .noLocalFile }) {
                    Text("These tracks were imported without local audio. Download them in the original app and re-import, or choose an audio file below.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Your playlist entries and ratings are kept when you choose a file.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(library.unavailableAudioIssues) { issue in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.track.title).fontWeight(.medium)
                                    if let artist = issue.track.artist, !artist.isEmpty {
                                        Text(artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(issue.reason).font(.caption).foregroundStyle(Color.pending)
                                    if let path = issue.track.location?.path {
                                        Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(issue.actionTitle) {
                                    library.chooseAudioFile(for: issue) { error = $0 }
                                }.disabled(!library.sourceCanChange)
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }.frame(height: 300)
            }
            HStack {
                if library.unavailableAudioIssues.contains(where: { $0.kind == .fileUnavailable }) {
                    Button(checking ? "Checking…" : "Recheck Files") {
                        checking = true
                        Task { await library.readLibrary(); checking = false }
                    }.disabled(checking || !library.sourceCanChange)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 650)
        .alert("Couldn't use this audio file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
