import SwiftUI

struct PlaylistCopy: Equatable {
    var targetID: String
    var sourceID: String?
    var trackIDs: [String]
    var skipped: Int
}

struct PlaylistPosition: Equatable {
    var playlistID: String
    var parentID: String?
    var beforeID: String?
}

enum PlaylistDropLocation { case on, before, after }

enum PlaylistDrop: Equatable {
    case move(String, String?)
    case position(PlaylistPosition)
    case copy(PlaylistCopy)

    var operation: DropOperation {
        switch self {
        case .move, .position: .move
        case .copy(let copy): copy.trackIDs.isEmpty ? .cancel : .copy
        }
    }

    var copy: PlaylistCopy? {
        if case .copy(let copy) = self { return copy }
        return nil
    }
}

/// Explicit proposals let self-drops refuse a copy cursor, while folder drops remain moves.
struct PlaylistDropDelegate: DropDelegate {
    var library: LibraryModel
    var targetID: String?
    var rowHeight: CGFloat? = nil
    var targeted: (PlaylistDropLocation?) -> Void
    var receive: (PlaylistDrop) -> Void

    static var types: [String] { [PlaylistDrag.type.identifier, TrackDrag.type.identifier] }

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: Self.types)
            && plan(library.draggedItems, at: location(info)).map { $0.operation != .cancel } == true
    }

    private func location(_ info: DropInfo) -> PlaylistDropLocation {
        guard PlaylistDrag.decode(library.draggedItems) != nil, let rowHeight else { return .on }
        if info.location.y < 7 { return .before }
        if info.location.y > rowHeight - 7 { return .after }
        return .on
    }

    private func plan(_ items: [String], at location: PlaylistDropLocation) -> PlaylistDrop? {
        library.playlistDrop(items, into: targetID, at: location)
    }

    func dropEntered(info: DropInfo) { targeted(validateDrop(info: info) ? location(info) : nil) }
    func dropExited(info: DropInfo) { targeted(nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let place = location(info)
        let operation = plan(library.draggedItems, at: place)?.operation ?? .cancel
        targeted(operation != .cancel ? place : nil)
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = location(info)
        targeted(nil)
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        library.draggedItems = []
        // The hover cache is never trusted for a write: read the providers from this drag session.
        Task { @MainActor in
            var items: [String] = []
            for provider in providers {
                let type = provider.hasItemConformingToTypeIdentifier(PlaylistDrag.type.identifier)
                    ? PlaylistDrag.type.identifier : TrackDrag.type.identifier
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
                }
                guard let data, let item = String(data: data, encoding: .utf8) else { return }
                items.append(item)
            }
            guard let drop = plan(items, at: place), drop.operation != .cancel else { return }
            receive(drop)
        }
        return true
    }
}
