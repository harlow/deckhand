import AppKit
import SwiftUI

/// The Console window: timings, hangs, actions, sync/analysis output and errors.
struct ConsoleView: View {
    @State private var log = AppLog.shared
    @State private var level: AppLog.Level? = nil
    @State private var search = ""
    @State private var follow = true

    private var shown: [AppLog.Entry] {
        log.entries.filter { e in
            (level == nil || e.level == level)
                && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search) || e.category.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $level) {
                    Text("All").tag(AppLog.Level?.none)
                    ForEach(AppLog.Level.allCases, id: \.self) { l in Text(l.rawValue.capitalized).tag(AppLog.Level?.some(l)) }
                }
                .fixedSize()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                Text("\(shown.count) entries").font(.caption).foregroundStyle(.secondary)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(Log.format).joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { log.clear() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(shown) { e in
                    Text(Log.format(e))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(e.level))
                        .textSelection(.enabled)
                        .listRowSeparator(.hidden)
                        .id(e.id)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 16)
                .onChange(of: log.entries.last?.id) {
                    if follow, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }

    private func color(_ level: AppLog.Level) -> Color {
        switch level {
        case .info: .secondary
        case .perf: Color(red: 0.45, green: 0.7, blue: 1)
        case .warning: .pending
        case .error: .red
        }
    }
}
