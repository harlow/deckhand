import AppKit
import SwiftUI

@main
struct DeckhandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryModel()
    @State private var player = Player()

    var body: some Scene {
        WindowGroup("Deckhand") {
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

        Window("Deckhand Console", id: "console") {
            ConsoleView().preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 420)
        .commands {
            ConsoleCommands()
            CommandMenu("Playback") {
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
