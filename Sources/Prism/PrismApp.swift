import KeyboardShortcuts
import SwiftUI

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppState.shared)  // If needed or just environmentObject(ChatManager.shared)
                .navigationTitle("Prism")
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Prism") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "Developed by Aarav Goyal",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.labelColor,
                                ]
                            )
                        ]
                    )
                }
                Divider()
                Button("Check for Updates…") {
                    AppDelegate.shared?.showUpdateWindow()
                    Task { await UpdateManager.shared.checkForUpdates() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(ChatManager.shared)
                .frame(minWidth: 420, minHeight: 500)
        }
    }
}

class AppState: ObservableObject {
    static let shared = AppState()
    var hasShownSplash: Bool = false

    private init() {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var updateWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: [
            "ShowMenuBar": true,
            "EnableQuickAI": true,
            "EnableWebOverlay": true,
            "EnableAIAutocomplete": false,
            "AIAutocompleteBackend": "Ollama",
            "AIAutocompleteDebounceMs": 500,
            "AIAutocompleteMemoryEnabled": true,
            "QuickAIClickOutsideCloses": false,
            "WebOverlayClickOutsideCloses": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app is a regular app (shows in Dock, has UI)
        NSApp.setActivationPolicy(.regular)

        // Bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Force main window to appear if needed
        // Observe new windows becoming main to auto-zoom them
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                !(window is QuickAIPanel),
                !(window is WebOverlayPanel),
                !(window is NSPanel)
            else { return }
            // Zoom the window to fill the screen if it isn't already zoomed
            if !window.isZoomed {
                window.zoom(nil)
            }
        }

        DispatchQueue.main.async {
            // Find the main window (not the Quick AI panel or Web Overlay)
            if let window = NSApp.windows.first(where: {
                !($0 is QuickAIPanel) && !($0 is WebOverlayPanel)
            }) {
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                // Zoom to fill the screen instead of centering at default size
                window.zoom(nil)
            }
        }

        // When the main window closes via Cmd+W, just hide it instead of closing
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                !(window is QuickAIPanel),
                !(window is WebOverlayPanel),
                !(window is NSPanel)
            else { return }
            // Keep the window around so it can be re-shown
            window.isReleasedWhenClosed = false
        }

        QuickAIManager.shared.setup()
        WebOverlayManager.shared.setup()

        // Setup menu bar status item
        setupStatusItem()

        HotKeyManager.shared.onTrigger = {
            if UserDefaults.standard.bool(forKey: "EnableQuickAI") {
                QuickAIManager.shared.toggle()
            }
        }
        HotKeyManager.shared.register()

        // Web Overlay shortcut
        KeyboardShortcuts.onKeyUp(for: .toggleWebOverlay) {
            if UserDefaults.standard.bool(forKey: "EnableWebOverlay") {
                WebOverlayManager.shared.toggle()
            }
        }

        // AI Autocomplete: register toggle shortcut and auto-start if enabled
        KeyboardShortcuts.onKeyUp(for: .toggleAIAutocomplete) {
            AutocompleteManager.shared.toggle()
        }
        if UserDefaults.standard.bool(forKey: "EnableAIAutocomplete") {
            AutocompleteManager.shared.setup()
        }

        IconManager.shared.updateIcon()

        // Start local extension server on a background thread to avoid blocking launch
        DispatchQueue.global(qos: .utility).async {
            ExtensionServer.shared.start()
        }

        print("Prism has launched!")

        // Check for updates silently on launch
        Task {
            await UpdateManager.shared.checkForUpdates()
        }
    }

    func showUpdateWindow() {
        if let existing = updateWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // Clear stale reference to prevent use-after-free
        updateWindow = nil

        let view = UpdateView()
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = hostingView
        window.center()
        window.title = "Software Update"
        window.makeKeyAndOrderFront(nil)
        updateWindow = window
    }

    private func setupStatusItem() {
        // Check ShowMenuBar preference and create status item if enabled
        if UserDefaults.standard.bool(forKey: "ShowMenuBar") {
            createStatusItem()
        }
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "triangle.inset.filled", accessibilityDescription: "Prism")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked)
            button.target = self
        }
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusItemClicked() {
        QuickAIManager.shared.toggle()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        // Intercept quit action: instead of quitting, switch to accessory mode
        // This removes the app from the Dock but keeps it running for Quick AI hotkeys

        // Hide all windows
        for window in NSApp.windows {
            window.orderOut(nil)
        }

        // Switch to accessory mode (removes from Dock)
        NSApp.setActivationPolicy(.accessory)

        // Cancel the termination
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources to prevent crashes during shutdown
        ExtensionServer.shared.stop()
        if UserDefaults.standard.bool(forKey: "EnableAIAutocomplete") {
            AutocompleteManager.shared.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If Quick AI or Web Overlay is open, we don't want to force the main window to open
        if let panel = QuickAIManager.shared.panel, panel.isVisible {
            return
        }
        if let panel = WebOverlayManager.shared.panel, panel.isVisible {
            return
        }

        showOrCreateMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        showOrCreateMainWindow()
        return false
    }

    private func showOrCreateMainWindow() {
        // Restore regular activation policy so the app appears in the Dock
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Find any main window and show it
        for window in NSApp.windows {
            if !(window is QuickAIPanel) && !(window is WebOverlayPanel) && !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
}
