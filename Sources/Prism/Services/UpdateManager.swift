import Foundation
import SwiftUI

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let owner = "gl-aarav"
    private let repo = "PrismApp"
    private let appZipName = "Prism.zip"
    private let chromeZipName = "Chrome.zip"
    private let safariZipName = "Safari.zip"
    private let browserAutomationZipName = "BrowserAutomation.zip"
    private let browserAutomationVersionFileName = "version.txt"

    @Published var updateAvailable = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    @Published var releaseURL: URL? = nil
    @Published var appDownloadURL: URL? = nil
    @Published var chromeZipDownloadURL: URL? = nil
    @Published var safariZipDownloadURL: URL? = nil
    @Published var isPreRelease = false
    @Published var showUpdateOverlay = false

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedFileURL: URL? = nil
    @Published var errorMessage: String? = nil

    @Published var isDownloadingChrome = false
    @Published var chromeDownloadProgress: Double = 0
    @Published var chromeExtensionUpdated = false
    @Published var chromeErrorMessage: String? = nil
    @Published var latestChromeVersion: String = ""
    @Published var chromeUpdateAvailable = false

    @Published var isDownloadingSafari = false
    @Published var safariDownloadProgress: Double = 0
    @Published var safariExtensionUpdated = false
    @Published var safariErrorMessage: String? = nil
    @Published var latestSafariVersion: String = ""
    @Published var safariUpdateAvailable = false

    @Published var isDownloadingBrowserAutomation = false
    @Published var browserAutomationDownloadProgress: Double = 0
    @Published var browserAutomationUpdated = false
    @Published var browserAutomationErrorMessage: String? = nil
    @Published var latestBrowserAutomationVersion: String = ""
    @Published var browserAutomationUpdateAvailable = false
    @Published var browserAutomationZipDownloadURL: URL? = nil

    var enablePreRelease: Bool {
        UserDefaults.standard.bool(forKey: "EnablePreReleaseUpdates")
    }
    @AppStorage("ChromeExtensionPath") var chromeExtensionPath: String = ""
    @AppStorage("SafariExtensionPath") var safariExtensionPath: String = ""

    private var downloadTask: URLSessionDownloadTask? = nil
    private var chromeDownloadTask: URLSessionDownloadTask? = nil
    private var safariDownloadTask: URLSessionDownloadTask? = nil
    private var browserAutomationDownloadTask: URLSessionDownloadTask? = nil

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        updateAvailable = false

        defer { isChecking = false }

        do {
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
            else {
                errorMessage = "Failed to fetch releases."
                return
            }

            guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
                errorMessage = "Could not parse release data."
                return
            }

            let candidates =
                enablePreRelease
                ? releases
                : releases.filter { !$0.prerelease }

            guard let latest = candidates.first else {
                errorMessage = "No releases found."
                return
            }

            let remoteVersion = latest.tag_name.trimmingCharacters(
                in: CharacterSet(charactersIn: "vV"))

            if compareVersions(remoteVersion, isNewerThan: currentVersion) {
                latestVersion = remoteVersion
                releaseNotes = latest.body ?? ""
                releaseURL = URL(string: latest.html_url)
                isPreRelease = latest.prerelease

                if let zipAsset = latest.assets.first(where: { $0.name == appZipName }) {
                    appDownloadURL = URL(string: zipAsset.browser_download_url)
                } else {
                    appDownloadURL = nil
                }

                updateAvailable = true
            }

            // Check Chrome extension version independently.
            // Parse from release notes tag (Chrome-Version), never from the app release tag.
            let chromeCandidates = enablePreRelease ? releases : releases.filter { !$0.prerelease }
            if let chromeInfo = latestExtensionInfo(
                in: chromeCandidates, assetName: chromeZipName, marker: "Chrome-Version")
            {
                chromeZipDownloadURL = chromeInfo.downloadURL
                latestChromeVersion = chromeInfo.version
            } else {
                chromeZipDownloadURL = nil
                latestChromeVersion = ""
            }

            // Compare against installed Chrome extension version
            if !latestChromeVersion.isEmpty, !chromeExtensionPath.isEmpty {
                let installedVersion = readInstalledChromeVersion()
                if !installedVersion.isEmpty {
                    chromeUpdateAvailable = compareVersions(
                        latestChromeVersion, isNewerThan: installedVersion)
                } else {
                    // No manifest.json found — assume update is available
                    chromeUpdateAvailable = true
                }
            } else {
                chromeUpdateAvailable = false
            }

            // Check Safari extension version independently.
            // Parse from release notes tag (Safari-Version), never from the app release tag.
            let safariCandidates = enablePreRelease ? releases : releases.filter { !$0.prerelease }
            if let safariInfo = latestExtensionInfo(
                in: safariCandidates, assetName: safariZipName, marker: "Safari-Version")
            {
                safariZipDownloadURL = safariInfo.downloadURL
                latestSafariVersion = safariInfo.version
            } else {
                safariZipDownloadURL = nil
                latestSafariVersion = ""
            }

            // Compare against installed Safari extension version
            if !latestSafariVersion.isEmpty, !safariExtensionPath.isEmpty {
                let installedVersion = readInstalledSafariVersion()
                if !installedVersion.isEmpty {
                    safariUpdateAvailable = compareVersions(
                        latestSafariVersion, isNewerThan: installedVersion)
                } else {
                    // No manifest.json found — assume update is available
                    safariUpdateAvailable = true
                }
            } else {
                safariUpdateAvailable = false
            }

            // Check Browser Automation version independently.
            if let browserAutomationInfo = latestExtensionInfo(
                in: candidates,
                assetName: browserAutomationZipName,
                marker: "browser-automation")
            {
                browserAutomationZipDownloadURL = browserAutomationInfo.downloadURL
                latestBrowserAutomationVersion = browserAutomationInfo.version
            } else {
                browserAutomationZipDownloadURL = nil
                latestBrowserAutomationVersion = ""
            }

            if !latestBrowserAutomationVersion.isEmpty {
                let installedVersion = readInstalledBrowserAutomationVersion()
                if installedVersion.isEmpty {
                    browserAutomationUpdateAvailable = true
                } else {
                    browserAutomationUpdateAvailable = compareVersions(
                        latestBrowserAutomationVersion, isNewerThan: installedVersion)
                }
            } else {
                browserAutomationUpdateAvailable = false
            }
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
        }
    }

    /// Reads the version from the installed Chrome extension's manifest.json
    private func readInstalledChromeVersion() -> String {
        guard !chromeExtensionPath.isEmpty else { return "" }
        let manifestURL = URL(fileURLWithPath: chromeExtensionPath).appendingPathComponent(
            "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = json["version"] as? String
        else { return "" }
        return version
    }

    /// Reads the version from the installed Safari extension's manifest.json
    private func readInstalledSafariVersion() -> String {
        guard !safariExtensionPath.isEmpty else { return "" }
        let manifestURL = URL(fileURLWithPath: safariExtensionPath).appendingPathComponent(
            "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = json["version"] as? String
        else { return "" }
        return version
    }

    func browserAutomationInstallationDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Prism/BrowserAutomation", isDirectory: true)
    }

    private func readInstalledBrowserAutomationVersion() -> String {
        let versionURL = browserAutomationInstallationDirectory()
            .appendingPathComponent(browserAutomationVersionFileName)
        guard let version = try? String(contentsOf: versionURL, encoding: .utf8) else { return "" }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func downloadUpdate() {
        guard let url = appDownloadURL else {
            errorMessage = "No download URL available."
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadedFileURL = nil
        errorMessage = nil

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        } onComplete: { [weak self] localURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isDownloading = false
                if let error {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    return
                }
                guard let localURL else {
                    self.errorMessage = "Download failed."
                    return
                }

                // Move to Downloads folder
                let downloads = FileManager.default.urls(
                    for: .downloadsDirectory, in: .userDomainMask
                ).first!
                let dest = downloads.appendingPathComponent(self.appZipName)

                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: localURL, to: dest)
                    self.downloadedFileURL = dest
                } catch {
                    self.errorMessage = "Could not save file: \(error.localizedDescription)"
                }
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    func installAndRestart() {
        guard let zipPath = downloadedFileURL else { return }

        let appBundlePath = Bundle.main.bundlePath
        let zipFile = zipPath.path

        // Script: wait for app to quit, extract ZIP, copy new .app, relaunch
        let script = """
            #!/bin/bash
            sleep 2
            TEMP_DIR=$(mktemp -d)
            ditto -xk "\(zipFile)" "$TEMP_DIR"
            APP_SRC=$(find "$TEMP_DIR" -maxdepth 2 -name "*.app" -type d | head -1)
            if [ -z "$APP_SRC" ]; then rm -rf "$TEMP_DIR"; exit 1; fi
            rm -rf "\(appBundlePath)"
            cp -R "$APP_SRC" "\(appBundlePath)"
            rm -rf "$TEMP_DIR"
            open "\(appBundlePath)"
            """

        let tmpScript = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prism_update.sh")
        try? script.write(to: tmpScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmpScript.path)

        // Launch script fully detached so it survives app exit
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup \(tmpScript.path) > /dev/null 2>&1 &"]
        try? process.run()
        process.waitUntilExit()

        // Force quit immediately so the script can replace the app bundle
        exit(0)
    }

    // MARK: - Chrome Extension Update

    func downloadChromeExtension() {
        guard let url = chromeZipDownloadURL else {
            chromeErrorMessage = "No Chrome.zip in this release."
            return
        }
        guard !chromeExtensionPath.isEmpty else {
            chromeErrorMessage = "Set the Chrome extension folder in Settings first."
            return
        }

        isDownloadingChrome = true
        chromeDownloadProgress = 0
        chromeExtensionUpdated = false
        chromeErrorMessage = nil

        let extensionPath = chromeExtensionPath

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.chromeDownloadProgress = progress
            }
        } onComplete: { [weak self] localURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isDownloadingChrome = false
                if let error {
                    self.chromeErrorMessage = "Download failed: \(error.localizedDescription)"
                    return
                }
                guard let localURL else {
                    self.chromeErrorMessage = "Download failed."
                    return
                }

                // Extract zip to the chrome extension folder
                do {
                    try self.extractZip(from: localURL, to: URL(fileURLWithPath: extensionPath))
                    self.chromeExtensionUpdated = true
                } catch {
                    self.chromeErrorMessage = "Failed to extract: \(error.localizedDescription)"
                }

                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        chromeDownloadTask = session.downloadTask(with: url)
        chromeDownloadTask?.resume()
    }

    func cancelChromeDownload() {
        chromeDownloadTask?.cancel()
        chromeDownloadTask = nil
        isDownloadingChrome = false
        chromeDownloadProgress = 0
    }

    // MARK: - Safari Extension Update

    func downloadSafariExtension() {
        guard let url = safariZipDownloadURL else {
            safariErrorMessage = "No Safari.zip in this release."
            return
        }
        guard !safariExtensionPath.isEmpty else {
            safariErrorMessage = "Set the Safari extension folder in Settings first."
            return
        }

        isDownloadingSafari = true
        safariDownloadProgress = 0
        safariExtensionUpdated = false
        safariErrorMessage = nil

        let extensionPath = safariExtensionPath

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.safariDownloadProgress = progress
            }
        } onComplete: { [weak self] localURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isDownloadingSafari = false
                if let error {
                    self.safariErrorMessage = "Download failed: \(error.localizedDescription)"
                    return
                }
                guard let localURL else {
                    self.safariErrorMessage = "Download failed."
                    return
                }

                // Extract zip to the safari extension folder
                do {
                    try self.extractZip(from: localURL, to: URL(fileURLWithPath: extensionPath))
                    self.safariExtensionUpdated = true
                } catch {
                    self.safariErrorMessage = "Failed to extract: \(error.localizedDescription)"
                }

                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        safariDownloadTask = session.downloadTask(with: url)
        safariDownloadTask?.resume()
    }

    func cancelSafariDownload() {
        safariDownloadTask?.cancel()
        safariDownloadTask = nil
        isDownloadingSafari = false
        safariDownloadProgress = 0
    }

    // MARK: - Browser Automation Update

    func downloadBrowserAutomation() {
        guard let url = browserAutomationZipDownloadURL else {
            browserAutomationErrorMessage = "No BrowserAutomation.zip in this release."
            return
        }

        isDownloadingBrowserAutomation = true
        browserAutomationDownloadProgress = 0
        browserAutomationUpdated = false
        browserAutomationErrorMessage = nil

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.browserAutomationDownloadProgress = progress
            }
        } onComplete: { [weak self] localURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isDownloadingBrowserAutomation = false
                if let error {
                    self.browserAutomationErrorMessage =
                        "Download failed: \(error.localizedDescription)"
                    return
                }
                guard let localURL else {
                    self.browserAutomationErrorMessage = "Download failed."
                    return
                }

                let installDirectory = self.browserAutomationInstallationDirectory()
                do {
                    try FileManager.default.createDirectory(
                        at: installDirectory,
                        withIntermediateDirectories: true,
                        attributes: nil)
                    try self.extractZip(from: localURL, to: installDirectory)
                    let versionURL = installDirectory.appendingPathComponent(
                        self.browserAutomationVersionFileName)
                    try self.latestBrowserAutomationVersion.write(
                        to: versionURL, atomically: true, encoding: .utf8)
                    self.browserAutomationUpdated = true
                    self.browserAutomationUpdateAvailable = false
                } catch {
                    self.browserAutomationErrorMessage =
                        "Failed to install: \(error.localizedDescription)"
                }

                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        browserAutomationDownloadTask = session.downloadTask(with: url)
        browserAutomationDownloadTask?.resume()
    }

    func cancelBrowserAutomationDownload() {
        browserAutomationDownloadTask?.cancel()
        browserAutomationDownloadTask = nil
        isDownloadingBrowserAutomation = false
        browserAutomationDownloadProgress = 0
    }

    private func extractZip(from zipURL: URL, to destDir: URL) throws {
        let fm = FileManager.default

        // Create a temp directory for extraction
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? fm.removeItem(at: tmpDir) }

        // Use ditto to unzip (built-in on macOS, handles zip reliably)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tmpDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "UpdateManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ditto extraction failed"])
        }

        // Find extracted contents - could be a top-level folder or loose files
        let extracted = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)

        // Determine source: if there's exactly one folder (e.g. "Chrome/"), use its contents
        var sourceDir = tmpDir
        if extracted.count == 1, let single = extracted.first {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: single.path, isDirectory: &isDir), isDir.boolValue {
                sourceDir = single
            }
        }

        // Copy each item into the destination, replacing existing files
        let items = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
        for item in items {
            let target = destDir.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: item, to: target)
        }
    }

    func dismiss() {
        showUpdateOverlay = false
        updateAvailable = false
        latestVersion = ""
        releaseNotes = ""
        releaseURL = nil
        appDownloadURL = nil
        chromeZipDownloadURL = nil
        safariZipDownloadURL = nil
        downloadedFileURL = nil
        errorMessage = nil
        isDownloading = false
        downloadProgress = 0
        chromeExtensionUpdated = false
        chromeErrorMessage = nil
        latestChromeVersion = ""
        chromeUpdateAvailable = false
        isDownloadingChrome = false
        chromeDownloadProgress = 0
        safariExtensionUpdated = false
        safariErrorMessage = nil
        latestSafariVersion = ""
        safariUpdateAvailable = false
        isDownloadingSafari = false
        safariDownloadProgress = 0
        browserAutomationUpdated = false
        browserAutomationErrorMessage = nil
        latestBrowserAutomationVersion = ""
        browserAutomationUpdateAvailable = false
        browserAutomationZipDownloadURL = nil
        isDownloadingBrowserAutomation = false
        browserAutomationDownloadProgress = 0
    }

    func showOverlay() {
        showUpdateOverlay = true
    }

    func hideOverlay() {
        showUpdateOverlay = false
    }

    private func latestExtensionInfo(
        in releases: [GitHubRelease], assetName: String, marker: String
    ) -> (version: String, downloadURL: URL?)? {
        for release in releases {
            guard let asset = release.assets.first(where: { $0.name == assetName }) else {
                continue
            }
            let url = URL(string: asset.browser_download_url)

            guard let body = release.body,
                let version = extractVersionTag(named: marker, from: body)
            else {
                continue
            }

            return (version, url)
        }

        return nil
    }

    private func extractVersionTag(named marker: String, from text: String) -> String? {
        // Supports variants like:
        // Chrome-Version: 12.4.0
        // Chrome-Version 12.4.0
        // Chrome-Version = v12.4.0
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        let pattern = "(?im)\\b\(escapedMarker)\\b\\s*[:=-]?\\s*(v?[0-9][0-9A-Za-z.-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }

        return text[valueRange]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r,.;"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    // MARK: - Version Comparison

    func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(remoteParts.count, localParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - GitHub API Models

struct GitHubRelease: Codable {
    let tag_name: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let html_url: String
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let browser_download_url: String
    let size: Int
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to temp so it persists after this callback
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".dmg")
        do {
            try FileManager.default.copyItem(at: location, to: tmp)
            onComplete(tmp, nil)
        } catch {
            onComplete(nil, error)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error {
            onComplete(nil, error)
        }
    }
}
