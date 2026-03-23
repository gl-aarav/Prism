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

// MARK: - Unified Web Overlay Item

/// Represents either a built-in service or a custom web view in the overlay.
struct WebOverlayItem: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let icon: String
    let isCustom: Bool

    init(service: WebOverlayService) {
        self.id = "builtin_\(service.rawValue)"
        self.name = service.rawValue
        self.url = service.url
        self.icon = service.icon
        self.isCustom = false
    }

    init(custom: CustomWebView) {
        self.id = "custom_\(custom.id.uuidString)"
        self.name = custom.name.isEmpty ? custom.url : custom.name
        self.url = URL(string: custom.url) ?? URL(string: "https://example.com")!
        self.icon = custom.icon ?? "globe"
        self.isCustom = true
    }
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
        if UserDefaults.standard.bool(forKey: "WebOverlayClickOutsideCloses") {
            orderOut(nil)
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
    @Published var currentItemId: String = "builtin_Gemini"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    // Persistent WKWebViews keyed by item id
    private var webViews: [WebOverlayService: WKWebView] = [:]
    private var customWebViews: [String: WKWebView] = [:]
    // Coordinator per service/item
    private var coordinators: [WebOverlayService: WebOverlayCoordinator] = [:]
    private var customCoordinators: [String: WebOverlayCoordinator] = [:]

    private let panelWidth: CGFloat = 420
    private let panelMinHeight: CGFloat = 500
    private let panelMaxHeight: CGFloat = 800
    private var navigationObservers: [WebOverlayService: NSKeyValueObservation] = [:]
    private var backObservers: [WebOverlayService: NSKeyValueObservation] = [:]
    private var forwardObservers: [WebOverlayService: NSKeyValueObservation] = [:]
    private var customBackObservers: [String: NSKeyValueObservation] = [:]
    private var customForwardObservers: [String: NSKeyValueObservation] = [:]

    private init() {
        // Load last used service
        if let savedItemId = UserDefaults.standard.string(forKey: "WebOverlayLastItemId"),
            !savedItemId.isEmpty
        {
            currentItemId = savedItemId
            // Try to resolve as built-in service
            if savedItemId.hasPrefix("builtin_") {
                let raw = String(savedItemId.dropFirst("builtin_".count))
                if let service = WebOverlayService(rawValue: raw) {
                    currentService = service
                }
            }
        } else if let saved = UserDefaults.standard.string(forKey: "WebOverlayLastService"),
            let service = WebOverlayService(rawValue: saved)
        {
            currentService = service
            currentItemId = "builtin_\(saved)"
        }
    }

    func setup() {
        // Restore persisted size or use defaults
        let savedWidth = UserDefaults.standard.double(forKey: "WebOverlayWidth")
        let savedHeight = UserDefaults.standard.double(forKey: "WebOverlayHeight")
        let width = savedWidth > 0 ? CGFloat(savedWidth) : panelWidth
        let height = savedHeight > 0 ? CGFloat(savedHeight) : 600

        let panel = WebOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
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

        // Observe panel resize to persist size
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel = panel else { return }
            UserDefaults.standard.set(Double(panel.frame.width), forKey: "WebOverlayWidth")
            UserDefaults.standard.set(Double(panel.frame.height), forKey: "WebOverlayHeight")
        }

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
        currentItemId = "builtin_\(service.rawValue)"
        UserDefaults.standard.set(service.rawValue, forKey: "WebOverlayLastService")
        UserDefaults.standard.set(currentItemId, forKey: "WebOverlayLastItemId")
        updateNavigationState()
    }

    func switchToItem(_ item: WebOverlayItem) {
        currentItemId = item.id
        UserDefaults.standard.set(item.id, forKey: "WebOverlayLastItemId")
        if !item.isCustom {
            // Resolve built-in service
            let raw = String(item.id.dropFirst("builtin_".count))
            if let service = WebOverlayService(rawValue: raw) {
                currentService = service
                UserDefaults.standard.set(service.rawValue, forKey: "WebOverlayLastService")
            }
        }
        updateNavigationState()
    }

    private func updateNavigationState() {
        if currentItemId.hasPrefix("custom_") {
            if let webView = customWebViews[currentItemId] {
                canGoBack = webView.canGoBack
                canGoForward = webView.canGoForward
            } else {
                canGoBack = false
                canGoForward = false
            }
        } else {
            if let webView = webViews[currentService] {
                canGoBack = webView.canGoBack
                canGoForward = webView.canGoForward
            } else {
                canGoBack = false
                canGoForward = false
            }
        }
    }

    func goBack() {
        if currentItemId.hasPrefix("custom_") {
            customWebViews[currentItemId]?.goBack()
        } else {
            webViews[currentService]?.goBack()
        }
    }

    func goForward() {
        if currentItemId.hasPrefix("custom_") {
            customWebViews[currentItemId]?.goForward()
        } else {
            webViews[currentService]?.goForward()
        }
    }

    func reloadCurrentPage() {
        if currentItemId.hasPrefix("custom_") {
            customWebViews[currentItemId]?.reload()
        } else {
            webViews[currentService]?.reload()
        }
    }

    func navigateToHome() {
        if currentItemId.hasPrefix("custom_") {
            if let item = allItems().first(where: { $0.id == currentItemId }) {
                customWebViews[currentItemId]?.load(URLRequest(url: item.url))
            }
        } else {
            webViews[currentService]?.load(URLRequest(url: currentService.url))
        }
    }

    func getWebView(for service: WebOverlayService) -> WKWebView {
        if let existing = webViews[service] {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []

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

        // Observe back/forward state for the current service
        backObservers[service] = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateNavigationState()
            }
        }
        forwardObservers[service] = webView.observe(\.canGoForward, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateNavigationState()
            }
        }

        return webView
    }

    func getCustomWebView(for item: WebOverlayItem) -> WKWebView {
        if let existing = customWebViews[item.id] {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        let coordinator = WebOverlayCoordinator()
        customCoordinators[item.id] = coordinator
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator

        webView.load(URLRequest(url: item.url))
        customWebViews[item.id] = webView

        customBackObservers[item.id] = webView.observe(\.canGoBack, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateNavigationState()
            }
        }
        customForwardObservers[item.id] = webView.observe(\.canGoForward, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateNavigationState()
            }
        }

        return webView
    }

    func coordinatorForItem(_ item: WebOverlayItem) -> WebOverlayCoordinator? {
        if item.isCustom {
            return customCoordinators[item.id]
        } else {
            let raw = String(item.id.dropFirst("builtin_".count))
            if let service = WebOverlayService(rawValue: raw) {
                return coordinators[service]
            }
            return nil
        }
    }

    func webViewForItem(_ item: WebOverlayItem) -> WKWebView {
        if item.isCustom {
            return getCustomWebView(for: item)
        } else {
            let raw = String(item.id.dropFirst("builtin_".count))
            if let service = WebOverlayService(rawValue: raw) {
                return getWebView(for: service)
            }
            // Fallback
            return getCustomWebView(for: item)
        }
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

    /// Returns all items (built-in + custom) for the overlay.
    func allItems() -> [WebOverlayItem] {
        var items: [WebOverlayItem] = enabledServices.map { WebOverlayItem(service: $0) }
        let customs = loadCustomWebViews()
        items.append(contentsOf: customs.map { WebOverlayItem(custom: $0) })
        return items
    }

    /// Load custom web views from UserDefaults.
    private func loadCustomWebViews() -> [CustomWebView] {
        guard let json = UserDefaults.standard.string(forKey: "CustomWebViews"),
            let data = json.data(using: .utf8),
            let views = try? JSONDecoder().decode([CustomWebView].self, from: data)
        else { return [] }
        return views
    }

    /// Notify the manager to refresh (e.g. when custom web views change in settings).
    func refreshItems() {
        objectWillChange.send()
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

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection

        // Present as a sheet on the overlay panel window so the picker
        // appears on the overlay, not the main app window.
        if let window = webView.window {
            openPanel.beginSheetModal(for: window) { response in
                if response == .OK {
                    completionHandler(openPanel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        } else {
            // Fallback: present as a standalone modal window
            let response = openPanel.runModal()
            if response == .OK {
                completionHandler(openPanel.urls)
            } else {
                completionHandler(nil)
            }
        }
    }
}
