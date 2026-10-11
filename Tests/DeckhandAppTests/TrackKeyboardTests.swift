@testable import DeckhandApp
import AppKit
import Testing

@MainActor @Suite(.serialized) struct TrackKeyboardTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Track \(row)" }
    }

    // A command-line test runner cannot activate an app window. Keep real AppKit responders and
    // field editors, but explicitly model which window is receiving keyboard input.
    private final class WorkspaceWindow: NSWindow {
        var receivesKeys = true
        override var isKeyWindow: Bool { receivesKeys }
    }

    private func withTable(_ check: (KeyTableView, NSWindow, NSButton) -> Void) {
        _ = NSApplication.shared
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = KeyTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let rows = Rows()
        table.dataSource = rows
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        window.contentView!.addSubview(table)
        let button = NSButton(title: "Sync", target: nil, action: nil)
        window.contentView!.addSubview(button)
        table.reloadData()
        window.makeFirstResponder(button)
        defer { window.close() }
        withExtendedLifetime(rows) { check(table, window, button) }
    }

    private func key(_ text: String, in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: text.lowercased() == "j" ? 38 : 40)!
    }

    @Test func navigatesFromOtherControlsAndDoesNotDispatchTwice() {
        withTable { table, window, button in
            #expect(table.routeWorkspaceNavigation(key("j", in: window)))
            #expect(table.selectedRow == 0)
            #expect(window.firstResponder === table)
            let next = key("j", in: window)
            #expect(!table.routeWorkspaceNavigation(next))
            table.keyDown(with: next)
            #expect(table.selectedRow == 1)
            window.makeFirstResponder(button)
            #expect(table.routeWorkspaceNavigation(key("k", in: window)))
            #expect(table.selectedRow == 0)
        }
    }

    @Test func shiftExtendsAndNavigationStopsAtListEdges() {
        withTable { table, window, button in
            table.selectRowIndexes([1], byExtendingSelection: false)
            #expect(table.routeWorkspaceNavigation(key("J", in: window, flags: .shift)))
            #expect(table.selectedRowIndexes == IndexSet([1, 2]))
            table.keyDown(with: key("K", in: window, flags: .shift))
            #expect(table.selectedRowIndexes == IndexSet([0, 1, 2]))
            for _ in 0..<6 { table.keyDown(with: key("j", in: window)) }
            #expect(table.selectedRow == 3)
            for _ in 0..<6 { table.keyDown(with: key("k", in: window)) }
            #expect(table.selectedRow == 0)
        }
    }

    @Test func leavesSearchAndNameEditorsAlone() {
        withTable { table, window, _ in
            for field in [NSSearchField(), NSTextField()] {
                window.contentView!.addSubview(field)
                window.makeFirstResponder(field)
                #expect(window.firstResponder is NSTextView) // The real AppKit field editor.
                #expect(!table.routeWorkspaceNavigation(key("j", in: window)))
                #expect(!table.routeWorkspaceNavigation(key("k", in: window)))
                #expect(table.selectedRow == -1)
                #expect(window.firstResponder is NSTextView)
            }
        }
    }

    @Test func ignoresModifiedKeysOtherWindowsAndHiddenLists() {
        withTable { table, window, _ in
            for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
                #expect(!table.routeWorkspaceNavigation(key("j", in: window, flags: flags)))
            }
            #expect(!table.routeWorkspaceNavigation(key("q", in: window)))
            let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            #expect(!table.routeWorkspaceNavigation(key("j", in: other)))
            (window as! WorkspaceWindow).receivesKeys = false
            #expect(!table.routeWorkspaceNavigation(key("j", in: window)))
            (window as! WorkspaceWindow).receivesKeys = true
            table.isHidden = true
            #expect(!table.routeWorkspaceNavigation(key("j", in: window)))
            #expect(table.selectedRow == -1)
        }
    }

    @Test func leavesSheetsAlone() {
        withTable { table, window, _ in
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            #expect(!table.routeWorkspaceNavigation(key("j", in: window)))
            #expect(!table.routeWorkspaceNavigation(key("j", in: sheet)))
            #expect(table.selectedRow == -1)
            window.endSheet(sheet)
            sheet.close()
        }
    }
}
