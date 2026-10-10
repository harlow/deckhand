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
    /// A plain directory standing in for a drive (tests): not re-resolved as a volume while syncing.
    let isTestRoot: Bool

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
        isTestRoot = false
    }

    /// A directory standing in for a drive, for tests.
    init(testRoot: URL, available: Int64 = 1 << 40) {
        url = testRoot
        name = testRoot.lastPathComponent
        uuid = nil
        format = "MS-DOS (FAT32)"
        isRemovable = true
        isInternal = false
        isReadOnly = false
        isRoot = false
        capacity = 1 << 40
        self.available = available
        isTestRoot = true
    }

    /// Free space now (the value read at mount can be stale).
    func currentAvailable() throws -> Int64 {
        isTestRoot ? available : try Volume(url: url).available
    }

    /// Throws if the drive was unplugged.
    func ensureMounted() throws {
        guard FileManager.default.fileExists(atPath: url.path), isTestRoot || (try? Volume(url: url)) != nil else {
            throw SyncError.volumeDisappeared(name)
        }
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

    /// Paths can come from a drive's own manifest or database, so `.` and `..` components are dropped to keep the
    /// result inside the volume.
    public func url(forUsbPath path: String) -> URL {
        let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
        return url.appendingPathComponent(parts.joined(separator: "/"))
    }
}
