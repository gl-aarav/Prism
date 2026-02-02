import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case graphite = "Graphite"

    var id: String { self.rawValue }

    var gradientColors: [NSColor] {
        switch self {
        case .default:
            return [.cyan, .systemBlue, .systemGreen]
        case .blue:
            return [.systemTeal, .systemBlue, .systemIndigo]
        case .purple:
            return [.systemIndigo, .systemPurple, .systemPink]
        case .pink:
            return [.systemPurple, .systemPink, .systemRed]
        case .red:
            return [.systemOrange, .systemRed, .systemPink]
        case .orange:
            return [.systemYellow, .systemOrange, .systemRed]
        case .yellow:
            return [.systemYellow, .systemOrange, .systemBrown]
        case .green:
            return [.systemMint, .systemGreen, .systemTeal]
        case .graphite:
            return [.systemGray, .darkGray, .black]
        }
    }

    var colors: [Color] {
        gradientColors.map { Color(nsColor: $0) }
    }
}

class IconManager: ObservableObject {
    static let shared = IconManager()

    private var observation: NSKeyValueObservation?

    // Retrieves current theme from UserDefaults directly to avoid property wrapper issues in non-View class
    var currentTheme: AppTheme {
        if let saved = UserDefaults.standard.string(forKey: "AppTheme"),
            let theme = AppTheme(rawValue: saved)
        {
            return theme
        }
        return .default
    }

    init() {
        // Observe appearance changes to update for Dark Mode
        observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateIcon()
            }
        }
    }

    @MainActor
    func updateIcon(theme: AppTheme? = nil) {
        let themeToUse = theme ?? self.currentTheme
        let isDark =
            NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            == .darkAqua

        let renderer = ImageRenderer(content: PrismIconView(theme: themeToUse, isDark: isDark))
        renderer.scale = 1.0  // Ensure 1:1 pixel mapping for 1024x1024

        if let image = renderer.nsImage {
            // Ensure the image has the correct pixel size
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
            rep?.size = CGSize(width: 1024, height: 1024)
            let finalImage = NSImage(size: CGSize(width: 1024, height: 1024))
            finalImage.addRepresentation(rep!)

            NSApplication.shared.applicationIconImage = finalImage
        }
    }

    // No longer used, replaced by SwiftUI view
    private func generateIconImage(theme: AppTheme, triangleColor: NSColor) -> NSImage? {
        return nil
    }
}

struct PrismIconView: View {
    let theme: AppTheme
    let isDark: Bool

    // Standard macOS Icon Size
    let size: CGFloat = 1024

    // Apple Design Resources Guidelines:
    // The icon grid is 1024x1024.
    // The main shape area is effectively ~824x824 (padding of ~100pt).
    // Apple suggests simple "RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)"
    // applied to the ~824px shape.

    var body: some View {
        let padding: CGFloat = 100
        let iconSize = size - (padding * 2)
        // Correct squircle logic: approx 22% of sizing.
        // Update for macOS Tahoe "bubbly" look: ~23%
        let cornerRadius = iconSize * 0.24

        ZStack {
            // Transparent background for the 1024x1024 canvas
            Color.clear

            // The Squircle Shape
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: theme.colors),
                        center: .center,
                        startRadius: 0,
                        endRadius: iconSize  // Gradient radius approx width of icon
                    )
                )
                .frame(width: iconSize, height: iconSize)
                // Add weak shadow to mimic system lift?
                // System usually adds its own shadow in Dock, but for .icns we often bake a small one or none.
                // Keeping it flat as per modern trends or adding very subtle one.
                // Prism original code had a shadow.
                .shadow(
                    color: Color.black.opacity(0.1), radius: iconSize * 0.02, x: 0,
                    y: iconSize * 0.01)

            // The 'Prism' Triangle
            // We scale the triangle to fit the iconSize
            GeometryReader { geo in
                let w = iconSize
                // h = iconSize
                // Scale factors from original 1024 logic:
                // Top: y=850 (near top logic inverted? No, in Draw func y=850 was top).
                // Wait, Quartz y=0 is bottom. So y=850 is top.
                // SwiftUI y=0 is top.

                // Original Triangle:
                // Top: (0.5, 0.83) in Quartz (850/1024)
                // BottomLeft: (0.195, 0.244) (200/1024, 250/1024)
                // BottomRight: (0.805, 0.244) (824/1024, 250/1024)
                // So it points UP.

                // In SwiftUI (Top-Left 0,0):
                // Top: y should be small. (1 - 0.83) = 0.17
                // Bottom: y should be large. (1 - 0.244) = 0.756

                Path { path in
                    // Top Point
                    path.move(to: CGPoint(x: w * 0.5, y: w * 0.17))
                    // Bottom Left
                    path.addLine(to: CGPoint(x: w * 0.195, y: w * 0.756))
                    // Bottom Right
                    path.addLine(to: CGPoint(x: w * 0.805, y: w * 0.756))
                    path.closeSubpath()
                }
                .fill(Color(nsColor: isDark ? .black : .white).opacity(isDark ? 0.3 : 0.2))

                Path { path in
                    path.move(to: CGPoint(x: w * 0.5, y: w * 0.17))
                    path.addLine(to: CGPoint(x: w * 0.195, y: w * 0.756))
                    path.addLine(to: CGPoint(x: w * 0.805, y: w * 0.756))
                    path.closeSubpath()
                }
                .stroke(
                    Color(nsColor: isDark ? .black : .white),
                    style: StrokeStyle(lineWidth: w * 0.04, lineCap: .round, lineJoin: .round))

                // Shine
                Path { path in
                    path.move(to: CGPoint(x: w * 0.5, y: w * 0.17))
                    path.addLine(to: CGPoint(x: w * 0.5, y: w * 0.756))
                }
                .stroke(
                    Color(nsColor: isDark ? .black : .white).opacity(isDark ? 0.5 : 0.4),
                    style: StrokeStyle(lineWidth: w * 0.01, lineCap: .round))
            }
            .frame(width: iconSize, height: iconSize)
        }
        .frame(width: size, height: size)
    }
}
