import SwiftUI

struct QuickToolsView: View {
    let onClose: () -> Void

    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("QuickToolSelected") private var selectedTool: String = "Image Generation"
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverClose: Bool = false
    @State private var isPresented: Bool = false
    @State private var panelScale: CGFloat = 0.95
    @State private var panelOpacity: Double = 0.0
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

        let baseDarkStart = 0.08
        let baseDarkEnd = 0.05
        let baseLightStart = 0.12
        let baseLightEnd = 0.08

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
                        ? clampedOpacity + 0.16
                        : clampedOpacity + 0.12
                )
                
            if appTheme != .default {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(gradient)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Menu {
                    Button(action: { selectedTool = "Image Generation" }) {
                        Label("Image Generator", systemImage: "photo.artframe")
                    }
                    Button(action: { selectedTool = "PDF Creator" }) {
                        Label("PDF Creator", systemImage: "doc.text")
                    }
                    Button(action: { selectedTool = "Model Comparison" }) {
                        Label(
                            "Model Comparison",
                            systemImage:
                                "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button(action: { selectedTool = "Commands" }) {
                        Label("Commands", systemImage: "command")
                    }
                    Button(action: { selectedTool = "Quiz Me" }) {
                        Label("Quiz Me", systemImage: "questionmark.circle")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconForTool(selectedTool))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        Text(selectedTool)
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

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(hoverClose ? .primary : .secondary)
                        .animation(.easeInOut(duration: 0.1), value: hoverClose)
                }
                .buttonStyle(.plain)
                .onHover { h in hoverClose = h }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.clear)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1),
                alignment: .bottom
            )
            .zIndex(10)

            // Content Area
            Group {
                switch selectedTool {
                case "Image Generation":
                    ImageGenerationView()
                case "PDF Creator":
                    PDFCreatorView()
                case "Model Comparison":
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
        .scaleEffect(panelScale)
        .opacity(panelOpacity)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            if let window = notification.object as? NSWindow, window as? QuickToolsPanel != nil {
                panelScale = 0.92
                panelOpacity = 0.0

                let springResponse = 0.40
                let springDamping = 0.82

                withAnimation(
                    .spring(
                        response: springResponse, dampingFraction: springDamping,
                        blendDuration: 0.08)
                ) {
                    panelScale = 1.0
                    panelOpacity = 1.0
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            notification in
            if let window = notification.object as? NSWindow, window as? QuickToolsPanel != nil {
                let springResponse = 0.40
                let springDamping = 0.82

                withAnimation(
                    .spring(
                        response: springResponse, dampingFraction: springDamping,
                        blendDuration: 0.08)
                ) {
                    panelScale = 0.92
                    panelOpacity = 0.0
                }
            }
        }
        .onAppear {
            panelScale = 0.95
            panelOpacity = 0.0

            let springResponse = 0.40
            let springDamping = 0.82

            withAnimation(
                .spring(
                    response: springResponse, dampingFraction: springDamping, blendDuration: 0.08)
            ) {
                panelScale = 1.0
                panelOpacity = 1.0
            }
        }
    }

    private func iconForTool(_ tool: String) -> String {
        switch tool {
        case "Image Generation": return "photo.artframe"
        case "PDF Creator": return "doc.text"
        case "Model Comparison":
            return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case "Commands": return "command"
        case "Quiz Me": return "questionmark.circle"
        default: return "hammer"
        }
    }
}
