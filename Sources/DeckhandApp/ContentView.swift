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
                Text(DeckhandApp.displayName).font(.headline)
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

    /// A real toolbar title keeps this column's header and divider aligned with drive/sync controls.
    @ToolbarContentBuilder private var queueTitle: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { Text(library.review == nil ? "Suggestions" : "Quick Rate").font(.headline) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { Text(library.review == nil ? "Suggestions" : "Quick Rate").font(.headline) }
        }
    }

    var body: some View {
        @Bindable var library = library
        Group {
            switch library.startupScreen {
            case .loading:
                VStack(spacing: 14) {
                    PlatterMark().frame(width: 56, height: 56)
                    ProgressView().controlSize(.small)
                    Text("Opening your library…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sourceChooser:
                SourceChooserView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .workspace:
                workspace
            case .failed(let error):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Color.pending)
                    Text("Couldn't open your Deckhand library").font(.title3.bold())
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    Button("Try Again") { Task { await library.retryLoad() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KeyboardShortcutHost(library: library))
        .overlay {
            if library.showingKeyboardHelp {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { library.showingKeyboardHelp = false }
                    KeyboardHelpView(quickRate: library.review != nil) { library.showingKeyboardHelp = false }
                }
            }
        }
        .sheet(isPresented: $library.showingDestinations) {
            LibraryDestinationsView().frame(width: 680)
        }
        .sheet(isPresented: $library.choosingSource) {
            SourceChooserView().frame(width: 600).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $library.showingUSBConnection) {
            USBConnectionView()
        }
        .sheet(isPresented: $library.showingUSBChanges) {
            USBChangesView()
        }
    }

    @ViewBuilder private var workspace: some View {
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
            .toolbarBackground(.visible)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refreshFromMusic()
        }
        .onAppear {
            // Start with the track list focused (not the search box) so the keyboard shortcuts work.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .focusTracks, object: nil) }
        }
    }
}

private struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}
