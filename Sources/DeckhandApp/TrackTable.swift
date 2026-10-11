import AppKit
import SwiftUI

/// The track list's columns, in display order.
enum TrackColumn: String, CaseIterable {
    case status, title, overview, bpm, key, energy, rating, genre, time

    var title: String {
        switch self {
        case .status: ""
        case .title: "Title"
        case .overview: "Overview"
        case .bpm: "BPM"
        case .key: "Key"
        case .energy: "Energy"
        case .rating: "Rating"
        case .genre: "Genre"
        case .time: "Time"
        }
    }

    /// (minimum, ideal, maximum) width.
    var widths: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .status: (16, 16, 16)
        case .title: (150, 260, 1000)
        case .overview: (160, 320, 2000)
        case .bpm: (50, 60, 90)
        case .key: (44, 50, 70)
        case .energy: (80, 90, 120)
        case .rating: (70, 76, 100)
        case .genre: (70, 130, 400)
        case .time: (40, 48, 70)
        }
    }

    var sortable: Bool { self != .status && self != .overview }
    /// Cells with their own controls get mouse events; others pass clicks to the table.
    var interactive: Bool { self == .overview || self == .rating }
}

struct TrackSort: Equatable {
    var column: TrackColumn
    var ascending: Bool
}

/// Keyboard commands the track list hands to its owner (movement and selection it handles itself).
/// See `KeyTableView.keyDown` for the key map and `KeyboardHelpView` for the cheat sheet.
enum TrackCommand: Equatable {
    case play(fromMixIn: Bool), preview, togglePlay, queue(next: Bool)
    case hotCue(Int), beats(Int), section(Int), rate(Int)
    case toggleMixes, search, revealPlaying, help, delete, addToPlaylist, review
    case songStart
}

extension Notification.Name {
    /// Ask the search field to take keyboard focus.
    static let focusSearch = Notification.Name("deckhand.focusSearch")
    /// Ask the track list to take keyboard focus (e.g. Escape from search).
    static let focusTracks = Notification.Name("deckhand.focusTracks")
    static let focusSidebar = Notification.Name("deckhand.focusSidebar")
}

/// A context-menu entry built in SwiftUI land and turned into an NSMenuItem.
struct TrackMenuItem {
    var title = ""
    var action: (() -> Void)?
    var children: [TrackMenuItem] = []
    var enabled = true
    var separator = false

    static let divider = TrackMenuItem(separator: true)
}

/// The track list, on NSTableView: fixed-height rows that are only built when visible, so large
/// libraries scroll and switch instantly (SwiftUI's Table measured every row up front). Cells are
/// SwiftUI views hosted per visible cell.
struct TrackTable: NSViewRepresentable {
    var rows: [TrackRow]
    /// Changes whenever `rows` does, so unrelated redraws skip diffing them.
    var version: Int
    /// A new request focuses after the new playlist's rows and selection have been applied.
    var focusRequest: Int = 0
    @Binding var selection: Set<String>
    @Binding var sort: TrackSort?
    var cell: (TrackColumn, TrackRow) -> AnyView
    var menu: ([String]) -> [TrackMenuItem]
    var onOpen: (TrackRow) -> Void
    /// A keyboard command, with the rows it applies to (the selection).
    var onCommand: (TrackCommand, [String]) -> Void
    var onDragBegin: ([String]) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        // Single letters are commands, so typing doesn't jump to titles; `/` searches.
        table.allowsTypeSelect = false
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for c in TrackColumn.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            let (lo, ideal, hi) = c.widths
            col.minWidth = lo
            col.width = ideal
            col.maxWidth = hi
            col.resizingMask = c == .overview || c == .title ? [.autoresizingMask, .userResizingMask] : (lo == hi ? [] : .userResizingMask)
            if c.sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: true) }
            table.addTableColumn(col)
        }
        table.autosaveName = "DeckhandTracks"
        table.autosaveTableColumns = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(forName: .focusTracks, object: nil, queue: .main) { [weak table] _ in
            MainActor.assumeIsolated {
                guard let table else { return }
                table.window?.makeFirstResponder(table)
                if table.selectedRow < 0, table.numberOfRows > 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        if c.version != version {
            c.version = version
            let old = c.rows
            c.rows = rows
            if old.count != rows.count || !zip(old, rows).allSatisfy({ $0.id == $1.id }) {
                c.index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                table.reloadData()
            } else {
                let changed = IndexSet(rows.indices.filter { rows[$0] != old[$0] })
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
        }
        let wanted = sort.map { [NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)] } ?? []
        if table.sortDescriptors != wanted {
            c.applying = true
            table.sortDescriptors = wanted
            c.applying = false
        }
        let selected = IndexSet(selection.compactMap { c.index[$0] })
        if table.selectedRowIndexes != selected {
            c.applying = true
            table.selectRowIndexes(selected, byExtendingSelection: false)
            c.applying = false
            if let first = selected.first { table.scrollRowToVisible(first) }
        }
        if c.focusRequest != focusRequest {
            c.focusRequest = focusRequest
            if focusRequest != 0 {
                let request = focusRequest
                DispatchQueue.main.async { [weak c] in
                    guard let c, c.focusRequest == request, let table = c.table, let window = table.window else { return }
                    window.makeFirstResponder(table)
                    if table.selectedRow < 0, table.numberOfRows > 0 {
                        table.selectRowIndexes([0], byExtendingSelection: false)
                    }
                    if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TrackTable?
        weak var table: NSTableView?
        var rows: [TrackRow] = []
        var version: Int?
        var focusRequest: Int?
        var index: [String: Int] = [:]
        /// Set while pushing SwiftUI state into the table, so the delegate doesn't echo it back.
        var applying = false
        var focusObserver: NSObjectProtocol?

        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = TrackColumn(rawValue: id.rawValue),
                  row < rows.count, let parent else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HostingCell ?? {
                let c = HostingCell(interactive: column.interactive)
                c.identifier = id
                return c
            }()
            cell.content = parent.cell(column, rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count else { return nil }
            let item = NSPasteboardItem()
            let payload = TrackDrag.encode([rows[row].id])
            item.setString(payload, forType: .string)
            item.setData(Data(payload.utf8), forType: NSPasteboard.PasteboardType(TrackDrag.type.identifier))
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            parent?.onDragBegin(rowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            parent?.onDragEnd()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, let parent else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            if ids != parent.selection { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let parent else { return }
            let d = tableView.sortDescriptors.first
            parent.sort = d.flatMap { d in d.key.flatMap(TrackColumn.init(rawValue:)).map { TrackSort(column: $0, ascending: d.ascending) } }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            parent?.onOpen(rows[row])
        }

        /// The rows an action applies to: the selection, or the clicked row when it's outside it.
        func targetIds(clicked: Int) -> [String] {
            guard let table else { return [] }
            if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked) { return [rows[clicked].id] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let parent else { return }
            let ids = targetIds(clicked: table.clickedRow)
            guard !ids.isEmpty else { return }
            for item in parent.menu(ids) { menu.addItem(Self.build(item)) }
        }

        private static func build(_ item: TrackMenuItem) -> NSMenuItem {
            if item.separator { return .separator() }
            let m = ClosureMenuItem(title: item.title, action: item.action)
            m.isEnabled = item.enabled && (item.action != nil || !item.children.isEmpty)
            if !item.children.isEmpty {
                let sub = NSMenu(title: item.title)
                for child in item.children { sub.addItem(build(child)) }
                m.submenu = sub
            }
            return m
        }
    }
}

/// The song-list shortcuts are shown in KeyboardHelpView. Arrow keys, Shift-arrows, ⌘A and
/// ⌘↑/⌘↓ keep their standard table behavior; unmodified letter keys never intercept typing.
final class KeyTableView: NSTableView {
    weak var coordinator: TrackTable.Coordinator?
    private var navigationMonitor: Any?
    private var trackingMenus = Set<ObjectIdentifier>()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
        navigationMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        trackingMenus.removeAll()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan(_:)),
                                              name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingEnded(_:)),
                                              name: NSMenu.didEndTrackingNotification, object: nil)
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.routeWorkspaceNavigation(event) == true ? nil : event
        }
    }

    deinit {
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
    }

    @objc private func menuTrackingBegan(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
    }

    @objc private func menuTrackingEnded(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    /// Route song shortcuts from this table’s workspace, while editors and modal UI keep their keys.
    @discardableResult
    func routeWorkspaceNavigation(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, !window.isSheet, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor, window.firstResponder !== self,
              !(window.firstResponder is KeyboardShortcutView) else { return false }
        if let editor = window.firstResponder as? NSText, editor.isEditable { return false }
        if let field = window.firstResponder as? NSTextField, field.isEditable { return false }
        if collapseSelection(with: event) {
            window.makeFirstResponder(self)
            return true
        }
        if let delta = Self.navigationDelta(event) {
            guard numberOfRows > 0 else { return false }
            move(delta, extend: false)
            window.makeFirstResponder(self)
            return true
        }
        guard Self.songCommand(event) != nil else { return false }
        window.makeFirstResponder(self)
        keyDown(with: event)
        return true
    }

    private static func navigationDelta(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": return 1
        case "k": return -1
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if collapseSelection(with: event) { return }
        if let delta = Self.navigationDelta(event) {
            move(delta, extend: event.modifierFlags.contains(.shift))
            return
        }
        guard let c = coordinator, let parent = c.parent else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let ch = event.charactersIgnoringModifiers ?? ""
        let send = { (cmd: TrackCommand) in parent.onCommand(cmd, c.targetIds(clicked: -1)) }

        if flags.contains(.control) { return super.keyDown(with: event) }

        if flags.contains(.command) {
            switch (event.keyCode, ch) {
            case (126, _): select(0)
            case (125, _): select(numberOfRows - 1)
            default: super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 48, shift {
            NotificationCenter.default.post(name: .focusSidebar, object: nil)
            return
        }
        if let command = Self.songCommand(event) { send(command) }
        else { super.keyDown(with: event) }
    }

    /// Escape leaves one selected song, without changing playback or playlist contents.
    private func collapseSelection(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              trackingMenus.isEmpty,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              selectedRowIndexes.count > 1, let row = selectedRowIndexes.first else { return false }
        select(row)
        return true
    }

    private static func songCommand(_ event: NSEvent) -> TrackCommand? {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)
        let text = event.charactersIgnoringModifiers ?? ""
        guard flags.intersection([.command, .control]).isEmpty else { return nil }
        if flags.contains(.option) {
            return Int(text).flatMap { (0...5).contains($0) ? .rate($0) : nil }
        }
        switch event.keyCode {
        case 51, 117: return .delete
        case 49 where !shift: return .togglePlay
        case 36 where !shift, 76 where !shift: return .play(fromMixIn: false)
        default: break
        }
        switch text.lowercased() {
        case "h": return shift ? .beats(-64) : .songStart // 16 four-beat bars.
        case "l": return shift ? .beats(64) : .preview
        case "a" where !shift: return .addToPlaylist
        case "1" where !shift, "2" where !shift, "3" where !shift, "4" where !shift, "5" where !shift: return .hotCue(Int(text)!)
        case "/" where !shift: return .search
        case "?": return .help
        default: return nil
        }
    }

    private func move(_ delta: Int, extend: Bool) {
        let n = numberOfRows
        guard n > 0 else { return }
        let from = delta > 0 ? (selectedRowIndexes.last ?? -1) : (selectedRowIndexes.first ?? n)
        let target = max(0, min(n - 1, from + delta))
        selectRowIndexes([target], byExtendingSelection: extend)
        scrollRowToVisible(target)
    }

    private func select(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes([row], byExtendingSelection: false)
        scrollRowToVisible(row)
    }
}

/// A table cell hosting SwiftUI content. Non-interactive cells let clicks through to the table
/// (selection, dragging, double-click); selected rows get the emphasized (white-on-blue) style.
final class HostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let interactive: Bool

    var content = AnyView(EmptyView()) { didSet { render() } }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { if oldValue != backgroundStyle { render() } } }

    init(interactive: Bool) {
        self.interactive = interactive
        super.init(frame: .zero)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func render() {
        host.rootView = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.backgroundProminence, backgroundStyle == .emphasized ? .increased : .standard)
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, action handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler?() }
}
