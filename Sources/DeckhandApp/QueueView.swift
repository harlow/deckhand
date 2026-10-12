import SwiftUI

struct QueueView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                if player.queue.isEmpty, let next = player.nextInList {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("NEXT IN LIST")
                            .font(.caption.weight(.medium)).tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.horizontal, 16)
                        TrackLine(row: next)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } else if player.queue.isEmpty {
                    Text("Play a song to see suggestions. Drag tracks here to add them to Up Next.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .listRowInsets(EdgeInsets())
                }
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                    VStack(alignment: .leading, spacing: 4) {
                        if let prev = i == 0 ? player.current : player.queue[i - 1] {
                            let tr = Harmony.transition(from: prev, to: t)
                            Label(tr.text, systemImage: "arrow.down")
                                .font(.caption2)
                                .foregroundStyle(tr.good ? Color.synced : Color.pending)
                                .lineLimit(1)
                                .padding(.horizontal, 16)
                        }
                        TrackLine(row: t, interactive: true)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Play Now") { player.playQueued(t, artwork: library.artwork) }
                        Button("Remove") { player.queue.remove(at: i) }
                    }
                }
                .onMove { player.move(from: $0, to: $1) }
                .onDelete { player.remove(at: $0) }
            } header: {
                if !player.queue.isEmpty {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        Button("Clear") { player.queue = [] }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .listSectionSeparator(.hidden)

            // Nothing already queued, playing, or played this session.
            let excluded = Set(player.queue.map(\.id) + player.history.map(\.id) + [player.current?.id].compactMap { $0 })
            let suggestions = library.suggestions(after: player.queue.last ?? player.current, excluding: excluded)
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { t in
                        TrackLine(row: t, interactive: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.enqueue([t]) }
                        .accessibilityAction(named: "Add to Up Next") { player.enqueue([t]) }
                        .contextMenu {
                            Button("Add to Up Next") { player.enqueue([t]) }
                            Button("Play Now") { player.play(t, artwork: library.artwork) }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIXES WELL WITH")
                            .font(.caption.weight(.medium)).tracking(0.8)
                            .foregroundStyle(.secondary)
                        if let reference = player.queue.last ?? player.current {
                            Text(reference.title).font(.caption).fontWeight(.regular).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 16)
                } footer: {
                    Text("Double-click a suggestion to add it to Up Next.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        // AppKit draws the middle column's toolbar separator one point above its content edge.
        .safeAreaInset(edge: .top, spacing: 0) { Divider().offset(y: -1) }
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
    var interactive = false
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).fontWeight(.medium).lineLimit(1)
                Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                KeyChip(key: row.key)
                Text(row.bpmText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.white.opacity(interactive && hovered ? 0.06 : 0))
        .onHover { hovered = $0 }
    }
}
