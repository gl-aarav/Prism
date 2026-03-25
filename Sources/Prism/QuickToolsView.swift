import SwiftUI
import WebKit

struct QuickToolsView: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("QuickToolSelected") private var selectedTool: String = "Image Generation"
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("QuickToolsBackgroundOpacity") private var backgroundOpacity: Double = 0.25
    @AppStorage("QuickToolsTintIntensity") private var tintIntensity: Double = 0.5
    @AppStorage("CustomWebViews") private var customWebViewsJSON: String = "[]"
    @State private var isToolMenuOpen: Bool = false

    private var clampedOpacity: Double {
        min(max(backgroundOpacity, 0.05), 1.0)
    }

    private var clampedTint: Double {
        min(max(tintIntensity, 0.0), 1.0)
    }

    private var canonicalSelectedTool: String {
        switch selectedTool {
        case "Model Comparison": return "Compare"
        case "File Creator": return "File Creator"
        case "Image Generator": return "Image Generation"
        default: return selectedTool
        }
    }

    private var customWebViewsList: [CustomWebView] {
        guard let data = customWebViewsJSON.data(using: .utf8),
            let views = try? JSONDecoder().decode([CustomWebView].self, from: data)
        else { return [] }
        return views
    }

    private var isCustomWebViewSelected: Bool {
        selectedTool.hasPrefix("CustomWebTool:")
    }

    private var selectedCustomWebView: CustomWebView? {
        guard isCustomWebViewSelected else { return nil }
        let urlStr = String(selectedTool.dropFirst("CustomWebTool:".count))
        return customWebViewsList.first(where: { $0.url == urlStr })
    }

    private func toolDisplayName() -> String {
        if let custom = selectedCustomWebView {
            return custom.name.isEmpty ? custom.url : custom.name
        }
        return canonicalSelectedTool
    }

    private func toolDisplayIcon() -> String {
        if let custom = selectedCustomWebView {
            return custom.icon ?? "globe"
        }
        return iconForTool(canonicalSelectedTool)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Content Area
            Group {
                if isCustomWebViewSelected, let custom = selectedCustomWebView,
                    let url = URL(string: custom.url)
                {
                    QuickToolsWebViewContainer(url: url)
                } else {
                    switch canonicalSelectedTool {
                    case "Image Generation":
                        ImageGenerationView()
                    case "File Creator":
                        FileCreatorView()
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

                    if !customWebViewsList.isEmpty {
                        Divider()
                        ForEach(customWebViewsList) { webView in
                            Button(action: {
                                selectedTool = "CustomWebTool:\(webView.url)"
                            }) {
                                Label(
                                    webView.name.isEmpty ? webView.url : webView.name,
                                    systemImage: webView.icon ?? "globe"
                                )
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: toolDisplayIcon())
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        Text(toolDisplayName())
                            .font(.headline)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .lineLimit(1)
                        Image(systemName: isToolMenuOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.6) : Color.black.opacity(0.5))
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
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .focusEffectDisabled()
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isToolMenuOpen.toggle()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isToolMenuOpen = false
                            }
                        }
                    })
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
            if !isCustomWebViewSelected && selectedTool != canonicalSelectedTool {
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
                .fill(Color.clear)
                .glassEffect(
                    .regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .opacity(
                    colorScheme == .dark
                        ? clampedBackgroundOpacity + 0.16
                        : clampedBackgroundOpacity + 0.12
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Quick Tools Web View Container

struct QuickToolsWebViewContainer: View {
    let url: URL
    @State private var webView: WKWebView?

    var body: some View {
        QuickToolsWebViewRepresentable(url: url, webView: $webView)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 48)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
    }
}

struct QuickToolsWebViewRepresentable: NSViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            self.webView = wv
        }

        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Only reload if the URL has changed (different custom web view selected)
        if nsView.url?.absoluteString != url.absoluteString {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> WebOverlayCoordinator {
        WebOverlayCoordinator()
    }
}
