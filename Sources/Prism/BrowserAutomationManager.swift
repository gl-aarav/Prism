import AppKit
import Foundation
import SwiftUI

@MainActor
final class BrowserAutomationManager: ObservableObject {
    static let shared = BrowserAutomationManager()

    struct Status: Decodable {
        let engine: String?
        let isOpen: Bool
        let isAgentRunning: Bool
    }

    @Published private(set) var serverIsRunning = false
    @Published private(set) var browserIsOpen = false
    @Published private(set) var isAgentRunning = false
    @Published private(set) var activeEngine: String?
    @Published private(set) var isStarting = false
    @Published var launchError: String?
    @Published private(set) var lastLogLine: String?
    @AppStorage("BrowserAutomationPath") private var browserAutomationPath: String = ""

    private let serverURL = URL(string: "http://127.0.0.1:9090")!
    private let githubURL = URL(string: "https://github.com/gl-aarav/PrismApp/releases")!
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var outputPipe: Pipe?
    private var startupTask: Task<Void, Never>?

    private init() {
        startPolling()
    }

    var appURL: URL {
        serverURL
    }

    var hasLaunchableFiles: Bool {
        browserAutomationDirectory() != nil
    }

    func openInBrowser() {
        NSWorkspace.shared.open(appURL)
    }

    func openOnGitHub() {
        NSWorkspace.shared.open(githubURL)
    }

    func stopServer() {
        startupTask?.cancel()
        process?.terminate()
        process = nil
        isStarting = false
    }

    func setBrowserAutomationPath(_ path: String) {
        browserAutomationPath = path
    }

    func startServerIfNeeded() {
        guard !serverIsRunning, !isStarting else { return }
        guard let workingDirectory = browserAutomationDirectory() else {
            launchError = "BrowserAutomation folder not found."
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec node server.js"]
        process.currentDirectoryURL = workingDirectory

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        self.outputPipe = outputPipe
        bindOutputPipe(outputPipe)

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isStarting = false
                self?.process = nil
            }
        }

        do {
            isStarting = true
            launchError = nil
            lastLogLine = nil
            try process.run()
            self.process = process

            startupTask?.cancel()
            startupTask = Task {
                for attempt in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(300))
                    await refreshStatus()
                    if serverIsRunning {
                        isStarting = false
                        return
                    }
                    if attempt == 19 {
                        isStarting = false
                        launchError = lastLogLine ?? "Browser Automation did not start."
                    }
                }
            }
        } catch {
            isStarting = false
            launchError = error.localizedDescription
        }
    }

    func refreshStatus() async {
        do {
            let (data, _) = try await URLSession.shared.data(
                from: serverURL.appendingPathComponent("api/status"))
            let status = try JSONDecoder().decode(Status.self, from: data)
            serverIsRunning = true
            browserIsOpen = status.isOpen
            isAgentRunning = status.isAgentRunning
            activeEngine = status.engine
            launchError = nil
        } catch {
            serverIsRunning = false
            browserIsOpen = false
            isAgentRunning = false
            activeEngine = nil
        }
    }

    private func bindOutputPipe(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines =
                text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let last = lines.last else { return }
            Task { @MainActor in
                self?.lastLogLine = last
                if last.localizedCaseInsensitiveContains("error")
                    || last.localizedCaseInsensitiveContains("cannot")
                    || last.localizedCaseInsensitiveContains("not permitted")
                {
                    self?.launchError = last
                }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func browserAutomationDirectory() -> URL? {
        let fm = FileManager.default
        if !browserAutomationPath.isEmpty {
            let savedDirectory = URL(fileURLWithPath: browserAutomationPath, isDirectory: true)
            if fm.fileExists(atPath: savedDirectory.appendingPathComponent("server.js").path) {
                return savedDirectory
            }
        }

        let internalDirectory = UpdateManager.shared.browserAutomationInstallationDirectory()
        if fm.fileExists(atPath: internalDirectory.appendingPathComponent("server.js").path) {
            return internalDirectory
        }

        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]

        for base in candidates {
            let direct = base.appendingPathComponent("BrowserAutomation", isDirectory: true)
            if fm.fileExists(atPath: direct.appendingPathComponent("server.js").path) {
                return direct
            }

            var current = base
            for _ in 0..<4 {
                let nested = current.appendingPathComponent("BrowserAutomation", isDirectory: true)
                if fm.fileExists(atPath: nested.appendingPathComponent("server.js").path) {
                    return nested
                }
                current.deleteLastPathComponent()
            }
        }

        return nil
    }
}
