import DeckhandCore
import SwiftUI

/// Keyboard-first "Add to playlist" (⇧P in the track list and Quick Rate). Recently used playlists
/// come first. j/k or ↓/↑ (or Tab/⇧Tab) move, Space puts the tracks in or takes them out of the
/// highlighted playlist and stays open, Return adds and closes, / filters by name, Escape closes.
struct PlaylistPicker: View {
    var library: LibraryModel
    /// The tracks being added.
    var ids: [String]
    var done: () -> Void

    private enum Focus { case list, filter }

    @State private var filter = ""
    @State private var filtering = false
    @State private var highlighted = 0
    @FocusState private var focus: Focus?
    /// Recent order as it was when the picker opened, so adding doesn't reshuffle the list under you.
    @State private var recentIds: [String]?

    private static let recentLimit = 5

    /// Recent playlists, then the rest in library order (folders excluded). While filtering: the
    /// matches only.
    private var candidates: (list: [SourcePlaylist], recent: Int) {
        let all = library.playlists.filter { !$0.isFolder }
        let q = filter.trimmingCharacters(in: .whitespaces)
        if filtering, !q.isEmpty {
            return (all.filter { $0.name.localizedCaseInsensitiveContains(q) }, 0)
        }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = (recentIds ?? library.recentPlaylistIds).compactMap { byId[$0] }.prefix(Self.recentLimit)
        let recentIds = Set(recent.map(\.id))
        return (Array(recent) + all.filter { !recentIds.contains($0.id) }, recent.count)
    }

    private func hasAll(_ p: SourcePlaylist) -> Bool {
        let have = Set(p.trackIds)
        return ids.allSatisfy(have.contains)
    }

    var body: some View {
        let (list, recent) = candidates
        VStack(alignment: .leading, spacing: 10) {
            Text(ids.count == 1 ? "Add “\(library.rows[ids[0]]?.title ?? "track")” to…" : "Add \(ids.count) tracks to…")
                .font(.headline)
                .lineLimit(1)
            if filtering {
                TextField("Filter playlists", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .filter)
                    .onChange(of: filter) { highlighted = 0 }
                    .onKeyPress(keys: [.downArrow, .upArrow, .tab, .return, .escape]) { press in
                        handle(press, list)
                    }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                            if recent > 0 && i == 0 { sectionLabel("Recent") }
                            if recent > 0 && i == recent { sectionLabel("All playlists") }
                            row(p, highlighted: i == highlighted)
                                .id(p.id)
                                .onTapGesture { highlighted = i; toggle(p) }
                                .help(hasAll(p) ? "Space or click to take out" : "Space or click to add")
                        }
                        if list.isEmpty {
                            Text("No playlists match").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(height: 300)
                .onChange(of: highlighted) {
                    if highlighted < list.count { proxy.scrollTo(list[highlighted].id) }
                }
            }
            Text(filtering
                 ? "↑↓ to move · Return to add · Esc to stop filtering"
                 : "j k to move · Space to add or take out · Return to add and close · / to filter · Esc to close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(phases: .down) { press in
            // Only when the list has focus; the filter field handles its own keys.
            focus == .list ? handle(press, list) : .ignored
        }
        .onAppear {
            recentIds = library.recentPlaylistIds
            focus = .list
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(_ p: SourcePlaylist, highlighted: Bool) -> some View {
        let already = hasAll(p)
        return HStack(spacing: 8) {
            Image(systemName: already ? "checkmark.square.fill" : "square")
                .foregroundStyle(already ? Color.synced : Color.secondary)
            Text(p.name).lineLimit(1)
            Spacer()
            Text(p.trackIds.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(highlighted ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func handle(_ press: KeyPress, _ list: [SourcePlaylist]) -> KeyPress.Result {
        switch press.key {
        case .downArrow: move(1, list.count); return .handled
        case .upArrow: move(-1, list.count); return .handled
        case .tab: move(press.modifiers.contains(.shift) ? -1 : 1, list.count); return .handled
        case .return: commit(list); return .handled
        case .escape:
            if filtering {
                filtering = false
                filter = ""
                highlighted = 0
                focus = .list
            } else {
                done()
            }
            return .handled
        default: break
        }
        guard !filtering else { return .ignored }
        switch press.characters {
        case "j": move(1, list.count)
        case "k": move(-1, list.count)
        case " ":
            guard highlighted < list.count else { return .ignored }
            toggle(list[highlighted])
        case "/":
            filtering = true
            highlighted = 0
            DispatchQueue.main.async { focus = .filter }
        default: return .ignored
        }
        return .handled
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    /// Puts the tracks in `p`, or takes them out when they're all there already. Applied in Music
    /// straight away; the checkbox follows the library.
    private func toggle(_ p: SourcePlaylist) {
        let ids = ids
        if hasAll(p) {
            Task { await library.remove(ids, from: p) }
        } else {
            Task { await library.add(ids, to: p) }
        }
    }

    /// Return: adds to the highlighted playlist (if they aren't all there yet) and closes.
    private func commit(_ list: [SourcePlaylist]) {
        if highlighted < list.count, !hasAll(list[highlighted]) {
            let ids = ids, p = list[highlighted]
            Task { await library.add(ids, to: p) }
        }
        done()
    }
}
