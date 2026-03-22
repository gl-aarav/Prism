import AppKit
import SwiftUI
import WebKit

struct BrowserAutomationView: View {
    @StateObject private var manager = BrowserAutomationManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("BrowserAutomationPath") private var browserAutomationPath: String = ""

    private var tintStart: Color {
        (appTheme.colors.first ?? .blue).opacity(0.15)
    }

    private var tintEnd: Color {
        (appTheme.colors.last ?? .green).opacity(0.12)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [tintStart, tintEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .padding(12)

            VStack(spacing: 18) {
                header

                if manager.serverIsRunning {
                    BrowserAutomationWebView(url: manager.appURL)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    offlineCard
                }
            }
            .padding(26)
        }
        .task {
            await manager.refreshStatus()
            if !manager.hasLaunchableFiles {
                await updateManager.checkForUpdates()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Spacer()

            HStack(spacing: 10) {
                statusPill

                if manager.serverIsRunning {
                    Button("Stop") {
                        manager.stopServer()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                }

                Button("Open in Browser") {
                    manager.openInBrowser()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())

                if !manager.serverIsRunning {
                    Button {
                        manager.startServerIfNeeded()
                    } label: {
                        Label(manager.isStarting ? "Starting…" : "Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [
                                appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .disabled(manager.isStarting)
                }
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(manager.serverIsRunning ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(manager.serverIsRunning ? "Live" : "Offline")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var offlineCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    manager.hasLaunchableFiles
                        ? "Run the local automation server"
                        : "Browser Automation files not installed"
                )
                .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(
                    manager.hasLaunchableFiles
                        ? "This native tool wraps the existing website version and launches it locally on port 9090."
                        : "Open the release on GitHub, choose the BrowserAutomation folder on disk, and Prism will save that path in settings."
                )
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                actionBadge(title: "Server", value: "localhost:9090")
                actionBadge(
                    title: "Status",
                    value: manager.hasLaunchableFiles
                        ? (manager.isStarting ? "Starting" : "Stopped")
                        : "Files Missing")
                let installedVersion = updateManager.installedBrowserAutomationVersion()
                actionBadge(
                    title: "Version",
                    value: installedVersion.isEmpty
                        ? (updateManager.latestBrowserAutomationVersion.isEmpty
                            ? "Unknown"
                            : updateManager.latestBrowserAutomationVersion)
                        : installedVersion)
            }

            if !browserAutomationPath.isEmpty {
                actionBadge(
                    title: "Path",
                    value: URL(fileURLWithPath: browserAutomationPath).lastPathComponent)
            }

            HStack(spacing: 12) {
                if manager.hasLaunchableFiles {
                    Button {
                        manager.startServerIfNeeded()
                    } label: {
                        Label(
                            manager.isStarting ? "Starting…" : "Run Browser Automation",
                            systemImage: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .disabled(manager.isStarting)
                } else {
                    Button {
                        manager.openOnGitHub()
                    } label: {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                }

                if !manager.hasLaunchableFiles {
                    Button {
                        chooseBrowserAutomationFolder()
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                }

                Button("Open in Browser") {
                    manager.openInBrowser()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
            }

            if let launchError = manager.launchError {
                Text(launchError)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
            }

            if let lastLogLine = manager.lastLogLine, manager.launchError == nil {
                Text(lastLogLine)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if !browserAutomationPath.isEmpty && !manager.hasLaunchableFiles {
                Text(
                    "Saved path does not contain `server.js`. Choose the BrowserAutomation folder itself."
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func actionBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chooseBrowserAutomationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the BrowserAutomation folder containing server.js"
        if panel.runModal() == .OK, let url = panel.url {
            browserAutomationPath = url.path
            manager.setBrowserAutomationPath(url.path)
        }
    }
}

private struct BrowserAutomationWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
