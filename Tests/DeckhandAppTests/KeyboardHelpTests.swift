@testable import DeckhandApp
import AppKit
import Testing

@MainActor @Suite(.serialized) struct KeyboardHelpTests {
    private final class WorkspaceWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func withHost(_ check: (KeyboardShortcutView, NSWindow, NSButton) -> Void) {
        _ = NSApplication.shared
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = KeyboardShortcutView()
        let button = NSButton(title: "Sync", target: nil, action: nil)
        window.contentView!.addSubview(host)
        window.contentView!.addSubview(button)
        window.makeFirstResponder(button)
        defer { window.close() }
        check(host, window, button)
    }

    private func key(_ text: String, in window: NSWindow, flags: NSEvent.ModifierFlags = [], code: UInt16 = 44) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    @Test func opensFromControlsAndRestoresFocusWithoutPlaying() {
        withHost { host, window, button in
            host.toggleHelp = { host.showingHelp.toggle(); host.synchronizeFocus() }
            #expect(host.handle(key("?", in: window, flags: .shift)))
            #expect(host.showingHelp)
            #expect(window.firstResponder === host)
            for text in ["j", "k", "[", "]", " ", "\r", "1"] {
                #expect(host.handle(key(text, in: window)))
                #expect(host.showingHelp)
            }
            #expect(!host.handle(key("q", in: window, flags: .command)))
            #expect(host.handle(key("\u{1b}", in: window, code: 53)))
            #expect(!host.showingHelp)
            #expect(host.handle(key("/", in: window, flags: .command)))
            #expect(host.showingHelp)
            #expect(host.handle(key("/", in: window, flags: .command)))
            #expect(!host.showingHelp)
            #expect(window.firstResponder === button)
            #expect(host.handle(key("?", in: window)))
            #expect(host.handle(key("?", in: window)))
            #expect(!host.showingHelp)
        }
    }

    @Test func navigationDoesNotStealTypingOrQuickRateSectionKeys() {
        withHost { host, window, button in
            var directions: [Int] = []
            host.navigatePlaylist = { directions.append($0) }
            #expect(host.handle(key("[", in: window)))
            #expect(host.handle(key("]", in: window)))
            #expect(directions == [-1, 1])
            host.allowsPlaylistNavigation = false
            #expect(!host.handle(key("[", in: window)))
            host.allowsPlaylistNavigation = true
            for field in [NSSearchField(), NSTextField()] {
                window.contentView!.addSubview(field)
                window.makeFirstResponder(field)
                #expect(window.firstResponder is NSTextView)
                for text in ["?", "[", "]"] { #expect(!host.handle(key(text, in: window))) }
            }
            #expect(directions == [-1, 1])
            window.makeFirstResponder(button)
            for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
                #expect(!host.handle(key("?", in: window, flags: flags)))
            }
        }
    }

    @Test func sheetsAndOtherWindowsKeepTheirKeyboardInput() {
        withHost { host, window, _ in
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            defer { sheet.close() }
            #expect(!host.handle(key("?", in: sheet)))
            window.beginSheet(sheet)
            #expect(!host.handle(key("?", in: window)))
            #expect(!host.handle(key("]", in: window)))
            window.endSheet(sheet)
        }
    }

    @Test func commandHelpRestoresTheSearchFieldEditorAndInsertionPoint() {
        withHost { host, window, _ in
            let field = NSSearchField(string: "songs")
            window.contentView!.addSubview(field)
            window.makeFirstResponder(field)
            let editor = field.currentEditor() as! NSTextView
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            host.toggleHelp = { host.showingHelp.toggle(); host.synchronizeFocus() }
            #expect(host.handle(key("/", in: window, flags: .command)))
            #expect(window.firstResponder === host)
            #expect(host.handle(key("\u{1b}", in: window, code: 53)))
            #expect(window.firstResponder === field.currentEditor())
            #expect((field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 0))
            #expect(!host.handle(key("h", in: window)))
        }
    }

    @Test func matchesEscapeRespectsHelpEditorsMenusAndSheets() {
        withHost { host, window, button in
            var exits = 0
            host.leaveMatches = { exits += 1; return true }
            let escape = key("\u{1b}", in: window, code: 53)
            #expect(host.handle(escape) && exits == 1)
            host.showingHelp = true
            host.toggleHelp = { host.showingHelp = false }
            #expect(host.handle(escape) && exits == 1 && !host.showingHelp)
            let field = NSSearchField()
            window.contentView!.addSubview(field); window.makeFirstResponder(field)
            #expect(!host.handle(escape) && exits == 1)
            window.makeFirstResponder(button)
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            #expect(!host.handle(escape) && exits == 1)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            #expect(!host.handle(escape) && exits == 1)
            window.endSheet(sheet); sheet.close()
            #expect(host.handle(escape) && exits == 2)
        }
    }

    @Test func helpFocusBlocksTableNavigationBehindOverlay() {
        withHost { host, window, _ in
            let table = KeyTableView()
            window.contentView!.addSubview(table)
            host.showingHelp = true
            host.synchronizeFocus()
            #expect(window.firstResponder === host)
            #expect(!table.routeWorkspaceNavigation(key("j", in: window)))
        }
    }
}
