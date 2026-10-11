import SwiftUI

/// A neutral capacity indicator: the filled portion is used space, not sync progress.
struct DriveCapacityBar: View {
    var used: Int64
    var capacity: Int64

    private var fraction: Double {
        capacity > 0 ? min(1, max(0, Double(used) / Double(capacity))) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.gray)
                        .frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drive space used")
        .accessibilityValue(capacity > 0 ? "\(Int(fraction * 100)) percent" : "Capacity unavailable")
    }
}
