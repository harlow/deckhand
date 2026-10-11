import Foundation

enum FileOps {
    // No per-file fsync: cheap flash sticks take ~1s per flush. Durability comes from one
    // filesystem-wide sync before the database swap, which is the commit point.

    /// Copies file bytes only (no xattrs/resource forks, which create `._` files on FAT drives),
    /// writing to a temporary name and renaming into place: a file at its final path counts as copied.
    /// Returns the number of bytes copied.
    @discardableResult
    static func copyData(from src: URL, to dst: URL) throws -> Int64 {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".deckhand-tmp-\(dst.lastPathComponent)")
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        var copied: Int64 = 0
        try withOutput(tmp) { fd in
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try writeAll(chunk, to: fd, path: tmp.path)
                copied += Int64(chunk.count)
            }
        }
        try rename(tmp, to: dst)
        return copied
    }

    /// Writes data to a temporary sibling and renames it over `url`. For files whose partial state would be
    /// mistaken for a complete one (the manifest); analysis files and artwork use `write`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".deckhand-tmp-\(url.lastPathComponent)")
        try withOutput(tmp) { try writeAll(data, to: $0, path: tmp.path) }
        try rename(tmp, to: url)
    }

    /// Writes data in place. Renames cost ~0.1–0.5 s each on FAT sticks, so files that are only trusted once the
    /// manifest records them (ANLZ, artwork) skip the temporary file.
    static func write(_ data: Data, to url: URL) throws {
        try withOutput(url) { try writeAll(data, to: $0, path: url.path) }
    }

    /// Opens with POSIX calls: FileManager.createFile does its own temp-file-and-rename and adds xattrs.
    private static func withOutput(_ url: URL, _ body: (Int32) throws -> Void) throws {
        let dir = url.deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Deckhand creates at most two levels at once (USBANLZ/Pxxx/xxxxxxxx, Contents/Deckhand/xx).
            let created = url.deletingLastPathComponent()
            removeAppleDouble(of: created)
            removeAppleDouble(of: created.deletingLastPathComponent())
        }
        // Overwrite, then trim to the new length: O_TRUNC frees and reallocates clusters, which costs up to
        // ~0.3 s per file on FAT sticks; rewriting a same-sized file this way takes milliseconds.
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw posixError(url.path) }
        do {
            try body(fd)
            guard ftruncate(fd, lseek(fd, 0, SEEK_CUR)) == 0 else { throw posixError(url.path) }
        } catch {
            close(fd)
            unlink(url.path)
            throw error
        }
        guard close(fd) == 0 else { throw posixError(url.path) }
        removeAppleDouble(of: url)
    }

    /// macOS tags every file this process creates with com.apple.provenance, which FAT stores in a `._` sidecar
    /// that players can list as junk. It can't be prevented, so it's deleted right after each write.
    static func removeAppleDouble(of url: URL) {
        unlink(url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent).path)
    }

    static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw posixError(path) }
                offset += n
            }
        }
    }

    private static func rename(_ from: URL, to: URL) throws {
        // POSIX rename replaces an existing file in one step (FileManager.moveItem refuses to).
        guard Foundation.rename(from.path, to.path) == 0 else {
            let error = posixError(to.path)
            unlink(from.path)
            throw error
        }
        removeAppleDouble(of: to)
    }

    static func posixError(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    /// Size and modification time from one stat, as `size` and `modificationDate` report them; nil if missing.
    static func attributes(_ url: URL) -> (size: Int64, modified: Double)? {
        // Foundation also reads extended attributes here. On protected music folders that can
        // wait on a privacy prompt, even though we only need stat's size and modification time.
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { fstatat(AT_FDCWD, $0, &info, 0) == 0 } ?? false
        }) else { return nil }
        #if os(macOS)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        // Match Foundation Date's reference-date arithmetic exactly: rounding directly in the
        // Unix epoch changes some values by a fraction of a microsecond and misses old cache keys.
        let modified = Date(timeIntervalSinceReferenceDate:
            Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate + Double(time.tv_nsec) / 1_000_000_000)
        return (Int64(info.st_size), modified.timeIntervalSince1970)
    }

    static func size(_ url: URL) -> Int64 {
        attributes(url)?.size ?? 0
    }

    static func modificationDate(_ url: URL) -> Date? {
        attributes(url).map { Date(timeIntervalSince1970: $0.modified) }
    }

    /// Deletes macOS AppleDouble (`._*`) files in one directory (not recursive). FAT drives get them when files
    /// carry xattrs (e.g. com.apple.provenance), and players can show them as junk entries. Uses readdir
    /// directly: FileManager hides these files. `deckhand cleanup` sweeps whole drives.
    static func removeAppleDoubleFiles(in dir: URL) {
        guard let d = opendir(dir.path) else { return }
        defer { closedir(d) }
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name.hasPrefix("._") { unlink(dir.appendingPathComponent(name).path) }
        }
    }

    /// Flushes all pending writes to disk.
    static func syncFilesystem() {
        sync()
    }
}
