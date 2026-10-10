import Foundation

/// Finds audio already on a drive (e.g. from a Rekordbox export) that Deckhand can take over
/// instead of copying again.
public enum AdoptScanner {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "flac"]

    /// Audio files under /Contents that Deckhand doesn't own, keyed by audio hash → USB-relative path.
    public static func scan(_ volume: Volume, owned: Set<String>, cache: AnalysisCache,
                            progress: (Int, Int, String) -> Void = { _, _, _ in }) -> [String: String] {
        let root = volume.url(forUsbPath: "/Contents")
        // Compare resolved paths: enumerated URLs may come back with symlinks resolved (e.g. /private/var).
        let volumePath = volume.url.resolvingSymlinksInPath().path
        var files: [String] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e {
                let name = url.lastPathComponent
                guard !name.hasPrefix("._"), audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(volumePath) else { continue }
                let usbPath = "/" + full.dropFirst(volumePath.count).drop(while: { $0 == "/" })
                if usbPath.hasPrefix("/Contents/Deckhand/") || owned.contains(usbPath) { continue }
                files.append(usbPath)
            }
        }
        var index: [String: String] = [:]
        for (i, path) in files.sorted().enumerated() {
            progress(i + 1, files.count, (path as NSString).lastPathComponent)
            if let h = try? cache.contentHash(of: volume.url(forUsbPath: path)), index[h] == nil { index[h] = path }
        }
        try? cache.save()
        return index
    }
}
