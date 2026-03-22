import SwiftUI
import WebKit

struct BrowserAutomationView: View {
    @StateObject private var manager = BrowserAutomationManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

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
            VStack(alignment: .leading, spacing: 6) {
                Text("Browser Automation")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(subtitleText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                statusPill

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
                            colors: [appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green],
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
                        : "Download Browser Automation files"
                )
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(
                    manager.hasLaunchableFiles
                        ? "This native tool wraps the existing website version and launches it locally on port 9090."
                        : "The local automation bundle is missing. Download BrowserAutomation.zip into Prism's internal files to enable the tool."
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
                actionBadge(
                    title: "Version",
                    value: updateManager.latestBrowserAutomationVersion.isEmpty
                        ? "Unknown" : updateManager.latestBrowserAutomationVersion)
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
                            colors: [appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .disabled(manager.isStarting)
                } else {
                    Button {
                        Task {
                            if updateManager.browserAutomationZipDownloadURL == nil {
                                await updateManager.checkForUpdates()
                            }
                            updateManager.downloadBrowserAutomation()
                        }
                    } label: {
                        Label(
                            updateManager.isDownloadingBrowserAutomation
                                ? "Downloading…" : "Download Files",
                            systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [appTheme.colors.first ?? .blue, appTheme.colors.last ?? .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .disabled(updateManager.isDownloadingBrowserAutomation)
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

            if updateManager.isDownloadingBrowserAutomation {
                Text(
                    "Downloading BrowserAutomation.zip: \(Int(updateManager.browserAutomationDownloadProgress * 100))%"
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if let installError = updateManager.browserAutomationErrorMessage {
                Text(installError)
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

    private var subtitleText: String {
        if !manager.serverIsRunning {
            return "Native shell for the local Prism automation site"
        }
        if manager.browserIsOpen {
            let engine = manager.activeEngine?.capitalized ?? "Browser"
            return manager.isAgentRunning ? "\(engine) agent is active" : "\(engine) browser is ready"
        }
        return "Server is ready. Launch a browser from the control surface."
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
