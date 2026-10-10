import Foundation

public enum SyncError: Error, CustomStringConvertible {
    case notAVolumeRoot(String)
    case unsafeVolume(String, String)
    case notInitialized(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case playlistNotFound(String)
    case volumeDisappeared(String)
    case copyFailed(String, Error)
    /// The drive's manifest isn't the one a change was based on (another save landed in between).
    case manifestConflict(String)
    /// The manifest was written by a newer Deckhand.
    case newerManifest(Int)
    /// Another sync holds the drive's lock.
    case driveBusy(String, SyncLock.Info)
    /// A plan with unknown facts (e.g. audio not hashed yet) can't be carried out.
    case incompletePlan(Int)

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
        case .manifestConflict(let n):
            return "\"\(n)\" was changed by another sync while this one ran. Nothing was lost; sync again."
        case .newerManifest(let f):
            return "This drive was set up by a newer version of Deckhand (manifest format \(f)). Update Deckhand to sync it."
        case .driveBusy(let n, let held):
            return "\"\(n)\" is being synced by another Deckhand process (pid \(held.pid), since \(held.startedAt.formatted())). Try again when it finishes."
        case .incompletePlan(let n):
            return "\(n) track(s) haven't been checked yet; can't sync until they are."
        }
    }
}
