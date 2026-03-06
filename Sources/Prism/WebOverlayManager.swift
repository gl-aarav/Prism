import AppKit
import SwiftUI
import WebKit

// MARK: - Web Overlay Service

enum WebOverlayService: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case chatgpt = "ChatGPT"
    case perplexity = "Perplexity"
    case grok = "Grok"
    case claude = "Claude"

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .gemini: return URL(string: "https://gemini.google.com")!
        case .chatgpt: return URL(string: "https://chatgpt.com")!
        case .perplexity: return URL(string: "https://www.perplexity.ai")!
        case .grok: return URL(string: "https://grok.com")!
        case .claude: return URL(string: "https://claude.ai")!
        }
    }

    var icon: String {
        switch self {
        case .gemini: return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .perplexity: return "magnifyingglass"
        case .grok: return "bolt.horizontal"
        case .claude: return "brain.head.profile"
        }
    }

    var defaultsKey: String { "WebOverlayEnabled_\(rawValue)" }
}

// MARK: - Web Overlay Panel

class WebOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        WebOverlayManager.shared.returnFocusToPreviousApp()
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible, !self.isKeyWindow else { return }
            self.orderOut(nil)
            WebOverlayManager.shared.returnFocusToPreviousApp()
        }
    }
}

// MARK: - Web Overlay Manager

class WebOverlayManager: ObservableObject {
    static let shared = WebOverlayManager()

    var panel: WebOverlayPanel?
    var previousApp: NSRunningApplication?
    @Published var currentService: WebOverlayService = .gemini

    // Persistent WKWebViews per service to preserve sessions
    private var webViews: [WebOverlayService: WKWebView] = [:]
    // Coordinator per service
    private var coordinators: [WebOverlayService: WebOverlayCoordinator] = [:]

    private let panelWidth: CGFloat = 420
    private let panelMinHeight: CGFloat = 500
    private let panelMaxHeight: CGFloat = 800

    private init() {
        // Load last used service
        if let saved = UserDefaults.standard.string(forKey: "WebOverlayLastService"),
            let service = WebOverlayService(rawValue: saved)
        {
            currentService = service
        }
    }

    func setup() {
        let height: CGFloat = 600
        let panel = WebOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 360, height: panelMinHeight)
        panel.maxSize = NSSize(width: 700, height: panelMaxHeight)

        let rootView = WebOverlayView(manager: self)
            .edgesIgnoringSafeArea(.all)

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: height))
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 16
        containerView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        self.panel = panel

        // Preload all enabled services' webviews
        preloadEnabledServices()
    }

    func preloadEnabledServices() {
        for service in WebOverlayService.allCases where isServiceEnabled(service) {
            _ = getWebView(for: service)
        }
    }

    func toggle() {
        guard let panel = panel else { return }

        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
            returnFocusToPreviousApp()
        } else {
            // Remember previous app before we do anything
            previousApp = NSWorkspace.shared.frontmostApplication

            positionPanel(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func switchService(_ service: WebOverlayService) {
        currentService = service
        UserDefaults.standard.set(service.rawValue, forKey: "WebOverlayLastService")
    }

    func getWebView(for service: WebOverlayService) -> WKWebView {
        if let existing = webViews[service] {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        let coordinator = WebOverlayCoordinator()
        coordinators[service] = coordinator
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator

        webView.load(URLRequest(url: service.url))
        webViews[service] = webView
        return webView
    }

    func coordinator(for service: WebOverlayService) -> WebOverlayCoordinator? {
        return coordinators[service]
    }

    func returnFocusToPreviousApp() {
        if let previousApp = previousApp {
            previousApp.activate(options: [])
            self.previousApp = nil
        }
    }

    func isServiceEnabled(_ service: WebOverlayService) -> Bool {
        let key = service.defaultsKey
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setServiceEnabled(_ service: WebOverlayService, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: service.defaultsKey)
        objectWillChange.send()
    }

    var enabledServices: [WebOverlayService] {
        WebOverlayService.allCases.filter { isServiceEnabled($0) }
    }

    private func positionPanel(_ panel: WebOverlayPanel) {
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let panelSize = panel.frame.size
            // Center on screen
            let x = screenRect.midX - (panelSize.width / 2)
            let y = screenRect.midY - (panelSize.height / 2)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
    }
}

// MARK: - Coordinator for WebView navigation

class WebOverlayCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Load everything in the same webview — no popups
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
