import SwiftUI

struct QuickToolsView: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("QuickToolSelected") private var selectedTool: String = "Image Generation"
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("QuickToolsBackgroundOpacity") private var backgroundOpacity: Double = 0.25
    @AppStorage("QuickToolsTintIntensity") private var tintIntensity: Double = 0.5

    private var clampedOpacity: Double {
        min(max(backgroundOpacity, 0.05), 1.0)
    }

    private var clampedTint: Double {
        min(max(tintIntensity, 0.0), 1.0)
    }

    private var canonicalSelectedTool: String {
        switch selectedTool {
        case "Model Comparison": return "Compare"
        case "PDF Creator": return "File Creator"
        case "Image Generator": return "Image Generation"
        default: return selectedTool
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Content Area
            Group {
                switch canonicalSelectedTool {
                case "Image Generation":
                    ImageGenerationView()
                case "File Creator":
                    PDFCreatorView()
                case "Compare":
                    ModelComparisonView()
                case "Commands":
                    CommandsManagementView()
                case "Quiz Me":
                    QuizMeView()
                default:
                    ImageGenerationView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)

            // Floating tool selector
            HStack {
                Menu {
                    Button(action: { selectedTool = "Image Generation" }) {
                        Label("Image Generation", systemImage: "paintbrush")
                    }
                    Button(action: { selectedTool = "File Creator" }) {
                        Label("File Creator", systemImage: "doc.richtext")
                    }
                    Button(action: { selectedTool = "Compare" }) {
                        Label("Compare", systemImage: "square.split.2x1")
                    }
                    Button(action: { selectedTool = "Commands" }) {
                        Label("Commands", systemImage: "command")
                    }
                    Button(action: { selectedTool = "Quiz Me" }) {
                        Label("Quiz Me", systemImage: "questionmark.bubble")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconForTool(canonicalSelectedTool))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        Text(canonicalSelectedTool)
                            .font(.headline)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    .glassEffect(.regular, in: .capsule)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .focusEffectDisabled()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .background(Color.clear)
            .zIndex(10)
        }
        .background(QuickToolsPanelBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.0), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .onAppear {
            if selectedTool != canonicalSelectedTool {
                selectedTool = canonicalSelectedTool
            }
        }
        .focusEffectDisabled()
    }

    private func iconForTool(_ tool: String) -> String {
        switch tool {
        case "Image Generation": return "paintbrush"
        case "File Creator": return "doc.richtext"
        case "Compare": return "square.split.2x1"
        case "Commands": return "command"
        case "Quiz Me": return "questionmark.bubble"
        default: return "hammer"
        }
    }
}

struct QuickToolsPanelBackground: View {
    var cornerRadius: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuickToolsBackgroundOpacity") private var backgroundOpacity: Double = 0.25
    @AppStorage("QuickToolsTintIntensity") private var tintIntensity: Double = 0.5
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.05), 1.0)
    }

    private var clampedTintIntensity: Double {
        min(max(tintIntensity, 0.0), 1.0)
    }

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        let baseDarkStart = 0.08
        let baseDarkEnd = 0.05
        let baseLightStart = 0.12
        let baseLightEnd = 0.08

        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(
                        (colorScheme == .dark ? baseDarkStart : baseLightStart)
                            * clampedTintIntensity * 2),
                    location: 0.0),
                .init(
                    color: endColor.opacity(
                        (colorScheme == .dark ? baseDarkEnd : baseLightEnd)
                            * clampedTintIntensity * 2),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .opacity(
                    colorScheme == .dark
                        ? clampedBackgroundOpacity + 0.16
                        : clampedBackgroundOpacity + 0.12
                )
        }
    }
}
