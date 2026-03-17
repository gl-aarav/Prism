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
        ZStack {
            Color.clear
                .background(.ultraThinMaterial)

            if appTheme != .default {
                LinearGradient(
                    colors: appTheme.colors.map {
                        $0.opacity(colorScheme == .dark ? clampedTint * 0.85 : clampedTint * 0.6)
                    },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .opacity(clampedOpacity)
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
                        Text(selectedTool)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                )

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
                panelScale = 0.95
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
