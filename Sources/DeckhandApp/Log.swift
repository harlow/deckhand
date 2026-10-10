import Foundation
import Observation
import os

/// In-app log shown in the Console window (View → Show Console), mirrored to the system log
/// (subsystem rocks.deckhand.app) so Console.app sees it too.
@MainActor @Observable
final class AppLog {
    static let shared = AppLog()

    enum Level: String, CaseIterable { case info, perf, warning, error }

    struct Entry: Identifiable {
        let id: Int
        let date: Date
        let level: Level
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var nextId = 0
    private static let limit = 3000

    fileprivate func add(_ level: Level, _ category: String, _ message: String, at date: Date) {
        entries.append(Entry(id: nextId, date: date, level: level, category: category, message: message))
        nextId += 1
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }

    var text: String {
        entries.map(Log.format).joined(separator: "\n")
    }
}

/// Logging entry points, callable from any thread.
enum Log {
    private static let system = Logger(subsystem: "rocks.deckhand.app", category: "app")

    static func info(_ category: String, _ message: String) { post(.info, category, message) }
    static func warning(_ category: String, _ message: String) { post(.warning, category, message) }
    static func error(_ category: String, _ message: String) { post(.error, category, message) }

    static func post(_ level: AppLog.Level, _ category: String, _ message: String) {
        let date = Date()
        switch level {
        case .error: system.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: system.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        default: system.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        Task { @MainActor in AppLog.shared.add(level, category, message, at: date) }
    }

    /// Runs `body` and logs how long it took when that's over `threshold` seconds.
    @discardableResult
    static func measure<T>(_ category: String, _ label: @autoclosure () -> String, threshold: Double = 0.03,
                           _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        let result = try body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        if seconds >= threshold { post(.perf, category, "\(label()) took \(Int(seconds * 1000)) ms") }
        return result
    }

    nonisolated static func format(_ e: AppLog.Entry) -> String {
        "\(time.string(from: e.date))  \(e.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(e.category.padding(toLength: 9, withPad: " ", startingAt: 0)) \(e.message)"
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Logs whenever the main thread stops responding for more than a quarter second (a spinning cursor).
final class HangDetector: @unchecked Sendable {
    static let shared = HangDetector()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let thread = Thread {
            while true {
                let sent = DispatchTime.now()
                let pong = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { pong.signal() }
                if pong.wait(timeout: .now() + 0.25) == .timedOut {
                    pong.wait()
                    let ms = (DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
                    Log.warning("hang", "App was unresponsive for \(ms) ms")
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "HangDetector"
        thread.qualityOfService = .utility
        thread.start()
    }
}
