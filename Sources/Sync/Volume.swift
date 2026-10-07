import Foundation

/// A mounted volume and the properties Deckhand checks before writing to it.
public struct Volume: Sendable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let format: String
    public let isRemovable: Bool
    public let isInternal: Bool
    public let isReadOnly: Bool
    public let isRoot: Bool
    public let capacity: Int64
    public let available: Int64

    public init(url: URL) throws {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeURLKey,
        ]
        let v = try url.resourceValues(forKeys: keys)
        guard let root = v.volume, root.standardizedFileURL.path == url.standardizedFileURL.path else {
            throw SyncError.notAVolumeRoot(url.path)
        }
        self.url = root
        name = v.volumeName ?? root.lastPathComponent
        uuid = v.volumeUUIDString
        format = v.volumeLocalizedFormatDescription ?? "unknown"
        isRemovable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
        isInternal = v.volumeIsInternal ?? false
        isReadOnly = v.volumeIsReadOnly ?? false
        isRoot = v.volumeIsRootFileSystem ?? false
        capacity = Int64(v.volumeTotalCapacity ?? 0)
        available = Int64(v.volumeAvailableCapacity ?? 0)
    }

    /// A directory standing in for a drive, for tests.
    init(testRoot: URL) {
        url = testRoot
        name = testRoot.lastPathComponent
        uuid = nil
        format = "MS-DOS (FAT32)"
        isRemovable = true
        isInternal = false
        isReadOnly = false
        isRoot = false
        capacity = 1 << 40
        available = 1 << 40
    }

    /// Mounted volumes that look like external drives.
    public static func removable() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { try? Volume(url: $0) }.filter { $0.isRemovable && !$0.isInternal && !$0.isRoot }
    }

    /// Throws unless this volume is safe for Deckhand to write.
    public func checkWritable() throws {
        if isRoot || isInternal { throw SyncError.unsafeVolume(name, "it is an internal/system drive") }
        if isReadOnly { throw SyncError.unsafeVolume(name, "it is read-only") }
    }

    public var formatIsSupported: Bool {
        let f = format.lowercased()
        return f.contains("fat") || f.contains("exfat") || f.contains("ms-dos")
    }

    public func url(forUsbPath path: String) -> URL {
        url.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
    }
}
