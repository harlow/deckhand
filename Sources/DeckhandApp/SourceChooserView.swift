import MusicSource
import SwiftUI

/// Imports feed one library; choosing an input never switches the workspace.
struct SourceChooserView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Music").font(.title.weight(.semibold))
            Text("Bring your tracks and playlists into Deckhand.").foregroundStyle(.secondary)
            VStack(spacing: 10) {
                choice(.folder, icon: "folder", title: "Folder on Computer", detail: "Audio files and M3U playlists", action: "Choose Folder…")
                choice(.music, icon: "music.note", title: "Apple Music / iTunes", detail: "Your existing tracks and playlists", action: "Import")
                choice(.rekordbox, icon: "opticaldisc", title: "Rekordbox", detail: "Export Collection in XML format from Rekordbox first", action: "Choose XML…")
            }
            Text("Audio stays where it is. Playlists and ratings save automatically in Deckhand.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = library.sourceError {
                Text(error).font(.callout).foregroundStyle(Color.pending).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if library.connectingSource {
                    ProgressView().controlSize(.small)
                    Text("Importing music…").foregroundStyle(.secondary)
                } else if !library.hasLibrary {
                    Button("Start Empty") { Task { await library.startEmptyLibrary() } }
                        .disabled(!library.sourceCanChange)
                }
                Spacer()
                if library.hasLibrary {
                    // Dismissal remains available while a background import or sync is running.
                    Button("Done") { library.choosingSource = false }.keyboardShortcut(.cancelAction)
                }
            }
        }.padding(28).frame(maxWidth: 600)
    }

    private func choice(_ kind: SourceConnection.Kind, icon: String, title: String, detail: String, action: String) -> some View {
        Button { library.chooseSource(kind) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(action).font(.callout).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(!library.sourceCanChange).accessibilityLabel(title)
    }
}
