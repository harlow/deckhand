import Foundation
import OneLibrary

/// Finds files on a Deckhand drive left over from another tool (typically a Rekordbox export) that
/// nothing on the drive uses anymore. Never touches files outside the music/library folders,
/// player settings, or anything Deckhand owns.
public struct DriveCleanup {
    public enum Category: String, CaseIterable, Sendable {
        case audio = "Audio not in your library (Rekordbox leftovers)"
        case analysis = "Old analysis files"
        case artwork = "Old artwork"
        case legacyDatabase = "Rekordbox legacy database (export.pdb, read by older CDJs)"
        case emptyFolders = "Empty folders"
    }

    public struct Item: Sendable {
        public var category: Category
        /// USB-relative.
        public var path: String
        public var bytes: Int64
    }

    public var items: [Item]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// Files in /PIONEER/rekordbox written by other tools that Deckhand's library replaces.
    static let legacyFiles = ["export.pdb", "exportExt.pdb", "playlists3.sync", "playlists3Plus.sync"]

    public static func scan(_ volume: Volume, manifest: Manifest) throws -> DriveCleanup {
        let fm = FileManager.default
        var items: [Item] = []
        let ownedAudio = Set(manifest.tracks.values.map(\.usbPath))
        let ownedAnlz = Set(ownedAudio.map { AnlzPath.directory(forAudioPath: $0) })
        let referencedArt = try referencedImages(volume)
        let volumePath = volume.url.resolvingSymlinksInPath().path

        func relative(_ url: URL) -> String {
            "/" + url.resolvingSymlinksInPath().path.dropFirst(volumePath.count).drop(while: { $0 == "/" })
        }
        func walk(_ usbPath: String, _ visit: (URL, String) -> Void) {
            guard let e = fm.enumerator(at: volume.url(forUsbPath: usbPath), includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            for case let url as URL in e where !url.lastPathComponent.hasPrefix("._") {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                visit(url, relative(url))
            }
        }

        walk("/Contents") { url, path in
            guard !path.hasPrefix("/Contents/Deckhand/"), !ownedAudio.contains(path),
                  AdoptScanner.audioExtensions.contains(url.pathExtension.lowercased()) else { return }
            items.append(Item(category: .audio, path: path, bytes: FileOps.size(url)))
        }
        walk("/PIONEER/USBANLZ") { url, path in
            let dir = (path as NSString).deletingLastPathComponent
            guard !ownedAnlz.contains(dir) else { return }
            items.append(Item(category: .analysis, path: path, bytes: FileOps.size(url)))
        }
        walk("/PIONEER/Artwork") { url, path in
            let small = path.replacingOccurrences(of: "_m.jpg", with: ".jpg")
            guard !referencedArt.contains(small) else { return }
            items.append(Item(category: .artwork, path: path, bytes: FileOps.size(url)))
        }
        for name in legacyFiles {
            let path = "/PIONEER/rekordbox/" + name
            let url = volume.url(forUsbPath: path)
            if fm.fileExists(atPath: url.path) { items.append(Item(category: .legacyDatabase, path: path, bytes: FileOps.size(url))) }
        }
        let removing = Set(items.map(\.path))
        for root in ["/Contents", "/PIONEER/USBANLZ", "/PIONEER/Artwork"] {
            items += emptyFolders(volume, root: root, ignoring: removing).map { Item(category: .emptyFolders, path: $0, bytes: 0) }
        }
        return DriveCleanup(items: items)
    }

    /// Deletes the listed items, files first, then folders deepest-first. Returns paths that failed.
    public func apply(_ volume: Volume) -> [String] {
        var failed: [String] = []
        for item in items where item.category != .emptyFolders {
            let url = volume.url(forUsbPath: item.path)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failed.append(item.path)
            }
            let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
            unlink(sidecar.path)
        }
        for item in items.filter({ $0.category == .emptyFolders }).sorted(by: { $0.path.count > $1.path.count }) {
            let url = volume.url(forUsbPath: item.path)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasPrefix("._") || name == ".DS_Store" {
                unlink(url.appendingPathComponent(name).path)
            }
            if rmdir(url.path) != 0 { failed.append(item.path) }
            unlink(url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent).path)
        }
        FileOps.syncFilesystem()
        return failed
    }

    private static func referencedImages(_ volume: Volume) throws -> Set<String> {
        let db = volume.url(forUsbPath: "/PIONEER/rekordbox/exportLibrary.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        return try DeviceArtwork.paths(database: db)
    }

    /// Folders under `root` that would be empty once `ignoring` files (and macOS metadata) are removed.
    private static func emptyFolders(_ volume: Volume, root: String, ignoring: Set<String>) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        @discardableResult
        func visit(_ path: String) -> Bool {
            let url = volume.url(forUsbPath: path)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
            var empty = true
            for name in names where !(name.hasPrefix("._") || name == ".DS_Store") {
                let child = path + "/" + name
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDir)
                if isDir.boolValue {
                    if !visit(child) { empty = false }
                } else if !ignoring.contains(child) {
                    empty = false
                }
            }
            if empty, path != root { out.append(path) }
            return empty
        }
        visit(root)
        return out
    }
}
