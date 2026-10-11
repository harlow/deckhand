import AppKit
import SwiftUI

/// A window-level shortcut host: typing and modal dialogs keep their input, and help temporarily
/// owns keyboard focus so browsing keys cannot change selection behind the overlay.
struct KeyboardShortcutHost: NSViewRepresentable {
    var library: LibraryModel

    func makeNSView(context: Context) -> KeyboardShortcutView { KeyboardShortcutView() }

    func updateNSView(_ view: KeyboardShortcutView, context: Context) {
        view.toggleHelp = { library.showingKeyboardHelp.toggle() }
        view.navigatePlaylist = { delta in
            guard library.review == nil, case .workspace = library.startupScreen else { return }
            library.selectAdjacentPlaylist(delta)
        }
        view.showingHelp = library.showingKeyboardHelp
        view.allowsPlaylistNavigation = library.review == nil
        view.synchronizeFocus()
    }

    static func dismantleNSView(_ view: KeyboardShortcutView, coordinator: ()) { view.removeMonitor() }
}

final class KeyboardShortcutView: NSView {
    var toggleHelp: () -> Void = {}
    var navigatePlaylist: (Int) -> Void = { _ in }
    var showingHelp = false
    var allowsPlaylistNavigation = true
    private var monitor: Any?
    private var ownsFocus = false
    private weak var previousResponder: NSResponder?
    private weak var previousTextField: NSTextField?
    private var previousTextSelection: NSRange?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        synchronizeFocus()
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func synchronizeFocus() {
        guard let window else { return }
        if showingHelp, !ownsFocus {
            previousResponder = window.firstResponder
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
               let content = window.contentView {
                previousTextField = Self.field(owning: editor, in: content)
                previousTextSelection = editor.selectedRange()
            }
            ownsFocus = window.makeFirstResponder(self)
        } else if !showingHelp, ownsFocus {
            if window.firstResponder === self {
                window.makeFirstResponder(previousTextField ?? previousResponder)
                if let editor = previousTextField?.currentEditor() as? NSTextView,
                   let range = previousTextSelection { editor.setSelectedRange(range) }
            }
            previousResponder = nil
            previousTextField = nil
            previousTextSelection = nil
            ownsFocus = false
        }
    }

    private static func field(owning editor: NSTextView, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.currentEditor() === editor { return field }
        for child in view.subviews {
            if let field = field(owning: editor, in: child) { return field }
        }
        return nil
    }

    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, !window.isSheet, NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        let text = event.characters ?? ""
        if modifiers == .command, text == "/", !event.modifierFlags.contains(.shift) {
            toggleHelp()
            return true
        }
        if showingHelp {
            if event.keyCode == 53 || (text == "?" && modifiers.isEmpty) { toggleHelp(); return true }
            // Keep standard app/window commands available, but absorb playback and navigation keys.
            return !event.modifierFlags.contains(.command)
        }
        guard modifiers.isEmpty else { return false }
        if let editor = window.firstResponder as? NSText, editor.isEditable { return false }
        if let field = window.firstResponder as? NSTextField, field.isEditable { return false }
        switch text {
        case "?": toggleHelp(); return true
        case "[" where allowsPlaylistNavigation: navigatePlaylist(-1); return true
        case "]" where allowsPlaylistNavigation: navigatePlaylist(1); return true
        default: return false
        }
    }
}

struct KeyboardHelpView: View {
    var quickRate: Bool
    var close: () -> Void

    private func section(_ title: String, _ shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(shortcuts, id: \.0) { key, label in
                HStack(spacing: 12) {
                    Text(key).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 88, height: 24)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    Text(label).font(.callout)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").foregroundStyle(.secondary).padding(6) }
                    .buttonStyle(.plain).accessibilityLabel("Close keyboard shortcuts")
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    if quickRate {
                        section("Quick Rate", [
                            ("J / K", "Skip / go back"), ("⌥1–5", "Rate and continue"),
                            ("P or L", "Replay preview"), ("G", "Toggle groove"),
                            ("O", "Change order"), ("⇧P", "Add to playlist"), ("Esc", "Leave Quick Rate"),
                        ])
                    } else {
                        section("Navigation", [
                            ("[", "Previous playlist"), ("]", "Next playlist"),
                            ("K / ↑", "Previous song"), ("J / ↓", "Next song"),
                        ])
                        section("Playback", [
                            ("Enter", "Play selected song"), ("Space", "Play / pause"),
                            ("H", "Jump to song start"), ("L", "Jump to pre-drop preview"),
                            ("⇧H", "Back 16 bars"), ("⇧L", "Forward 16 bars"),
                        ])
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 18) {
                    if quickRate {
                        section("Playing song", [
                            ("Space", "Play / pause"), ("1–8", "Jump to hot cue A–H"),
                            (", / .", "Back / forward 4 beats"), ("⇧, / ⇧.", "Back / forward 16 beats"),
                            ("[ / ]", "Previous / next section"),
                        ])
                    } else {
                        section("Ratings", [("⌥1–5", "Rate song 1–5 stars"), ("⌥0", "Clear rating")])
                        section("Hot cues", [("1–5", "Jump to hot cue 1–5")])
                        section("Playlists", [("A", "Add selection to playlist"), ("/", "Search songs")])
                    }
                    section("General", [("? / ⌘/", "Keyboard shortcuts"),
                        ("Esc", quickRate ? "Close overlay / cancel" : "Close overlay / single selection")])
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Letter keys don’t need Shift. Shortcuts pause while you type.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Esc to close").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 740)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .accessibilityAddTraits(.isModal)
    }
}
