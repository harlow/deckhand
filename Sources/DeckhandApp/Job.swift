import DeckhandAppCore
import Foundation
import Observation

/// A background run of the `deckhand` command-line tool (sync or analyze), with parsed progress.
/// Sync logic lives in the CLI and its libraries; the app only drives it and shows progress.
@MainActor @Observable
final class Job {
    enum State: Equatable { case idle, running, succeeded, failed(String), cancelled }

    private(set) var state: State = .idle
    private(set) var title = ""
    /// Current step, e.g. "Analysis files" or "Writing library database".
    private(set) var phase = ""
    private(set) var done = 0
    /// Nil while the current step has no count (the bar is indeterminate).
    private(set) var total: Int?
    private(set) var detail = ""
    private(set) var log = ""
    private(set) var startedAt = Date()
    private(set) var finishedAt = Date()
    /// A sync's `@result` line: what it did and whether it left the drive up to date.
    private(set) var report: SyncReport?
    /// Set when a sync stopped before writing because Music couldn't be read live (`@live`).
    private(set) var liveWarning: LiveWarning?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pending = Data()

    var running: Bool { state == .running }

    /// The `deckhand` binary next to this app's executable (both are built into the same directory).
    static var cli: URL? {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
        return dir.map { $0.appendingPathComponent("deckhand") }.flatMap {
            FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
        }
    }

    func run(_ title: String, _ args: [String], completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard !running else { return }
        self.title = title
        phase = "Starting…"
        done = 0
        total = nil
        detail = ""
        report = nil
        liveWarning = nil
        log = "$ deckhand \(args.joined(separator: " "))\n"
        pending = Data()
        startedAt = Date()
        guard let cli = Self.cli else {
            state = .failed("Couldn't find the deckhand command next to the app. Build it with Scripts/build-app.sh.")
            completion(false)
            return
        }
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DECKHAND_PROGRESS"] = "1"
        env["DECKHAND_TIMING"] = "1"   // per-step timings ("[timing] …") land in the Console
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Output and the exit are delivered in order on the main queue, and the job finishes only once the output has
        // ended (or shortly after the exit), so the last lines — a sync's `@result` — are always read first.
        let run = UUID()
        currentRun = run
        outputEnded = false
        exitStatus = nil
        self.completion = completion
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentRun == run else { return }
                    if data.isEmpty {
                        self.outputEnded = true
                        self.finishIfDone()
                    } else {
                        self.consume(data)
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentRun == run else { return }
                    self.exitStatus = status
                    self.finishIfDone()
                }
            }
            // A child process still holding the output open mustn't keep the job running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let self, self.currentRun == run else { return }
                    self.outputEnded = true
                    self.finishIfDone()
                }
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            Log.info("job", "Started: deckhand \(args.joined(separator: " "))")
        } catch {
            state = .failed(error.localizedDescription)
            self.completion = nil
            currentRun = UUID()
            completion(false)
        }
    }

    @ObservationIgnored private var currentRun = UUID()
    @ObservationIgnored private var outputEnded = false
    @ObservationIgnored private var exitStatus: Int32?
    @ObservationIgnored private var completion: (@MainActor (Bool) -> Void)?

    private func finishIfDone() {
        guard outputEnded, let status = exitStatus, let completion else { return }
        self.completion = nil
        currentRun = UUID()
        consume(Data("\n".utf8))
        finishedAt = Date()
        let ok = status == 0
        Log.post(ok ? .info : .error, "job", "\(title) \(ok ? "finished" : "exited with status \(status)") after \(Int(finishedAt.timeIntervalSince(startedAt))) s")
        if state == .running {
            state = ok ? .succeeded : .failed(lastMessage ?? "exited with status \(status)")
        }
        process = nil
        completion(ok)
    }

    func cancel() {
        guard running else { return }
        state = .cancelled
        process?.interrupt()
    }

    func dismiss() {
        if !running { state = .idle }
    }

    /// The last meaningful line of output, used as the failure reason.
    private var lastMessage: String? {
        log.split(separator: "\n").last { !$0.hasPrefix("$ ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits output into lines. Bytes, not text: a read can end inside a multi-byte character.
    private func consume(_ data: Data) {
        pending.append(data)
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        if line.hasPrefix("@progress\t") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return }
            phase = f[1]
            done = Int(f[2]) ?? 0
            total = Int(f[3])
            detail = f.count > 4 ? f[4] : ""
            return
        }
        switch JobLine.parse(line) {
        case .result(let r)?:
            report = r
            Log.info("sync", "Result: generation \(r.generation), \(r.clean ? "clean" : "\(r.pending) still pending")")
            return
        case .live(let w)?:
            liveWarning = w
            return
        case nil: break
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        log += line + "\n"
        Log.info(title.lowercased().hasPrefix("sync") ? "sync" : "analyze", trimmed)
        // Indented status lines ("  writing library database") are steps without a count.
        if line.hasPrefix("  "), !trimmed.hasPrefix("!"), trimmed.first?.isLowercase == true {
            phase = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            total = nil
            detail = ""
        }
    }
}
