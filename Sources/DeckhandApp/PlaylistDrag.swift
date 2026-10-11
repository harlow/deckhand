import UniformTypeIdentifiers

/// A distinct payload keeps sidebar organization separate from dragging tracks into playlists.
enum PlaylistDrag {
    static let type = UTType(exportedAs: "rocks.deckhand.playlist", conformingTo: .data)
    private static let prefix = "deckhand-playlist:"

    static func encode(_ id: String) -> String { prefix + id }

    static func decode(_ items: [String]) -> String? {
        guard items.count == 1, let item = items.first, item.hasPrefix(prefix) else { return nil }
        let id = String(item.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
