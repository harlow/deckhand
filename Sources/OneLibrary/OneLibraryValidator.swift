import Foundation

/// Structural checks on an exportLibrary.db and the files it references.
public enum OneLibraryValidator {
    /// Returns a list of human-readable problems; empty means valid. The default inspects every analysis file.
    /// A sync can restrict inspection to changed directories when its manifest vouches for the rest. Database
    /// references and the existence of every audio, analysis and artwork file are always checked.
    public static func validate(database: URL, volumeRoot: URL,
                                analysisDirectoriesToInspect: Set<String>? = nil) throws -> [String] {
        var issues: [String] = []
        let db = try OneLibraryDatabase.open(database)

        func url(_ usbPath: String) -> URL {
            volumeRoot.appendingPathComponent(String(usbPath.drop(while: { $0 == "/" })))
        }

        let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.string })
        for required in ["content", "playlist", "playlist_content", "property", "color", "key", "artist", "album", "genre"]
        where !tables.contains(required) {
            issues.append("Missing table \(required)")
        }
        if !issues.isEmpty { return issues }

        var contentIds = Set<Int64>()
        for row in try db.query("SELECT content_id, title, path, analysisDataFilePath FROM content") {
            guard let id = row["content_id"]?.int, let path = row["path"]?.string else {
                issues.append("Content row without id/path")
                continue
            }
            contentIds.insert(id)
            let title = row["title"]?.string ?? "?"
            if !FileManager.default.fileExists(atPath: url(path).path) {
                issues.append("Audio file missing for \"\(title)\": \(path)")
            }
            guard let anlz = row["analysisDataFilePath"]?.string, !anlz.isEmpty else { continue }
            let expectedDir = AnlzPath.directory(forAudioPath: path)
            if !anlz.hasPrefix(expectedDir + "/") {
                issues.append("Analysis path for \"\(title)\" is \(anlz), expected under \(expectedDir)")
            }
            for ext in ["DAT", "EXT", "2EX"] {
                let file = url(expectedDir + "/ANLZ0000." + ext)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    issues.append("Missing \(ext) analysis file for \"\(title)\"")
                    continue
                }
                if let directories = analysisDirectoriesToInspect, !directories.contains(expectedDir) { continue }
                do {
                    if let problem = try checkAnlz(file, expectedPath: path) {
                        issues.append("Bad \(ext) analysis file for \"\(title)\": \(problem)")
                    }
                } catch {
                    issues.append("Missing \(ext) analysis file for \"\(title)\"")
                }
            }
        }

        var playlistIds = Set<Int64>()
        var parents: [(Int64, Int64)] = []
        for row in try db.query("SELECT playlist_id, playlist_id_parent FROM playlist") {
            guard let id = row["playlist_id"]?.int else { continue }
            playlistIds.insert(id)
            if let parent = row["playlist_id_parent"]?.int, parent != 0 { parents.append((id, parent)) }
        }
        for (id, parent) in parents where !playlistIds.contains(parent) {
            issues.append("Playlist \(id) has missing parent \(parent)")
        }
        for row in try db.query("SELECT playlist_id, content_id FROM playlist_content") {
            if let c = row["content_id"]?.int, !contentIds.contains(c) {
                issues.append("Playlist \(row["playlist_id"]?.int ?? 0) references missing content \(c)")
            }
            if let p = row["playlist_id"]?.int, !playlistIds.contains(p) {
                issues.append("playlist_content references missing playlist \(p)")
            }
        }
        for row in try db.query("SELECT path FROM image") {
            if let path = row["path"]?.string, !FileManager.default.fileExists(atPath: url(path).path) {
                issues.append("Artwork file missing: \(path)")
            }
        }
        if try db.query("SELECT * FROM property").count != 1 {
            issues.append("property table must have exactly one row")
        }
        return issues
    }

    /// Checks section framing and that the embedded path matches the audio path.
    static func checkAnlz(_ data: Data, expectedPath: String) -> String? {
        checkAnlz(length: data.count, expectedPath: expectedPath) { offset, count in
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
                throw BinaryError.truncated
            }
            return data.subdata(in: offset..<(offset + count))
        }
    }

    /// Validation needs section headers and the embedded audio path, not waveform payloads.
    /// Seek past those payloads: reading every waveform adds gigabytes of USB I/O to a rating edit.
    static func checkAnlz(_ file: URL, expectedPath: String) throws -> String? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length <= UInt64(Int.max) else { return "file too large" }
        return checkAnlz(length: Int(length), expectedPath: expectedPath) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw BinaryError.truncated
            }
            return data
        }
    }

    /// Shared parser keeps in-memory tests and USB validation subject to the same checks.
    static func checkAnlz(length: Int, expectedPath: String,
                          read: (Int, Int) throws -> Data) -> String? {
        do {
            var r = BinaryReader(try read(0, 12))
            guard try r.ascii(4) == "PMAI" else { return "missing PMAI header" }
            let headerLength = Int(try r.u32())
            let fileLength = Int(try r.u32())
            guard fileLength == length else { return "length field \(fileLength) != file size \(length)" }
            guard headerLength >= 12, headerLength <= length else { return "bad header length" }
            var offset = headerLength
            var sawPath = false
            while offset < length {
                var r = BinaryReader(try read(offset, 12))
                let tag = try r.ascii(4)
                _ = try r.u32()
                let sectionLength = Int(try r.u32())
                guard sectionLength >= 12, sectionLength <= length - offset else { return "bad length for section \(tag)" }
                if tag == "PPTH" {
                    guard sectionLength >= 16 else { return "bad PPTH length" }
                    var size = BinaryReader(try read(offset + 12, 4))
                    let byteLength = Int(try size.u32())
                    guard byteLength >= 2, byteLength.isMultiple(of: 2), byteLength <= sectionLength - 16 else {
                        return "bad PPTH length"
                    }
                    var pathReader = BinaryReader(try read(offset + 16, byteLength))
                    var units: [UInt16] = []
                    for _ in 0..<(byteLength / 2) { units.append(try pathReader.u16()) }
                    guard units.last == 0 else { return "PPTH path not null-terminated" }
                    let path = String(decoding: units.dropLast(), as: UTF16.self)
                    guard path == expectedPath else { return "PPTH path \(path) != \(expectedPath)" }
                    sawPath = true
                }
                offset += sectionLength
            }
            return sawPath ? nil : "missing PPTH section"
        } catch {
            return "truncated"
        }
    }
}

extension SQLiteDatabase.Value {
    var int: Int64? { if case .int(let v) = self { v } else { nil } }
    var string: String? { if case .text(let v) = self { v } else { nil } }
}
