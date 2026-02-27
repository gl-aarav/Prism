import SwiftUI

/// SwiftUI view displayed inside the SuggestionOverlayPanel.
/// Shows the autocomplete suggestion inline as ghost text.
struct SuggestionOverlayView: View {
    let suggestion: String
    let fontSize: CGFloat
    let maxWidth: CGFloat

    var body: some View {
        Text(suggestion)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(10)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)

        // Add a soft shadow
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .fixedSize()
        // Provide transparent padding around the capsule so the 
        // NSPanel hosting view doesn't clip the shadow natively
        .padding(12)
        .allowsHitTesting(false)
    }
}
