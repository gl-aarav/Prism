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
                .padding(.leading, 2) // Slight padding so it doesn't hug the cursor too tightly
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxHeight: .infinity, alignment: .center) // Mathematically centers font within cursor geometry box
                .fixedSize(horizontal: true, vertical: false)
                .allowsHitTesting(false)
        }
    }
}
