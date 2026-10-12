@testable import DeckhandApp
import AppKit
import Testing
import DeckhandCore
import SwiftUI

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

    private func key(_ text: String, in window: NSWindow, flags: NSEvent.ModifierFlags = [], code: UInt16? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code ?? (text.lowercased() == "j" ? 38 : 40))!
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

    @Test func removedShiftLetterNavigationStaysInactiveAndPlainNavigationStopsAtEdges() {
        withTable { table, window, button in
            table.selectRowIndexes([1], byExtendingSelection: false)
            #expect(!table.routeWorkspaceNavigation(key("J", in: window, flags: .shift)))
            #expect(!table.routeWorkspaceNavigation(key("K", in: window, flags: .shift)))
            #expect(table.selectedRowIndexes == IndexSet([1]))
            for _ in 0..<6 { table.keyDown(with: key("j", in: window)) }
            #expect(table.selectedRow == 3)
            for _ in 0..<6 { table.keyDown(with: key("k", in: window)) }
            #expect(table.selectedRow == 0)
        }
    }

    @Test func escapeCollapsesMultipleSongsToFirstSelectedSong() {
        withTable { table, window, button in
            table.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
            window.makeFirstResponder(table)
            table.keyDown(with: key("\u{1b}", in: window, code: 53))
            #expect(table.selectedRowIndexes == IndexSet([1]))

            table.selectRowIndexes([0, 2, 3], byExtendingSelection: false)
            window.makeFirstResponder(button)
            #expect(table.routeWorkspaceNavigation(key("\u{1b}", in: window, code: 53)))
            #expect(table.selectedRowIndexes == IndexSet([0]))
            #expect(window.firstResponder === table)

            window.makeFirstResponder(button)
            #expect(!table.routeWorkspaceNavigation(key("\u{1b}", in: window, code: 53)))
            #expect(table.selectedRowIndexes == IndexSet([0]))
            table.deselectAll(nil)
            #expect(!table.routeWorkspaceNavigation(key("\u{1b}", in: window, code: 53)))
            #expect(table.selectedRowIndexes.isEmpty)
        }
    }

    @Test func escapeLeavesEditorsHelpAndSheetsInCharge() {
        withTable { table, window, _ in
            let selection = IndexSet([0, 1, 2])
            table.selectRowIndexes(selection, byExtendingSelection: false)
            let escape = key("\u{1b}", in: window, code: 53)
            let editor = NSTextField()
            window.contentView!.addSubview(editor)
            window.makeFirstResponder(editor)
            #expect(!table.routeWorkspaceNavigation(escape))
            #expect(table.selectedRowIndexes == selection)

            let help = KeyboardShortcutView()
            window.contentView!.addSubview(help)
            window.makeFirstResponder(help)
            #expect(!table.routeWorkspaceNavigation(escape))
            #expect(table.selectedRowIndexes == selection)

            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            #expect(!table.routeWorkspaceNavigation(escape))
            #expect(table.selectedRowIndexes == selection)
            window.endSheet(sheet)
            sheet.close()
        }
    }

    @Test func escapeLeavesTrackingMenusInChargeUntilTheyClose() {
        withTable { table, window, _ in
            let selection = IndexSet([0, 1, 2])
            table.selectRowIndexes(selection, byExtendingSelection: false)
            let escape = key("\u{1b}", in: window, code: 53)
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            #expect(!table.routeWorkspaceNavigation(escape))
            #expect(table.selectedRowIndexes == selection)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            #expect(table.routeWorkspaceNavigation(escape))
            #expect(table.selectedRowIndexes == IndexSet([0]))
        }
    }

    @Test func dispatchesEveryCleanSongShortcutAndRejectsRemovedAliases() {
        withTable { table, window, button in
            var commands: [(TrackCommand, [String])] = []
            let row = TrackRow(id: "selected", source: SourceTrack(id: "selected", title: "Test Song"),
                title: "Test Song", artist: "", genre: "", duration: 180,
                location: URL(fileURLWithPath: "/test.wav"), dateAdded: .distantPast)
            let coordinator = TrackTable.Coordinator()
            coordinator.rows = [row]
            coordinator.table = table
            coordinator.parent = TrackTable(rows: [row], version: 0, selection: .constant([row.id]),
                sort: .constant(nil), cell: { _, _ in AnyView(EmptyView()) }, menu: { _ in [] },
                onOpen: { _ in }, onCommand: { commands.append(($0, $1)) })
            table.coordinator = coordinator
            table.selectRowIndexes([0], byExtendingSelection: false)
            window.makeFirstResponder(table)
            let keys: [(String, NSEvent.ModifierFlags, UInt16, TrackCommand)] = [
                ("\r", [], 36, .play(fromMixIn: false)), (" ", [], 49, .togglePlay),
                ("h", [], 4, .songStart), ("l", [], 37, .preview),
                ("H", .shift, 4, .beats(-32)), ("L", .shift, 37, .beats(32)),
                ("a", [], 0, .addToPlaylist), ("/", [], 44, .search), ("?", .shift, 44, .help),
            ] + (1...5).map { (String($0), [], UInt16(18 + $0), .hotCue($0)) }
              + (0...5).map { (String($0), .option, UInt16(18 + $0), .rate($0)) }
            for (text, flags, code, expected) in keys {
                let count = commands.count
                table.keyDown(with: key(text, in: window, flags: flags, code: code))
                #expect(commands.count == count + 1)
                #expect(commands.last?.0 == expected)
                #expect(commands.last?.1 == [row.id])
            }
            let count = commands.count
            for text in ["p", "P", "q", "Q", "6", "7", "8", ",", ".", "<", ">", "{", "}", "m", "r"] {
                table.keyDown(with: key(text, in: window))
            }
            table.keyDown(with: key("\r", in: window, flags: .shift, code: 36))
            table.keyDown(with: key("l", in: window, flags: .command, code: 37))
            table.keyDown(with: key("h", in: window, flags: .control, code: 4))
            #expect(commands.count == count)
            window.makeFirstResponder(button)
            #expect(table.routeWorkspaceNavigation(key("h", in: window, code: 4)))
            #expect(commands.last?.0 == .songStart)
            #expect(commands.count == count + 1)
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
                for text in ["h", "l", "H", "L", "a", "/", "1"] {
                    #expect(!table.routeWorkspaceNavigation(key(text, in: window)))
                }
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
