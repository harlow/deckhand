import SwiftUI

/// Detailed progress/log for a job: library jobs in the queue pane, USB jobs in the drive popover.
struct JobCard: View {
    @Environment(LibraryModel.self) private var library
    var onDismiss: () -> Void = {}
    @State private var showLog = false

    var body: some View {
        let job = library.job
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon(job.state)
                Text(job.title).fontWeight(.semibold).lineLimit(1)
                Spacer()
                if job.running {
                    Button("Cancel") { job.cancel() }.buttonStyle(.borderless)
                } else {
                    Button { job.dismiss(); onDismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
            switch job.state {
            case .running:
                if let total = job.total, total > 0 {
                    ProgressView(value: Double(min(job.done, total)), total: Double(total))
                    HStack {
                        Text(job.phase)
                        Spacer()
                        Text("\(job.done.formatted()) of \(total.formatted())").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !job.detail.isEmpty {
                        Text(job.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(job.phase).font(.caption).foregroundStyle(.secondary)
                }
            case .succeeded:
                Text("Finished in \(elapsed(job.startedAt, job.finishedAt)).").font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(Color.pending).lineLimit(3)
            case .cancelled:
                Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
            DisclosureGroup("Details", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(job.log)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 160)
                    .onChange(of: job.log) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
    }

    @ViewBuilder private func icon(_ state: Job.State) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.synced)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.pending)
        case .cancelled, .idle: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func elapsed(_ start: Date, _ end: Date) -> String {
        let s = Int(end.timeIntervalSince(start))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}
