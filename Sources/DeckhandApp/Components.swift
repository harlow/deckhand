import Analysis
import DeckhandAppCore
import DeckhandCore
import SwiftUI

extension Color {
    static let waveLow = Color(red: 0.24, green: 0.49, blue: 1.0)
    static let waveMid = Color(red: 0.94, green: 0.65, blue: 0.23)
    static let waveHigh = Color(red: 0.9, green: 0.9, blue: 0.93)
    static let synced = Color(red: 0.25, green: 0.76, blue: 0.69)
    static let pending = Color(red: 1.0, green: 0.70, blue: 0.25)

    init(rgb: [UInt8]) {
        self.init(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255)
    }

    /// Camelot wheel color: hue follows the wheel; minor (A) keys are deeper than major (B).
    static func camelot(_ key: MusicalKey) -> Color {
        let hue = Double((key.camelotNumber * 30 + 150) % 360) / 360
        return key.mode == .minor ? Color(hue: hue, saturation: 0.55, brightness: 0.88)
            : Color(hue: hue, saturation: 0.35, brightness: 0.97)
    }

    static func phrase(_ kind: StructureAnalyzer.Kind) -> Color {
        switch kind {
        case .intro, .outro: Color(red: 0.50, green: 0.65, blue: 0.85)
        case .build: Color(red: 0.90, green: 0.76, blue: 0.36)
        case .drop: Color(red: 1.0, green: 0.54, blue: 0.48)
        case .breakdown: Color(red: 0.73, green: 0.64, blue: 0.94)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Quiet toolbar controls gain a little contrast under the pointer. Active filters stay blue;
/// disabled controls never suggest an available action.
struct ControlHoverSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var active = false
    var bordered = true
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var highlighted: Bool { enabled && (hovered || pressed) }

    func body(content: Content) -> some View {
        content
            .background((active ? Color.accentColor : .white)
                .opacity(active ? (highlighted ? 0.4 : 0.3) : (highlighted ? 0.12 : 0.06)), in: shape)
            .overlay {
                if bordered {
                    shape.strokeBorder(active ? Color.accentColor : Color.white.opacity(highlighted ? 0.22 : 0.12))
                }
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }
}

struct QuietHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: 24)
            .modifier(ControlHoverSurface(shape: RoundedRectangle(cornerRadius: 5),
                                          bordered: false, pressed: configuration.isPressed))
    }
}

struct KeyChip: View {
    var key: MusicalKey?

    var body: some View {
        Text(key?.alphanumeric ?? "—")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(key == nil ? Color.secondary : Color.black.opacity(0.85))
            .frame(width: 36, height: 20)
            .background(key.map(Color.camelot) ?? Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            .help(key?.longName ?? "Key not analyzed")
    }
}

struct EnergyBar: View {
    var energy: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < (energy ?? 0) ? color : Color.white.opacity(0.12))
                    .frame(width: 4, height: 11)
            }
            Text(energy.map(String.init) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .accessibilityElement()
        .accessibilityLabel(energy.map { "Energy \($0) of 10" } ?? "Energy not analyzed")
    }

    private var color: Color {
        switch energy ?? 0 {
        case ...4: Color(red: 0.31, green: 0.55, blue: 1)
        case 5...6: Color(red: 0.88, green: 0.70, blue: 0.23)
        case 7...8: Color(red: 0.94, green: 0.54, blue: 0.23)
        default: Color(red: 1, green: 0.42, blue: 0.36)
        }
    }
}

/// A track's status on the active drive. Nothing for tracks the drive doesn't take, or whose status isn't known
/// (still checking, audio not hashed yet): unknown is neither synced nor pending.
struct SyncDot: View {
    var state: DriveStatus.Track?

    var body: some View {
        switch state {
        case .synced: Circle().fill(Color.synced).frame(width: 7, height: 7).help("On the drive")
        case .retained(let why):
            Circle().fill(Color.synced).frame(width: 7, height: 7).help("On the drive, kept although its source can't be read: \(why)")
        case .failed(let why): Circle().fill(Color.synced).frame(width: 7, height: 7).help("On the drive without analysis: \(why)")
        case .pending: Circle().strokeBorder(Color.pending, lineWidth: 2).frame(width: 9, height: 9).help("Waiting to sync")
        case .ineligible(let why): Color.clear.frame(width: 9, height: 9).help("Can't go on the drive: \(why)")
        case .unknown, nil: Color.clear.frame(width: 9, height: 9)
        }
    }
}

/// Three-band waveform (low blue, mid amber, high white) with cue ticks and an optional playhead.
struct WaveformView: View {
    var overview: Overview
    var progress: Double?
    var showCues = true

    var body: some View {
        Canvas { ctx, size in
            let n = overview.low.count
            guard n > 0 else { return }
            let w = size.width / CGFloat(n)
            for i in 0..<n {
                let x = CGFloat(i) * w
                for (values, color) in [(overview.low, Color.waveLow), (overview.mid, .waveMid), (overview.high, .waveHigh)] {
                    let h = CGFloat(values[min(i, values.count - 1)]) * size.height
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: max(w - 0.4, 0.6), height: h)), with: .color(color))
                }
            }
            if showCues {
                for c in overview.cues {
                    ctx.fill(Path(CGRect(x: c * size.width - 1, y: 0, width: 2, height: 5)), with: .color(.orange))
                }
            }
            if let p = progress {
                let x = p * size.width
                ctx.fill(Path(CGRect(x: 0, y: 0, width: x, height: size.height)), with: .color(.black.opacity(0.35)))
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}

/// Reports where in a view the user clicked, as a fraction of its width.
struct ClickPosition: ViewModifier {
    var action: (Double) -> Void

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in action(max(0, min(1, v.location.x / geo.size.width))) })
        }
    }
}

extension View {
    func onClickPosition(_ action: @escaping (Double) -> Void) -> some View {
        modifier(ClickPosition(action: action))
    }
}

/// The Deckhand "Platter" mark: a jog-wheel ring with a cue notch and spindle (see Scripts/make-icon.swift).
/// `mono` drops the notch and color for small sizes such as the title bar.
struct PlatterMark: View {
    var mono = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                Circle()
                    .inset(by: (100 - 76) * s)
                    .stroke(mono ? Color.primary : Color(red: 0.93, green: 0.93, blue: 0.94), lineWidth: (mono ? 22 : 18) * s)
                Circle()
                    .fill(mono ? Color.primary : Color(red: 1, green: 0.70, blue: 0.25))
                    .frame(width: (mono ? 56 : 52) * s, height: (mono ? 56 : 52) * s)
                if !mono {
                    RoundedRectangle(cornerRadius: 4 * s)
                        .fill(Color(red: 1, green: 0.70, blue: 0.25))
                        .frame(width: 14 * s, height: 40 * s)
                        .offset(y: -72 * s)
                        .rotationEffect(.degrees(38))
                }
            }
            .frame(width: 200 * s, height: 200 * s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Five stars; click one to rate, click the current rating again to clear it.
struct StarRating: View {
    var rating: Int
    var set: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                Button { set(n == rating ? 0 : n) } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(n <= rating ? Color.waveMid : Color.white.opacity(0.18))
                        .frame(width: 13, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(rating == 0 ? "Not rated" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: set(min(5, rating + 1))
            case .decrement: set(max(0, rating - 1))
            @unknown default: break
            }
        }
    }
}
