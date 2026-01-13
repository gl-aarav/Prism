import SwiftUI

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("ShowMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppState.shared) // If needed or just environmentObject(ChatManager.shared)
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

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "triangle")
                .font(.system(size: 14))
                .opacity(0.8)
                .overlay(
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 14))
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
    private var appearanceObservation: NSKeyValueObservation?
    private var lightIcon: NSImage?
    private var darkIcon: NSImage?

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

        loadIcons()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) {
            [weak self] app, _ in
            self?.updateAppIcon(for: app.effectiveAppearance)
        }

        print("Prism has launched!")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appearanceObservation = nil
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

    private func loadIcons() {
        lightIcon = loadIcon(named: "AppIconLight") ?? loadIcon(named: "AppIcon")
        darkIcon = loadIcon(named: "AppIconDark") ?? lightIcon
    }

    private func loadIcon(named: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: named, withExtension: "png"),
            let base = NSImage(contentsOf: url)
        else { return nil }
        return roundedIcon(from: base)
    }

    func refreshAppIcon() {
        // Dispatch async to allow activation policy changes to settle before updating the dock icon
        DispatchQueue.main.async { [weak self] in
            let appearance = NSApp.effectiveAppearance
            self?.updateAppIcon(for: appearance)
        }
    }

    private func roundedIcon(from image: NSImage) -> NSImage {
        let size = image.size
        // Slightly inset and round more to match native macOS icon silhouette
        let inset = min(size.width, size.height) * 0.095  // slightly larger glyph (~1px more)
        let imageRect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let radius = min(imageRect.width, imageRect.height) * 0.25

        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        // Shadow backdrop to mimic native icon lift
        let shadow = NSShadow()
        shadow.shadowBlurRadius = min(size.width, size.height) * 0.11
        shadow.shadowOffset = NSSize(width: 0, height: -size.height * 0.018)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()

        let shadowPath = NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.55).setFill()
        shadowPath.fill()

        // Clear shadow for subsequent drawing
        NSShadow().set()

        // Clip to rounded rect and draw scaled image
        shadowPath.addClip()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        newImage.unlockFocus()
        newImage.isTemplate = false
        return newImage
    }

    private func updateAppIcon(for appearance: NSAppearance) {
        // Fallback to checking system preference directly
        let isSystemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])

        if isSystemDark || match == .darkAqua {
            if let icon = darkIcon {
                NSApp.applicationIconImage = icon
                return
            }
        }

        // Only set light icon if we are NOT in dark mode
        if let icon = lightIcon {
            NSApp.applicationIconImage = icon
        }
    }
}
