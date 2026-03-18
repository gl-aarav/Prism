import SwiftUI
@main
struct TestApp: App {
    var body: some Scene {
        Settings {
            Text("Settings")
        }
        .windowStyle(.hiddenTitleBar)
        // .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
