/// Computes the hash-based ANLZ directory players use to find analysis files.
///
/// Players derive this from the audio file's USB-relative path and ignore any
/// path stored in the database, so it must match exactly.
public enum AnlzPath {
    /// Returns e.g. "/PIONEER/USBANLZ/P00E/000281CE" for "/Contents/a/b.flac".
    public static func directory(forAudioPath path: String) -> String {
        let (p, hash) = components(forAudioPath: path)
        return "/PIONEER/USBANLZ/P\(hex(p, width: 3))/\(hex(hash, width: 8))"
    }

    static func components(forAudioPath path: String) -> (p: UInt32, hash: UInt32) {
        var h: UInt32 = 0
        for unit in path.utf16 {
            let c = UInt32(unit)
            let temp = h &* 0x5BC9 &+ c
            h = temp &* 0x93B5 &+ c
        }
        let r = h % 200_003

        var p: UInt32 = 0
        p |= (r >> 0) & 0x01
        p |= (r >> 1) & 0x02
        p |= (r >> 4) & 0x04
        p |= (r >> 4) & 0x08
        p |= (r >> 5) & 0x10
        p |= (r >> 8) & 0x20
        p |= (r >> 10) & 0x40
        return (p, r)
    }

    private static func hex(_ v: UInt32, width: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
