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

    private var customBackground: some View {
        let colors = appTheme.colors

        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        let baseDarkStart = 0.12
        let baseDarkEnd = 0.08
        let baseLightStart = 0.16
        let baseLightEnd = 0.12

        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(
                        (colorScheme == .dark ? baseDarkStart : baseLightStart)
                            * clampedTint * 2),
                    location: 0.0),
                .init(
                    color: endColor.opacity(
                        (colorScheme == .dark ? baseDarkEnd : baseLightEnd) * clampedTint * 2),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .opacity(
                    colorScheme == .dark
                        ? clampedOpacity + 0.2
                        : clampedOpacity + 0.16
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(gradient)
        }
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
                    .contentShape(Rectangle())
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    .glassEffect(.regular, in: .capsule)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .background(Color.clear)
            .zIndex(10)
        }
        .background(customBackground)
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
