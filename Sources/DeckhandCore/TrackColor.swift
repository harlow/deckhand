/// The eight standard Pioneer track colors, in device order.
public enum TrackColor: Int, CaseIterable, Codable, Sendable {
    case pink = 1, red, orange, yellow, green, aqua, blue, purple

    public var name: String {
        switch self {
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }
}
