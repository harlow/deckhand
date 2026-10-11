import SwiftUI

/// Filters on the left, Quick Rate and search on the right, with their bottom edges aligned.
/// Narrow columns wrap the tools without duplicating the search field or its keyboard focus.
struct TrackToolsLayout: Layout {
    private let gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? (ideal[0].width + gap + ideal[1].width)
        let sizes = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
        let wraps = ideal[0].width + gap + ideal[1].width > width
        return CGSize(width: width, height: wraps ? sizes[0].height + 8 + sizes[1].height : max(sizes[0].height, sizes[1].height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let sizes = ideal.map { CGSize(width: min($0.width, bounds.width), height: $0.height) }
        let wraps = ideal[0].width + gap + ideal[1].width > bounds.width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: wraps ? bounds.minY : bounds.maxY - sizes[0].height),
                          proposal: .init(width: sizes[0].width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX - sizes[1].width, y: bounds.maxY - sizes[1].height),
                          proposal: .init(width: sizes[1].width, height: nil))
    }
}
