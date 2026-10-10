import Foundation

public enum AppleMusicWriterError: Error, CustomStringConvertible {
    case script(String)

    public var description: String {
        switch self {
        case .script(let m):
            return "Music.app scripting failed: \(m)\n"
                + "If macOS asked whether this terminal may control Music, allow it "
                + "(System Settings → Privacy & Security → Automation)."
        }
    }
}

/// Creates playlists in Music.app via AppleScript. iTunesLibrary.framework is read-only, so this
/// is the supported way to write.
public enum AppleMusicWriter {
    /// Creates a playlist (or folder) and returns its persistent ID.
    public static func createPlaylist(named name: String, isFolder: Bool, inFolder parentId: String?) throws -> String {
        let kind = isFolder ? "folder playlist" : "user playlist"
        let location = parentId.map { " at (first folder playlist whose persistent ID is \(quote($0)))" } ?? ""
        return try run("""
            tell application "Music"
                set p to make new \(kind)\(location) with properties {name:\(quote(name))}
                return persistent ID of p
            end tell
            """)
    }

    /// Appends tracks in order. Returns the IDs that couldn't be found in the library.
    @discardableResult
    public static func add(trackIds: [String], toPlaylist playlistId: String) throws -> [String] {
        var missing: [String] = []
        // Batches keep each script reasonably small; order is preserved.
        for batch in stride(from: 0, to: trackIds.count, by: 200).map({ Array(trackIds[$0..<min($0 + 200, trackIds.count)]) }) {
            let list = batch.map(quote).joined(separator: ", ")
            let result = try run("""
                tell application "Music"
                    set p to first user playlist whose persistent ID is \(quote(playlistId))
                    set missing to {}
                    repeat with tid in {\(list)}
                        try
                            duplicate (first track of library playlist 1 whose persistent ID is (contents of tid)) to p
                        on error
                            set end of missing to (contents of tid)
                        end try
                    end repeat
                    set AppleScript's text item delimiters to ","
                    return missing as text
                end tell
                """)
            missing += result.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        return missing
    }

    /// Removes tracks from a user playlist. They stay in the library (deleting from a user playlist
    /// never deletes the song).
    public static func remove(trackIds: [String], fromPlaylist playlistId: String) throws {
        for batch in stride(from: 0, to: trackIds.count, by: 200).map({ Array(trackIds[$0..<min($0 + 200, trackIds.count)]) }) {
            _ = try run("""
                tell application "Music"
                    set p to first user playlist whose persistent ID is \(quote(playlistId))
                    if smart of p then error "Smart playlists are edited by their rules in Music."
                    repeat with tid in {\(batch.map(quote).joined(separator: ", "))}
                        delete (every track of p whose persistent ID is (contents of tid))
                    end repeat
                end tell
                """)
        }
    }

    /// Sets the star rating (0–5; 0 clears it) of library tracks.
    public static func setRating(_ stars: Int, trackIds: [String]) throws {
        let value = max(0, min(5, stars)) * 20
        for batch in stride(from: 0, to: trackIds.count, by: 200).map({ Array(trackIds[$0..<min($0 + 200, trackIds.count)]) }) {
            _ = try run("""
                tell application "Music"
                    repeat with tid in {\(batch.map(quote).joined(separator: ", "))}
                        try
                            set rating of (first track of library playlist 1 whose persistent ID is (contents of tid)) to \(value)
                        end try
                    end repeat
                end tell
                """)
        }
    }

    /// Adds an audio file to the library and returns the new track's persistent ID and file location
    /// (Music may copy the file into its media folder, depending on the user's settings).
    /// Non-nil metadata values overwrite what Music read from the file's tags.
    public static func addFile(_ url: URL, title: String?, artist: String?, album: String?, genre: String?) throws
        -> (id: String, location: String) {
        var sets: [String] = []
        if let title, !title.isEmpty { sets.append("set name of t to \(quote(title))") }
        if let artist, !artist.isEmpty { sets.append("set artist of t to \(quote(artist))") }
        if let album, !album.isEmpty { sets.append("set album of t to \(quote(album))") }
        if let genre, !genre.isEmpty { sets.append("set genre of t to \(quote(genre))") }
        // Music returns the existing track for audio it already has; only retitle tracks it just created.
        let script = """
            tell application "Music"
                set t to add (POSIX file \(quote(url.path)))
                if (date added of t) > ((current date) - 300) then
                    \(sets.joined(separator: "\n            "))
                end if
                return (persistent ID of t) & linefeed & (POSIX path of (location of t as alias))
            end tell
            """
        let result: String
        do {
            result = try run(script)
        } catch {
            // The first request after Music launches (or while it shows a prompt) can fail; retry once.
            Thread.sleep(forTimeInterval: 2)
            result = try run(script)
        }
        let parts = result.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw AppleMusicWriterError.script("unexpected result adding \(url.lastPathComponent)") }
        return (parts[0], parts[1])
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw AppleMusicWriterError.script("could not compile script") }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw AppleMusicWriterError.script(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        return result.stringValue ?? ""
    }
}
