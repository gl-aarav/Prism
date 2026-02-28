import Foundation
import SwiftUI

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let owner = "gl-aarav"
    private let repo = "PrismApp"
    private let dmgName = "Prism_Installer.dmg"
    private let chromeZipName = "Chrome.zip"

    @Published var updateAvailable = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    @Published var releaseURL: URL? = nil
    @Published var dmgDownloadURL: URL? = nil
    @Published var chromeZipDownloadURL: URL? = nil
    @Published var isPreRelease = false

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

    @AppStorage("EnablePreReleaseUpdates") var enablePreRelease: Bool = false
    @AppStorage("ChromeExtensionPath") var chromeExtensionPath: String = ""

    private var downloadTask: URLSessionDownloadTask? = nil
    private var chromeDownloadTask: URLSessionDownloadTask? = nil

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

                if let dmgAsset = latest.assets.first(where: { $0.name == dmgName }) {
                    dmgDownloadURL = URL(string: dmgAsset.browser_download_url)
                } else {
                    dmgDownloadURL = nil
                }

                updateAvailable = true
            }

            // Check Chrome extension version independently
            // Look through all releases for the latest one that has Chrome.zip
            let chromeCandidates = enablePreRelease ? releases : releases.filter { !$0.prerelease }
            for release in chromeCandidates {
                if let chromeAsset = release.assets.first(where: { $0.name == chromeZipName }) {
                    chromeZipDownloadURL = URL(string: chromeAsset.browser_download_url)
                    // Parse chrome version from release body: "Chrome-Version: X.Y.Z"
                    if let body = release.body,
                        let range = body.range(
                            of: #"Chrome-Version:\s*(\S+)"#, options: .regularExpression)
                    {
                        let match = body[range]
                        let ver =
                            match.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
                            ?? ""
                        latestChromeVersion = ver
                    } else {
                        // Fallback: use release tag as chrome version
                        let tag = release.tag_name.trimmingCharacters(
                            in: CharacterSet(charactersIn: "vV"))
                        latestChromeVersion = tag
                    }
                    break
                }
            }
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
        }
    }

    func downloadUpdate() {
        guard let url = dmgDownloadURL else {
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
                let dest = downloads.appendingPathComponent(self.dmgName)

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
        guard let dmgPath = downloadedFileURL else { return }

        let appBundlePath = Bundle.main.bundlePath
        let dmgFile = dmgPath.path

        // Script: mount DMG, copy new .app over current, unmount, relaunch
        let script = """
            #!/bin/bash
            sleep 1
            MOUNT_OUTPUT=$(hdiutil attach "\(dmgFile)" -nobrowse -noverify 2>&1)
            MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/[^"]*' | head -1)
            if [ -z "$MOUNT_POINT" ]; then exit 1; fi
            APP_SRC=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" | head -1)
            if [ -z "$APP_SRC" ]; then hdiutil detach "$MOUNT_POINT" -quiet; exit 1; fi
            rm -rf "\(appBundlePath)"
            cp -R "$APP_SRC" "\(appBundlePath)"
            hdiutil detach "$MOUNT_POINT" -quiet
            open "\(appBundlePath)"
            """

        let tmpScript = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prism_update.sh")
        try? script.write(to: tmpScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmpScript.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tmpScript.path]
        try? process.run()

        // Quit current app so the script can replace it
        NSApplication.shared.terminate(nil)
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

    private func extractZip(from zipURL: URL, to destDir: URL) throws {
        let fm = FileManager.default

        // Create a temp directory for extraction
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
        updateAvailable = false
        latestVersion = ""
        releaseNotes = ""
        releaseURL = nil
        dmgDownloadURL = nil
        chromeZipDownloadURL = nil
        downloadedFileURL = nil
        errorMessage = nil
        isDownloading = false
        downloadProgress = 0
        chromeExtensionUpdated = false
        chromeErrorMessage = nil
        isDownloadingChrome = false
        chromeDownloadProgress = 0
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
