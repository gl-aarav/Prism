import SwiftUI

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("ShowMenuBar") private var showMenuBar = true

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

        MenuBarExtra(isInserted: $showMenuBar) {
            QuickChatView()
        } label: {
            PrismMenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

class AppState: ObservableObject {
    static let shared = AppState()
    var hasShownSplash: Bool = false

    private init() {}
}

struct PrismMenuBarIcon: View {
    @State private var isAnimating = false
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "triangle")
                .font(.system(size: 14))
                .foregroundColor(appTheme.colors.first)
                .opacity(0.8)
                .overlay(
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(isAnimating ? 0.6 : 0.0)
                        .blur(radius: 2)
                )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: ["ShowMenuBar": true, "EnableQuickAI": true])
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

        HotKeyManager.shared.onTrigger = {
            if UserDefaults.standard.bool(forKey: "EnableQuickAI") {
                QuickAIManager.shared.toggle()
            }
        }
        HotKeyManager.shared.register()

        IconManager.shared.updateIcon()

        print("Prism has launched!")
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
