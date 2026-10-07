import Foundation

/// Single-line terminal progress bar. Redraws in place on a TTY (throttled); elsewhere prints
/// a plain line every 10%. Thread-safe.
final class ProgressBar: @unchecked Sendable {
    private let label: String
    private let total: Int
    private let isTTY = isatty(STDOUT_FILENO) != 0
    private let start = Date()
    private let lock = NSLock()
    private var done = 0
    private var lastDraw = Date.distantPast
    private var lastPlainDecile = -1
    private var finished = false

    init(_ label: String, total: Int) {
        self.label = label
        self.total = max(total, 1)
    }

    /// Records one completed item; `detail` (e.g. the track title) is shown at the end of the line.
    func advance(_ detail: String = "") {
        lock.withLock {
            done += 1
            draw(detail, force: done == total)
        }
    }

    /// Ends the bar line, leaving the final state visible.
    func finish(_ summary: String? = nil) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            done = min(done, total)
            if isTTY {
                draw(summary ?? "", force: true)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else if let summary {
                print("\(label.trimmingCharacters(in: .whitespaces)): \(summary)")
            }
        }
    }

    private func draw(_ detail: String, force: Bool) {
        let elapsed = Date().timeIntervalSince(start)
        let rate = elapsed > 0 ? Double(done) / elapsed : 0
        let percent = Int(Double(done) / Double(total) * 100)

        guard isTTY else {
            let decile = percent / 10
            if decile > lastPlainDecile {
                lastPlainDecile = decile
                print("\(label.trimmingCharacters(in: .whitespaces)): \(done)/\(total) (\(percent)%)")
            }
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastDraw) >= 0.1 else { return }
        lastDraw = now

        let width = 24
        let filled = min(width, Int(Double(done) / Double(total) * Double(width)))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let eta = rate > 0 ? Self.clock(Double(total - done) / rate) : "--:--"
        let counts = "\(Self.grouped(done))/\(Self.grouped(total))"
        var line = "\(label)  [\(bar)]  \(counts)  \(percent)%  \(String(format: "%.1f", rate))/s  ETA \(eta)"
        if !detail.isEmpty { line += "  \(detail)" }
        let columns = Self.terminalColumns()
        if line.count > columns { line = String(line.prefix(max(0, columns - 1))) + "…" }
        FileHandle.standardOutput.write(Data(("\r\u{1B}[2K" + line).utf8))
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func terminalColumns() -> Int {
        var w = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 ? Int(w.ws_col) : 120
    }
}
