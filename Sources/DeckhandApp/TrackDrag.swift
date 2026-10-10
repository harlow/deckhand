import Foundation

/// Drag payload for tracks: their Apple Music IDs as tagged plain text, so drops from other apps are ignored.
enum TrackDrag {
    private static let prefix = "deckhand-tracks:"

    static func encode(_ ids: [String]) -> String {
        prefix + ids.joined(separator: ",")
    }

    static func decode(_ items: [String]) -> [String] {
        items.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
    }
}
