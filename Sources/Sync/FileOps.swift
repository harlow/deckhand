import Foundation

enum FileOps {
    // No per-file fsync: cheap flash sticks take ~1s per flush. Durability comes from one
    // filesystem-wide sync before the database swap, which is the commit point.

    /// Copies file bytes only (no xattrs/resource forks, which create `._` files on FAT drives),
    /// writing to a temporary name and renaming into place.
    static func copyData(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".deckhand-tmp-\(dst.lastPathComponent)")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: tmp)
        do {
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
    }

    /// Writes data to a temporary sibling and renames it over `url`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".deckhand-tmp-\(url.lastPathComponent)")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Deletes macOS AppleDouble (`._*`) files that FAT drives accumulate when files carry xattrs
    /// (e.g. com.apple.provenance). Players can show them as junk entries.
    /// Uses readdir directly: FileManager hides these files.
    static func removeAppleDoubleFiles(volumeRoot: URL, managedPaths: [String]) {
        for path in managedPaths {
            let dir = volumeRoot.appendingPathComponent(path)
            unlink(dir.deletingLastPathComponent().appendingPathComponent("._" + dir.lastPathComponent).path)
            removeAppleDouble(inTree: dir.path)
        }
    }

    private static func removeAppleDouble(inTree dir: String) {
        guard let d = opendir(dir) else { return }
        defer { closedir(d) }
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let full = dir + "/" + name
            if name.hasPrefix("._") {
                unlink(full)
            } else if entry.pointee.d_type == DT_DIR {
                removeAppleDouble(inTree: full)
            }
        }
    }

    /// Flushes all pending writes to disk.
    static func syncFilesystem() {
        sync()
    }
}
