import Foundation

public enum SyncError: Error, CustomStringConvertible {
    case notAVolumeRoot(String)
    case unsafeVolume(String, String)
    case notInitialized(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case playlistNotFound(String)
    case volumeDisappeared(String)
    case copyFailed(String, Error)

    public var description: String {
        switch self {
        case .notAVolumeRoot(let p):
            return "\(p) is not the root of a mounted volume. Pass the drive itself, e.g. /Volumes/DJUSB."
        case .unsafeVolume(let n, let why):
            return "Refusing to write to \"\(n)\": \(why)."
        case .notInitialized(let n):
            return "\"\(n)\" is not a Deckhand drive yet. Run `deckhand init /Volumes/\(n)` first."
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough free space: need \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) available."
        case .playlistNotFound(let n):
            return "No Apple Music playlist named \"\(n)\". Run `deckhand playlists` to see available names."
        case .volumeDisappeared(let n):
            return "The drive \"\(n)\" was disconnected during sync. The previous library on it is still intact; reconnect and sync again."
        case .copyFailed(let p, let e):
            return "Could not copy \(p): \(e.localizedDescription)"
        }
    }
}
