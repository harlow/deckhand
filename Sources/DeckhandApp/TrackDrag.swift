import Foundation
import UniformTypeIdentifiers

/// Local track IDs. The plain-text representation also supports dropping into the queue.
enum TrackDrag {
    static let type = UTType(exportedAs: "rocks.deckhand.tracks", conformingTo: .data)
    private static let prefix = "deckhand-tracks:"

    static func encode(_ ids: [String]) -> String {
        prefix + ids.joined(separator: ",")
    }

    static func decode(_ items: [String]) -> [String] {
        items.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
    }
}
