import AppKit
import SwiftUI

@main
struct DeckhandApp: App {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Deckhand"
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryModel()
    @State private var player = Player()

    var body: some Scene {
        WindowGroup(Self.displayName) {
            ContentView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 560)
                .task {
                    player.cache = library.cache
                    await library.load()
                    // `open build/Deckhand.app --args --quick-rate` starts Quick Rate once loaded (for testing).
                    if CommandLine.arguments.contains("--quick-rate") { library.startReview(player: player) }
                }
        }
        .defaultSize(width: 1440, height: 900)
        // Don't let the window shrink below the layout's minimum: the content would overflow and be
        // cropped top and bottom (sidebar's first rows and Quick Rate's track details disappear).
        .windowResizability(.contentMinSize)

        Settings {
            MusicImportsView().environment(library).preferredColorScheme(.dark)
        }

        Window("Deckhand Console", id: "console") {
            ConsoleView().preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 420)
        .commands {
            ConsoleCommands()
            TrackCommands()
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { library.showingKeyboardHelp.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Add Music…") { library.choosingSource = true }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!library.sourceCanChange)
                Divider()
                Button("Sync USB") { library.requestSync() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(library.activeDrive == nil || !library.sourceAvailable || !library.sourceCanChange)
                Button("Analyze Library") { library.analyzeLibrary() }
                    .disabled(!library.sourceAvailable || !library.sourceCanChange || library.unanalyzedCount == 0)
                Button("Export Playlists…") { library.showingDestinations = true }
                    .disabled(!library.sourceAvailable || !library.sourceCanChange)
                Divider()
                SettingsLink { Text("Library Settings…") }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Next Playlist") { library.selectAdjacentPlaylist(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Playlist") { library.selectAdjacentPlaylist(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Show Playing Song") { library.revealPlaying(player.current) }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(player.current == nil || library.review != nil || !library.sourceAvailable)
                Divider()
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Next Track") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
        }
    }
}

/// Rates the selected tracks in the track list (0 clears).
struct RateSelection {
    var rate: (Int) -> Void
}

extension FocusedValues {
    @Entry var rateSelection: RateSelection?
}

struct TrackCommands: Commands {
    @FocusedValue(\.rateSelection) private var rateSelection

    var body: some Commands {
        CommandMenu("Track") {
            ForEach(1...5, id: \.self) { stars in
                Button("Rate \(stars) Star\(stars == 1 ? "" : "s")") { rateSelection?.rate(stars) }
                    .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .option)
                    .disabled(rateSelection == nil)
            }
            Button("Clear Rating") { rateSelection?.rate(0) }
                .keyboardShortcut("0", modifiers: .option)
                .disabled(rateSelection == nil)
        }
    }
}

struct ConsoleCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Show Console") { openWindow(id: "console") }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run DeckhandApp`); an .app bundle is
        // activated by Launch Services (and `open -g` keeps it in the background).
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        HangDetector.shared.start()
        Log.info("app", "Launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
