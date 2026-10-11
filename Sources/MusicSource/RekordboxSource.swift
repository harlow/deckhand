import DeckhandCore
import Foundation

/// Rekordbox's documented XML exchange format. Reading it does not open or edit its desktop database.
public struct RekordboxSource: LibrarySourceAdapter {
    public let connection: SourceConnection
    public init(connection: SourceConnection) { self.connection = connection }

    static func document(at url: URL) throws -> XMLDocument {
        try document(data: Data(contentsOf: url))
    }

    static func document(data: Data) throws -> XMLDocument {
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
            throw LibrarySourceError.invalidXML("Choose a UTF-8 Rekordbox collection XML file without a document type declaration.")
        }
        let doc = try XMLDocument(data: data, options: [.nodePreserveAll])
        guard doc.rootElement()?.name == "DJ_PLAYLISTS",
              doc.rootElement()?.elements(forName: "COLLECTION").count == 1,
              doc.rootElement()?.elements(forName: "PLAYLISTS").count == 1 else {
            throw LibrarySourceError.invalidXML("This isn't a Rekordbox collection export. In Rekordbox, choose File → Export Collection in xml format.")
        }
        return doc
    }

    public func load(files: [String: IndexedAudioFile]) async throws -> SourceRead {
        guard let url = connection.location else { throw LibrarySourceError.unavailable("Choose a Rekordbox XML file.") }
        let data = try Data(contentsOf: url)
        let doc = try Self.document(data: data)
        let collection = doc.rootElement()!.elements(forName: "COLLECTION")[0]
        var tracks: [String: SourceTrack] = [:]
        var externalIDs: [String: String] = [:]
        var locations: [String: String] = [:]
        var all: [String] = []
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        for element in collection.elements(forName: "TRACK") {
            let a = element.attributesDictionary
            guard let externalID = a["TrackID"], externalIDs[externalID] == nil,
                  let path = a["Location"], let location = URL(string: path), location.isFileURL else {
                throw LibrarySourceError.invalidXML("A Rekordbox track has a duplicate/missing ID or invalid local file location.")
            }
            let id = connection.trackID(externalID)
            let rating = a["Rating"].flatMap(Int.init).map { max(0, min(5, Int((Double($0) / 51).rounded()))) }
            var t = SourceTrack(id: id, title: a["Name"] ?? location.deletingPathExtension().lastPathComponent,
                                artist: a["Artist"], album: a["Album"], genre: a["Genre"],
                                trackNumber: a["TrackNumber"].flatMap(Int.init), discNumber: a["DiscNumber"].flatMap(Int.init),
                                year: a["Year"].flatMap(Int.init), rating: rating, comment: a["Comments"],
                                durationSeconds: a["TotalTime"].flatMap(Double.init), location: location,
                                dateAdded: a["DateAdded"].flatMap(date.date(from:)), playCount: a["PlayCount"].flatMap(Int.init),
                                lastPlayed: a["LastPlayed"].flatMap(date.date(from:)),
                                modifiedDate: a["DateModified"].flatMap(date.date(from:)), fileSize: a["Size"].flatMap(Int64.init))
            if !FileManager.default.isReadableFile(atPath: location.path) { t.unavailableReason = "Audio file is missing or unreadable" }
            tracks[id] = t
            externalIDs[externalID] = id
            locations[path] = id
            locations[location.standardizedFileURL.path] = id
            all.append(id)
        }
        var playlists: [SourcePlaylist] = []
        var seen = Set<String>()
        func visit(_ element: XMLElement, parent: String?, path: [String], root: Bool = false) throws {
            let a = element.attributesDictionary
            if root {
                for child in element.elements(forName: "NODE") { try visit(child, parent: nil, path: []) }
                return
            }
            guard let name = a["Name"], let type = a["Type"], type == "0" || type == "1" else {
                throw LibrarySourceError.invalidXML("A Rekordbox playlist has no name or an invalid type.")
            }
            let parts = path + [name]
            let key = String(data: try JSONEncoder().encode(parts), encoding: .utf8)!
            let id = connection.playlistID(key)
            guard seen.insert(id).inserted else { throw LibrarySourceError.invalidXML("Duplicate Rekordbox playlist path: \(parts.joined(separator: " / ")).") }
            let folder = type == "0"
            var ids: [String] = []
            if !folder {
                for item in element.elements(forName: "TRACK") {
                    guard let key = item.attribute(forName: "Key")?.stringValue else {
                        throw LibrarySourceError.invalidXML("A playlist contains a track without a Key.")
                    }
                    let track = a["KeyType"] == "1" ? locations[key] ?? URL(string: key).flatMap { locations[$0.standardizedFileURL.path] }
                        : externalIDs[key]
                    guard let track else { throw LibrarySourceError.invalidXML("Playlist “\(name)” refers to a track missing from its collection.") }
                    ids.append(track)
                }
            }
            playlists.append(SourcePlaylist(id: id, name: name, parentId: parent, isFolder: folder, trackIds: ids))
            for child in element.elements(forName: "NODE") { try visit(child, parent: id, path: parts) }
        }
        let roots = doc.rootElement()!.elements(forName: "PLAYLISTS")[0].elements(forName: "NODE")
        for root in roots {
            try visit(root, parent: nil, path: [], root: root.attribute(forName: "Name")?.stringValue == "ROOT"
                      && root.attribute(forName: "Type")?.stringValue == "0")
        }
        var library = SourceLibrary(playlists: playlists, tracks: tracks, artwork: FileArtwork(tracks: tracks))
        library.sourceID = connection.id
        library.allTrackIds = all
        return SourceRead(library: library, files: files, originalXML: data)
    }

    /// Builds a new exchange file, preserving the original track nodes (including cues and grids) where possible.
    public static func export(_ library: SourceLibrary, original: URL, to destination: URL,
                              originalData: Data? = nil, originalTrackIDs: [String: String] = [:]) throws {
        guard original.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw LibrarySourceError.invalidXML("Save to a new XML file so the imported source stays intact.")
        }
        let originalDoc = try originalData.map { try document(data: $0) } ?? document(at: original)
        let originalTracks = originalDoc.rootElement()!.elements(forName: "COLLECTION")[0].elements(forName: "TRACK")
        let originals = Dictionary(originalTracks.compactMap { node -> (String, XMLElement)? in
            guard let id = node.attribute(forName: "TrackID")?.stringValue else { return nil }
            return (id, node)
        }, uniquingKeysWith: { first, _ in first })
        let root = XMLElement(name: "DJ_PLAYLISTS")
        root.setAttribute("Version", "1.0.0")
        let product = XMLElement(name: "PRODUCT")
        product.setAttribute("Name", "Deckhand")
        product.setAttribute("Version", "0.1")
        product.setAttribute("Company", "Deckhand")
        root.addChild(product)
        let collection = XMLElement(name: "COLLECTION")
        var keys: [String: String] = [:]
        for (offset, track) in library.tracks.values.sorted(by: { $0.id < $1.id }).enumerated() {
            guard let url = track.location else { continue }
            let external = originalTrackIDs[track.id] ?? track.id.components(separatedBy: ":track:").last ?? ""
            let node = originals[external]?.copy() as? XMLElement ?? XMLElement(name: "TRACK")
            let key = String(offset + 1)
            keys[track.id] = key
            node.setAttribute("TrackID", key)
            var location = URLComponents(url: url, resolvingAgainstBaseURL: true)
            location?.host = "localhost"
            node.setAttribute("Location", location?.url?.absoluteString ?? url.absoluteString)
            node.setAttribute("Name", track.title)
            node.setAttribute("Rating", String((track.rating ?? 0) * 51))
            if let value = track.artist { node.setAttribute("Artist", value) }
            if let value = track.album { node.setAttribute("Album", value) }
            if let value = track.genre { node.setAttribute("Genre", value) }
            if let value = track.comment { node.setAttribute("Comments", value) }
            if let value = track.durationSeconds { node.setAttribute("TotalTime", String(Int(value))) }
            collection.addChild(node)
        }
        collection.setAttribute("Entries", String(keys.count))
        root.addChild(collection)
        let playlists = XMLElement(name: "PLAYLISTS")
        let rootFolder = XMLElement(name: "NODE")
        rootFolder.setAttribute("Name", "ROOT")
        rootFolder.setAttribute("Type", "0")
        func append(_ parent: String?, to node: XMLElement, ancestors: Set<String>) throws {
            let children = library.playlists.filter { $0.parentId == parent }
            node.setAttribute("Count", String(children.count))
            for p in children {
                guard !ancestors.contains(p.id) else { throw LibrarySourceError.invalidXML("Playlist hierarchy contains a cycle.") }
                let child = XMLElement(name: "NODE")
                child.setAttribute("Name", p.name)
                child.setAttribute("Type", p.isFolder ? "0" : "1")
                if p.isFolder { try append(p.id, to: child, ancestors: ancestors.union([p.id])) }
                else {
                    let ids = p.trackIds.compactMap { keys[$0] }
                    child.setAttribute("Entries", String(ids.count))
                    child.setAttribute("KeyType", "0")
                    for id in ids {
                        let item = XMLElement(name: "TRACK")
                        item.setAttribute("Key", id)
                        child.addChild(item)
                    }
                }
                node.addChild(child)
            }
        }
        try append(nil, to: rootFolder, ancestors: [])
        playlists.addChild(rootFolder)
        root.addChild(playlists)
        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        try doc.xmlData(options: [.nodePrettyPrint]).write(to: destination, options: .atomic)
    }
}

private extension XMLElement {
    var attributesDictionary: [String: String] {
        Dictionary((attributes ?? []).compactMap { a in a.name.flatMap { name in a.stringValue.map { (name, $0) } } },
                   uniquingKeysWith: { first, _ in first })
    }
    func setAttribute(_ name: String, _ value: String) {
        removeAttribute(forName: name)
        addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }
}
