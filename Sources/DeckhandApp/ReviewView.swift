import AppKit
import SwiftUI

/// Quick Rate's main column: the current track large, its waveform from the preview point, and
/// the rating keys. Replaces the track list while a review is running.
struct ReviewView: View {
    var review: Review
    var library: LibraryModel
    var player: Player
    /// Catches Quick Rate's keys at the window level, so they work wherever focus is.
    @State private var monitor: Any?
    /// The track waiting in the ⇧P "Add to playlist" picker.
    @State private var picking: String?

    var body: some View {
        ScrollView { content }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handle(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
            .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
                if let id = picking { PlaylistPicker(library: library, ids: [id]) { picking = nil } }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let row = review.current {
                track(row)
                PlayerWaveform(player: player, waveHeight: 90, phraseHeight: 16)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text("\(formatTime(player.time)) / \(formatTime(player.duration))").monospacedDigit()
                    Spacer()
                    Text("1–8  hot cues   ·   , .  4 beats   ·   [ ]  sections   ·   Space  pause   ·   l  replay")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ratingKeys(row)
                moveKeys
            } else {
                finished
            }
            lastLine
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quick Rate").font(.title2.bold())
                Text("· \(review.source)").font(.title2).foregroundStyle(.secondary)
                Spacer()
                Button { library.endReview() } label: {
                    HStack(spacing: 6) { Text("Done"); KeyCap("esc") }
                }
            }
            Text("\(review.remaining.formatted()) of \(review.total.formatted()) unrated left · \(review.bestFirst ? "best guesses first" : "shuffled")\(review.groove ? ", next track follows key and tempo" : "") · starting just before the first drop")
                .foregroundStyle(.secondary)
            ProgressView(value: Double(review.total - review.remaining), total: Double(max(review.total, 1)))
                .tint(Color.pending)
        }
    }

    private func track(_ row: TrackRow) -> some View {
        HStack(spacing: 20) {
            Group {
                if let art = player.current?.id == row.id ? player.artwork : nil {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.06))
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text(row.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                Text([row.artist, row.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    KeyChip(key: row.key)
                    chip("\(row.bpmText) BPM")
                    if let e = row.energy { chip("Energy \(e)") }
                    chip(formatTime(row.duration))
                    Text("added \(row.dateAdded.formatted(.dateTime.month(.abbreviated).year()))")
                        .foregroundStyle(.secondary)
                }
                if case let why = review.reasons(row.id), !why.isEmpty {
                    Label(why.joined(separator: " · "), systemImage: "sparkles")
                        .font(.callout).foregroundStyle(Color.pending.opacity(0.9))
                }
                if row.rating > 0 {
                    Text("Currently \(String(repeating: "★", count: row.rating)): ⌥1–⌥5 to change it, j to keep it")
                        .font(.callout).foregroundStyle(Color.pending)
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
    }

    /// Five rating buttons; ⌥1–⌥5 press them (plain digits are hot cues, as in the list). The keys
    /// are in each button's tooltip rather than on it, to keep the row quiet.
    private func ratingKeys(_ row: TrackRow) -> some View {
        let labels = ["Not for me", "Meh", "Decent", "Great", "Banger"]
        return HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { n in
                Button { review.rate(n) } label: {
                    VStack(spacing: 6) {
                        Text(String(repeating: "★", count: n)).font(.system(size: 11))
                            .foregroundStyle(Color.pending).lineLimit(1).fixedSize()
                        Text(labels[n - 1]).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(row.rating == n ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rate \(n) star\(n == 1 ? "" : "s") and go to the next track (⌥\(n))")
            }
        }
    }

    /// Three groups on one row: moving (j k) left, playlists (⇧P) centre, order (g o) right. Two
    /// rows only when the window is too narrow for one.
    private var moveKeys: some View {
        let move = HStack(spacing: 16) {
            hint("j", "Next, no rating")
            hint("k", "Previous track")
        }
        let playlist = hint("⇧P", "Add to playlist")
        let order = HStack(spacing: 16) {
            hint("g", review.groove ? "Groove on" : "Groove off")
            hint("o", review.bestFirst ? "Best guesses first" : "Shuffled")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                move
                Spacer(minLength: 16)
                playlist
                Spacer(minLength: 16)
                order
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) { move; playlist }
                order
            }
        }
        .foregroundStyle(.secondary)
        .help("j leaves a track unrated and doesn't offer it again for \(Review.snoozeDays) days · g picks each next track to mix with this one")
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key)
            Text(text).lineLimit(1).fixedSize()
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All done").font(.title.bold())
            Text("You went through \(review.history.count.formatted()) tracks in \(review.source).")
                .foregroundStyle(.secondary)
            HStack {
                Button("Back to the list") { library.endReview() }.keyboardShortcut(.defaultAction)
                Text("k goes back to the last track").foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder private var lastLine: some View {
        if let (row, action) = review.last {
            let what = switch action {
            case .rated(let n): String(repeating: "★", count: n)
            case .skipped: "skipped for \(Review.snoozeDays) days"
            }
            Text("Last: \(row.title) · \(what) · k to go back")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Returns true when the key was a Quick Rate command. Leaves keys alone while the playlist
    /// picker (or any sheet) is open, while typing in a text field, and with ⌘ or ⌃ held.
    private func handle(_ event: NSEvent) -> Bool {
        guard picking == nil, let window = event.window, window.attachedSheet == nil, window.isKeyWindow,
              !(window.firstResponder is NSTextView),
              event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        switch event.keyCode {
        case 53: library.endReview(); return true   // Escape
        case 49: player.toggle(); return true       // Space
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers else { return false }
        if event.modifierFlags.contains(.option) {
            guard let n = Int(ch), (1...5).contains(n) else { return false }
            review.rate(n)
            return true
        }
        switch ch {
        case "1", "2", "3", "4", "5", "6", "7", "8": if !player.jumpToHotCue(Int(ch)!) { NSSound.beep() }
        case "P": if let id = review.current?.id { picking = id }
        case "g": review.groove.toggle()
        case "o": review.bestFirst.toggle()
        case "j": review.skip()
        case "k": review.back()
        case "l", "p": review.replay()
        case ",": player.jumpBeats(-4)
        case ".": player.jumpBeats(4)
        case "<": player.jumpBeats(-16)
        case ">": player.jumpBeats(16)
        case "[": player.jumpSection(-1)
        case "]": player.jumpSection(1)
        default: return false
        }
        return true
    }
}

/// Quick Rate's right-hand column: this session's tally and what's coming up. Scrolls, so its
/// content can never make the window taller than it is.
struct ReviewPanel: View {
    var review: Review

    var body: some View {
        ScrollView {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        let tally = review.tally
        let most = Double(max(tally.max() ?? 1, 1))
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("THIS SESSION · \(review.history.count) TRACKS")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach([5, 4, 3, 2, 1, 0], id: \.self) { n in
                    HStack(spacing: 8) {
                        Text(n == 0 ? "Skipped" : String(repeating: "★", count: n))
                            .font(.caption).foregroundStyle(n == 0 ? Color.secondary : Color.pending)
                            .frame(width: 64, alignment: .leading)
                        ProgressView(value: Double(tally[n]), total: most)
                            .tint(n == 0 ? Color.secondary : Color.pending)
                        Text("\(tally[n])").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
            if !review.upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("COMING UP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(review.upcoming) { r in
                        HStack(spacing: 6) {
                            Text(r.title).lineLimit(1)
                            Spacer(minLength: 4)
                            KeyChip(key: r.key)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("HOW IT WORKS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Ratings go straight to Apple Music. j leaves a track unrated and hides it from Quick Rate for \(Review.snoozeDays) days; nothing is written to Music.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
        }
    }
}

/// A small keycap label.
struct KeyCap: View {
    var key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.15)))
    }
}
