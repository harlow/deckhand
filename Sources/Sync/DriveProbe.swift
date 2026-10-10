import Foundation
import OneLibrary

/// What's on a drive, read in one pass: Deckhand's audio, analysis and artwork files and the database's identity.
/// Paths compare the way FAT does: case-insensitively, after Unicode normalization.
public struct DriveProbe: Sendable {
    /// `OneLibraryDatabase.fileId` of the drive's database; nil if there's none.
    public var databaseId: String?
    var audio: Set<String> = []
    /// ANLZ directory → which of DAT, EXT, 2EX it holds (bits 0–2).
    var anlz: [String: UInt8] = [:]
    var images: Set<String> = []
    /// Sizes of drive copies the manifest doesn't record (older manifests).
    var sizes: [String: Int64] = [:]
    /// The drive database's content IDs by path, read only when evaluate finds audio already at a new track's path
    /// (as after a sync cut short between replacing the database and saving the manifest).
    var databaseContentIds: [String: Int]?

    public init() {}

    static let databasePath = "/PIONEER/rekordbox/exportLibrary.db"
    static let audioRoot = "/Contents/Deckhand"
    static let anlzFiles = ["ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX"]
    static let allAnlz: UInt8 = 0b111

    static func key(_ path: String) -> String {
        (path.utf8.allSatisfy { $0 < 0x80 } ? path : path.precomposedStringWithCanonicalMapping).lowercased()
    }

    public func hasAudio(_ usbPath: String) -> Bool { audio.contains(Self.key(usbPath)) }
    func hasAllAnlz(forAudio usbPath: String) -> Bool {
        anlz[Self.key(AnlzPath.directory(forAudioPath: usbPath))] == Self.allAnlz
    }
    func hasImage(_ usbPath: String) -> Bool { images.contains(Self.key(usbPath)) }
    func size(_ usbPath: String) -> Int64? { sizes[Self.key(usbPath)] }

    mutating func addAudio(_ usbPath: String) { audio.insert(Self.key(usbPath)) }
    mutating func removeAudio(_ usbPath: String) { audio.remove(Self.key(usbPath)) }
    mutating func addAnlz(forAudio usbPath: String) {
        anlz[Self.key(AnlzPath.directory(forAudioPath: usbPath))] = Self.allAnlz
    }
    mutating func addImage(_ usbPath: String) { images.insert(Self.key(usbPath)) }
}

extension DriveProbe {
    /// Walks /Contents/Deckhand, /PIONEER/USBANLZ and /PIONEER/Artwork with readdir (no stat per file), reads the
    /// database's first 16 bytes, and stats only manifest tracks outside Deckhand's folder or without a recorded size.
    public static func scan(_ volume: Volume, manifest: Manifest?) -> DriveProbe {
        var p = DriveProbe()
        p.databaseId = OneLibraryDatabase.fileId(volume.url(forUsbPath: databasePath))
        let root = volume.url.path
        walk(root, audioRoot, depth: 2) { p.audio.insert(key($0)) }
        walk(root, "/PIONEER/USBANLZ", depth: 3) { path in
            let name = (path as NSString).lastPathComponent.uppercased()
            guard let bit = anlzFiles.firstIndex(of: name) else { return }
            p.anlz[key((path as NSString).deletingLastPathComponent), default: 0] |= 1 << bit
        }
        walk(root, "/PIONEER/Artwork", depth: 2) { p.images.insert(key($0)) }
        let ownFolder = key(audioRoot + "/")
        for t in (manifest?.tracks ?? [:]).values {
            let k = key(t.usbPath)
            if !k.hasPrefix(ownFolder), FileManager.default.fileExists(atPath: volume.url(forUsbPath: t.usbPath).path) {
                p.audio.insert(k)
            }
            if t.fileSize == nil, p.audio.contains(k), let a = FileOps.attributes(volume.url(forUsbPath: t.usbPath)) {
                p.sizes[k] = a.size
            }
        }
        return p
    }

    /// Calls `visit` with the USB path of each file up to `depth` levels below `dir`. Skips dot files: AppleDouble
    /// sidecars, Deckhand's temporary copies, Finder's files.
    private static func walk(_ root: String, _ dir: String, depth: Int, _ visit: (String) -> Void) {
        guard let d = opendir(root + dir) else { return }
        defer { closedir(d) }
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if name.hasPrefix(".") { continue }
            let path = dir + "/" + name
            var isDirectory = e.pointee.d_type == DT_DIR
            if e.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                isDirectory = lstat(root + path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            if isDirectory {
                if depth > 1 { walk(root, path, depth: depth - 1, visit) }
            } else {
                visit(path)
            }
        }
    }
}
