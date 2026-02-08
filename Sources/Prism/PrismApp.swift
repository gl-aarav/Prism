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
            }
        }

        Settings {
            SettingsView()
                .environmentObject(ChatManager.shared)
                .frame(minWidth: 500, minHeight: 400)
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

    override init() {
        super.init()
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: [
            "ShowMenuBar": true,
            "EnableQuickAI": true,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app is a regular app (shows in Dock, has UI)
        NSApp.setActivationPolicy(.regular)

        // Bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Force main window to appear if needed
        DispatchQueue.main.async {
            // Find the main window (not the Quick AI panel)
            if let window = NSApp.windows.first(where: { !($0 is QuickAIPanel) }) {
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.makeKeyAndOrderFront(nil)
                window.center()
            }
        }

        QuickAIManager.shared.setup()

        // Setup menu bar status item
        setupStatusItem()

        HotKeyManager.shared.onTrigger = {
            if UserDefaults.standard.bool(forKey: "EnableQuickAI") {
                QuickAIManager.shared.toggle()
            }
        }
        HotKeyManager.shared.register()

        IconManager.shared.updateIcon()

        print("Prism has launched!")
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

    func applicationWillTerminate(_ notification: Notification) {

    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If Quick AI is open, we don't want to force the main window to open
        if let panel = QuickAIManager.shared.panel, panel.isVisible {
            return
        }

        // If no windows are visible (excluding Quick AI), show the main window
        // This handles Cmd+Tab or other activation methods where applicationShouldHandleReopen might not be called
        let visibleWindows = NSApp.windows.filter { $0.isVisible && !($0 is QuickAIPanel) }
        if visibleWindows.isEmpty {
            for window in NSApp.windows {
                if !(window is QuickAIPanel) {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        // If Quick AI is open, we don't want to force the main window to open
        if let panel = QuickAIManager.shared.panel, panel.isVisible {
            return true
        }

        if !flag {
            // If no windows are visible (excluding Quick AI which might be hidden), show the main window
            for window in NSApp.windows {
                if !(window is QuickAIPanel) {
                    window.makeKeyAndOrderFront(nil)
                    return false
                }
            }
        }
        return true
    }
}
