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

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pending = ""

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
        log = "$ deckhand \(args.joined(separator: " "))\n"
        pending = ""
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
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.consume("\n")
                self.finishedAt = Date()
                let ok = proc.terminationStatus == 0
                Log.post(ok ? .info : .error, "job", "\(self.title) \(ok ? "finished" : "exited with status \(proc.terminationStatus)") after \(Int(self.finishedAt.timeIntervalSince(self.startedAt))) s")
                if self.state == .running {
                    self.state = ok ? .succeeded : .failed(self.lastMessage ?? "exited with status \(proc.terminationStatus)")
                }
                self.process = nil
                completion(ok)
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            Log.info("job", "Started: deckhand \(args.joined(separator: " "))")
        } catch {
            state = .failed(error.localizedDescription)
            completion(false)
        }
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

    private func consume(_ text: String) {
        pending += text
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
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
