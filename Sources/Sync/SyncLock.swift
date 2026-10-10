import Foundation

/// `/.deckhand/sync.lock`, held by a sync while it writes to the drive so two syncs never overlap and the app
/// doesn't edit the selection mid-sync. Stale once its process is gone, it's from another Mac (a drive is only
/// ever mounted on one), or it's more than 6 hours old.
public struct SyncLock: Sendable {
    public struct Info: Codable, Sendable, Equatable {
        public var pid: Int32
        public var host: String
        public var startedAt: Date
        var token: String
    }

    public static let staleAfter: TimeInterval = 6 * 3600
    let url: URL
    public let info: Info

    static func url(root: URL) -> URL {
        root.appendingPathComponent(Manifest.directory).appendingPathComponent("sync.lock")
    }

    /// Creates the lock file (exclusively), replacing a stale one. Throws `SyncError.driveBusy` if it's held.
    public static func acquire(on volume: Volume) throws -> SyncLock {
        let url = url(root: volume.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = Info(pid: getpid(), host: hostName, startedAt: Date(), token: UUID().uuidString)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)
        for attempt in 0..<2 {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                defer { FileOps.removeAppleDouble(of: url) }
                do {
                    try FileOps.writeAll(data, to: fd, path: url.path)
                    guard close(fd) == 0 else { throw FileOps.posixError(url.path) }
                } catch {
                    unlink(url.path)
                    throw error
                }
                // A stale lock replaced by two processes at once could let both in; only one token survives.
                guard read(url)?.token == info.token else { break }
                return SyncLock(url: url, info: info)
            }
            guard errno == EEXIST else { throw FileOps.posixError(url.path) }
            if let held = holder(url) { throw SyncError.driveBusy(volume.name, held) }
            if attempt == 0 { unlink(url.path) }
        }
        throw SyncError.driveBusy(volume.name, read(url) ?? info)
    }

    public func release() {
        if Self.read(url)?.token == info.token { unlink(url.path) }
        FileOps.removeAppleDouble(of: url)
    }

    /// Who holds the drive's lock, if it's held and not stale.
    public static func current(on volume: Volume) -> Info? { holder(url(root: volume.url)) }

    private static func holder(_ url: URL) -> Info? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let info = read(url) else {
            // Unreadable: perhaps being written this instant. Treat a fresh one as held.
            let age = Date().timeIntervalSince(FileOps.modificationDate(url) ?? .distantPast)
            return age < 60 ? Info(pid: 0, host: "", startedAt: Date(), token: "") : nil
        }
        return isLive(info) ? info : nil
    }

    static func isLive(_ info: Info, now: Date = Date()) -> Bool {
        guard info.host == hostName, now.timeIntervalSince(info.startedAt) < staleAfter else { return false }
        guard let started = processStart(info.pid) else { return false }
        // A process that started after the lock was taken reuses a dead holder's pid.
        return started <= info.startedAt.addingTimeInterval(1)
    }

    private static func read(_ url: URL) -> Info? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Info.self, from: $0) }
    }

    /// Start time of a running process, or nil if there's none with that pid.
    private static func processStart(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    static let hostName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
