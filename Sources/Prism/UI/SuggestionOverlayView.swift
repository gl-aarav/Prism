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
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: true)
                .allowsHitTesting(false)
        }
    }
}
