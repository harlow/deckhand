import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    /// Logo and app name together; the system window title is hidden (macOS 15+) because toolbar
    /// spacing would otherwise leave a wide gap between them.
    @ViewBuilder private var titleMark: some View {
        if #available(macOS 15, *) {
            HStack(spacing: 7) {
                PlatterMark(mono: true).frame(width: 18, height: 18)
                Text("Deckhand").font(.headline)
            }
            .padding(.leading, 4)
        } else {
            PlatterMark(mono: true).frame(width: 18, height: 18).padding(.leading, 4)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { titleMark }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { titleMark }
        }
    }

    /// Giving the Up Next column its own toolbar item makes the toolbar split at that column, so the
    /// track list's trailing items stop at the Up Next divider instead of the window edge.
    @ToolbarContentBuilder private var queueTitle: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
        }
    }

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .environment(library).environment(player)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            // Up Next is a real column (not an inspector) so the track list gets its own toolbar
            // section: its drive/sync items right-align at the Up Next divider, not the window edge.
            Group {
                if let review = library.review {
                    ReviewView(review: review, library: library, player: player)
                } else {
                    TrackListView()
                        .environment(library).environment(player)
                        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar().environment(library).environment(player) }
                }
            }
            .toolbar { toolbarItems }
            .modifier(HideWindowTitle())
            .navigationSplitViewColumnWidth(min: 600, ideal: 1000)
        } detail: {
            Group {
                if let review = library.review { ReviewPanel(review: review) } else { QueueView() }
            }
            .environment(library).environment(player)
            .toolbar { queueTitle }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refreshFromMusic()
        }
        .onAppear {
            // Start with the track list focused (not the search box) so the keyboard shortcuts work.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .focusTracks, object: nil) }
        }
        .overlay(alignment: .bottomLeading) {
            if let status = library.notice ?? library.status ?? player.error {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .padding(.bottom, 84)
            }
        }
    }
}

private struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}
