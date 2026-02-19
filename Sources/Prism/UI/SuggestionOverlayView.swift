import SwiftUI

/// SwiftUI view displayed inside the SuggestionOverlayPanel.
/// Shows the autocomplete suggestion as inline ghost text — no bubble,
/// no background, just gray continuation text that appears to flow
/// naturally from the user's cursor.
struct SuggestionOverlayView: View {
    @EnvironmentObject var manager: AutocompleteManager

    var body: some View {
        if let suggestion = manager.suggestion {
            Text(suggestion)
                // Use dynamic font size matching exact host app text size
                .font(.system(size: manager.suggestionFontSize, weight: .regular, design: .default))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, -1.5) // Nudge slightly left to counteract standard font bearing
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) // Anchors straight to the descender baseline
                .fixedSize(horizontal: true, vertical: false)
                .allowsHitTesting(false)
        }
    }
}
