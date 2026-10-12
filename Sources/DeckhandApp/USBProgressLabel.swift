import SwiftUI

/// The phase counter is local to a step; final disk writes and verification have no item count.
struct USBProgressState: Equatable {
    var phase: String
    var done: Int
    var total: Int?

    var title: String {
        switch phase {
        case "Copying": "Copying tracks"
        case "Analyzing": "Analyzing tracks"
        case "Analysis files": "Saving analysis"
        case "Writing library database": "Saving library"
        case "Committing": "Finishing USB"
        case "Checking USB": "Checking USB"
        case "", "Starting…": "Preparing sync"
        default: phase.hasPrefix("Removing ") ? "Removing old files" : phase
        }
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(min(max(done, 0), total)) / Double(total)
    }

    var count: String? {
        guard let total, total > 0 else { return nil }
        return "\(min(max(done, 0), total).formatted()) of \(total.formatted())"
    }
}

/// Progress stands beside the drive control, leaving that control's identity and size stable.
struct USBProgressLabel: View {
    var driveName: String
    var phase: String
    var done: Int
    var total: Int?
    var detail: String

    private var progress: USBProgressState { .init(phase: phase, done: done, total: total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(progress.title).lineLimit(1)
                Spacer(minLength: 0)
                if let count = progress.count {
                    Text(count).monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.callout)
            if let fraction = progress.fraction {
                GeometryReader { geometry in
                    Capsule().fill(Color.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .frame(width: geometry.size.width * fraction)
                        }
                }.frame(height: 6)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                    .frame(height: 6)
            }
        }
        .frame(width: 200, height: 28)
        .help([progress.title, progress.count, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Syncing \(driveName)")
        .accessibilityValue([progress.title, progress.count, detail].compactMap { $0 }.joined(separator: ", "))
    }
}
