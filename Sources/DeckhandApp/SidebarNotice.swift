import SwiftUI

/// A transient message constrained to its sidebar, expanding vertically for longer text.
struct SidebarNotice: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
