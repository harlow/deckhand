@testable import DeckhandApp
import AppKit
import DeckhandCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct MatchesTableTests {
    @Test func returningFromLongMatchesListPreservesOriginalSongSelection() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func rows(_ prefix: String, count: Int) -> [TrackRow] {
            (0..<count).map { i in
                let id = "\(prefix)-\(i)"
                return TrackRow(id: id, source: SourceTrack(id: id, title: id), title: id, artist: "",
                    genre: "", duration: 20, location: URL(fileURLWithPath: "/\(id).wav"), dateAdded: .distantPast)
            }
        }
        var selection: Set<String> = ["origin-2"]
        func view(_ rows: [TrackRow], version: Int) -> TrackTable {
            TrackTable(rows: rows, version: version, selection: Binding(get: { selection }, set: { selection = $0 }),
                sort: .constant(nil), cell: { _, row in AnyView(Text(row.title)) }, menu: { _ in [] },
                onOpen: { _ in }, onCommand: { _, _ in })
        }
        let host = NSHostingView(rootView: view(rows("origin", count: 3), version: 1))
        window.contentView = host
        func findTable(_ view: NSView) -> KeyTableView? {
            if let table = view as? KeyTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        for _ in 0..<100 where findTable(host)?.numberOfRows != 3 {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
        let table = try #require(findTable(host))
        #expect(table.selectedRow == 2 && selection == ["origin-2"])
        selection = ["match-49"]
        host.rootView = view(rows("match", count: 50), version: 2)
        for _ in 0..<100 where table.numberOfRows != 50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(table.selectedRow == 49 && selection == ["match-49"])
        selection = ["origin-2"]
        host.rootView = view(rows("origin", count: 3), version: 3)
        for _ in 0..<100 where table.numberOfRows != 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(table.selectedRow == 2 && selection == ["origin-2"])
    }
}
