import MusicSource
import SwiftUI

/// Occasional import management, separate from the everyday library and USB workflow.
struct MusicImportsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showingHistory = false
    @State private var reviewUnavailableAudio = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Library Settings").font(.title2.weight(.semibold))
            Text("Your playlists and ratings save automatically in Deckhand.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if library.unavailableTracks > 0 {
                HStack {
                    Text(UnavailableAudioIssue.summary(library.unavailableAudioIssues)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Review") { reviewUnavailableAudio = true }
                }
            }
            DisclosureGroup("Import History", isExpanded: $showingHistory) {
                Text("Re-import to bring in changes. Your Deckhand edits are kept.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if library.connections.isEmpty {
                        Text("No music imported yet. Use Add Music to get started.")
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(library.connections) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(title(item.connection)).font(.headline)
                                Spacer()
                                Button("Re-import") { Task { await library.reimport(item.connection) } }
                            }
                            Text(item.connection.location?.path ?? "Apple Music / iTunes library")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let date = item.lastImported {
                                HStack(spacing: 4) { Text("Last imported"); Text(date, style: .relative); Text("ago") }
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = item.error {
                                Text(error).font(.caption).foregroundStyle(Color.pending)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                        }
                        .padding(12).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!library.sourceCanChange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 280)
            }
            if library.sourceConflicts > 0 {
                Text("\(library.sourceConflicts) imported playlist(s) changed outside Deckhand. Your Deckhand edits were kept.")
                    .font(.caption).foregroundStyle(Color.pending)
            }
            HStack {
                Button("Add Music…") { dismiss(); library.choosingSource = true }
                    .disabled(!library.sourceCanChange)
                Spacer()
                Button("Export Playlists…") { dismiss(); library.showingDestinations = true }
                    .disabled(!library.sourceAvailable || !library.sourceCanChange)
            }
            Text("Export sends copies to another app when you choose.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 650)
        .sheet(isPresented: $reviewUnavailableAudio) { UnavailableAudioView(library: library) }
    }

    private func title(_ connection: SourceConnection) -> String {
        switch connection.kind {
        case .music: "Apple Music / iTunes"
        case .folder: connection.location?.lastPathComponent ?? "Music folder"
        case .rekordbox: "Rekordbox · \(connection.location?.lastPathComponent ?? "XML")"
        }
    }
}
