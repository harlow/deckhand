import SwiftUI

struct QueueView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                if player.queue.isEmpty, let next = player.nextInList {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next in list").font(.caption).foregroundStyle(.secondary)
                        TrackLine(row: next)
                    }
                } else if player.queue.isEmpty {
                    Text("Drag tracks here, or right-click them and choose Play Next or Add to Up Next.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                    VStack(alignment: .leading, spacing: 4) {
                        if let prev = i == 0 ? player.current : player.queue[i - 1] {
                            let tr = Harmony.transition(from: prev, to: t)
                            Label(tr.text, systemImage: "arrow.down")
                                .font(.caption2)
                                .foregroundStyle(tr.good ? Color.synced : Color.pending)
                                .lineLimit(1)
                        }
                        TrackLine(row: t)
                    }
                    .contextMenu {
                        Button("Play Now") { player.playQueued(t, artwork: library.artwork) }
                        Button("Remove") { player.queue.remove(at: i) }
                    }
                }
                .onMove { player.move(from: $0, to: $1) }
                .onDelete { player.remove(at: $0) }
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    if !player.queue.isEmpty {
                        Button("Clear") { player.queue = [] }.buttonStyle(.borderless)
                    }
                }
            }

            // Nothing already queued, playing, or played this session.
            let excluded = Set(player.queue.map(\.id) + player.history.map(\.id) + [player.current?.id].compactMap { $0 })
            let suggestions = library.suggestions(after: player.queue.last ?? player.current, excluding: excluded)
            if !suggestions.isEmpty {
                Section("Mixes well next") {
                    ForEach(suggestions) { t in
                        HStack(spacing: 8) {
                            Button { player.enqueue([t]) } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Add to Up Next")
                            TrackLine(row: t)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.enqueue([t]) }
                        .contextMenu {
                            Button("Add to Up Next") { player.enqueue([t]) }
                            Button("Play Now") { player.play(t, artwork: library.artwork) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        // Pinned to the bottom so a running job doesn't push Up Next around.
        .safeAreaInset(edge: .bottom) {
            if library.job.state != .idle, !library.job.isUSBSync {
                JobCard().padding(12)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            let rows = TrackDrag.decode(items).compactMap { library.rows[$0] }
            player.enqueue(rows)
            return !rows.isEmpty
        }
    }
}

private struct TrackLine: View {
    var row: TrackRow

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).fontWeight(.medium).lineLimit(1)
                Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                KeyChip(key: row.key)
                Text(row.bpmText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
