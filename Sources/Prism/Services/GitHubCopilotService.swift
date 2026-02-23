import AppKit
import Foundation
import SwiftUI

// MARK: - GitHub Copilot OAuth + Chat Service

class GitHubCopilotService: ObservableObject {
    static let shared = GitHubCopilotService()

    @Published var isAuthenticated: Bool = false
    @Published var userName: String = ""
    @Published var avatarURL: String = ""
    @Published var isSigningIn: Bool = false
    @Published var deviceCode: String? = nil
    @Published var verificationURL: URL? = nil
    @Published var errorMessage: String? = nil

    private let clientId = "Iv1.b507a08c87ecfe98"  // GitHub Copilot's public client ID for device flow
    private let session: URLSession

    // Token storage keys
    private let tokenKey = "GitHubCopilotToken"
    private let userNameKey = "GitHubCopilotUserName"
    private let avatarKey = "GitHubCopilotAvatar"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        // Restore saved auth state
        if let token = getStoredToken(), !token.isEmpty {
            isAuthenticated = true
            userName = UserDefaults.standard.string(forKey: userNameKey) ?? ""
            avatarURL = UserDefaults.standard.string(forKey: avatarKey) ?? ""
        }
    }

    // MARK: - Token Storage (Keychain)

    func getStoredToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func storeToken(_ token: String) {
        let data = token.data(using: .utf8)!

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: tokenKey,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: tokenKey,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: tokenKey,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - GitHub Device Flow OAuth

    struct DeviceCodeResponse: Codable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    /// Start the device flow. Returns (user_code, verification_uri) for the user.
    func startDeviceFlow() async throws -> DeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["client_id": clientId, "scope": "read:user"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    /// Poll for the access token after user has entered the code.
    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw URLError(.badURL)
        }

        let pollInterval = max(interval, 5)

        while true {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "client_id": clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await session.data(for: request)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let accessToken = json["access_token"] as? String {
                return accessToken
            }

            if let error = json["error"] as? String {
                if error == "authorization_pending" {
                    continue
                } else if error == "slow_down" {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                } else if error == "expired_token" {
                    throw NSError(
                        domain: "GitHubCopilot", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Device code expired. Please try again."
                        ])
                } else if error == "access_denied" {
                    throw NSError(
                        domain: "GitHubCopilot", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Access denied by user."])
                }
            }
        }
    }

    /// Complete signin: store token, fetch user info
    func completeSignIn(token: String) async throws {
        storeToken(token)

        // Fetch user info
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let login = json["login"] as? String ?? ""
            let avatar = json["avatar_url"] as? String ?? ""

            await MainActor.run {
                self.userName = login
                self.avatarURL = avatar
                self.isAuthenticated = true
                UserDefaults.standard.set(login, forKey: self.userNameKey)
                UserDefaults.standard.set(avatar, forKey: self.avatarKey)
            }
        }
    }

    func signOut() {
        deleteToken()
        isAuthenticated = false
        userName = ""
        avatarURL = ""
        UserDefaults.standard.removeObject(forKey: userNameKey)
        UserDefaults.standard.removeObject(forKey: avatarKey)
    }

    /// Convenience: orchestrate the full device flow sign-in from UI
    func startSignIn() {
        isSigningIn = true
        errorMessage = nil
        deviceCode = nil
        verificationURL = nil

        Task {
            do {
                let response = try await startDeviceFlow()
                await MainActor.run {
                    self.deviceCode = response.user_code
                    self.verificationURL = URL(string: response.verification_uri)
                }

                // Open browser for user
                if let url = URL(string: response.verification_uri) {
                    _ = await MainActor.run { NSWorkspace.shared.open(url) }
                }

                // Poll for token
                let token = try await pollForToken(
                    deviceCode: response.device_code, interval: response.interval)
                try await completeSignIn(token: token)

                await MainActor.run {
                    self.isSigningIn = false
                    self.deviceCode = nil
                    self.verificationURL = nil

                    // Auto-create copilot account if needed
                    if !AccountManager.shared.accounts.contains(where: {
                        $0.providerType == "copilot"
                    }) {
                        AccountManager.shared.addAccount(.copilotAccount())
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSigningIn = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Get Copilot Token (exchange GitHub token for Copilot API token)

    private var cachedCopilotToken: String?
    private var copilotTokenExpiry: Date?

    func getCopilotToken() async throws -> String {
        // Return cached if still valid
        if let token = cachedCopilotToken, let expiry = copilotTokenExpiry, Date() < expiry {
            return token
        }

        guard let githubToken = getStoredToken() else {
            throw NSError(
                domain: "GitHubCopilot", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Not signed in to GitHub."])
        }

        guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("PrismApp/1.0", forHTTPHeaderField: "Editor-Version")
        request.addValue("copilot-chat", forHTTPHeaderField: "Editor-Plugin-Version")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 401 {
            await MainActor.run { self.signOut() }
            throw NSError(
                domain: "GitHubCopilot", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "GitHub token expired. Please sign in again."]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["token"] as? String
        else {
            throw NSError(
                domain: "GitHubCopilot", code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to get Copilot token. Ensure you have a GitHub Copilot subscription."
                ])
        }

        cachedCopilotToken = token
        // Token typically valid for ~30 minutes, refresh at 25
        copilotTokenExpiry = Date().addingTimeInterval(25 * 60)

        return token
    }

    // MARK: - Chat Streaming

    func sendMessageStream(
        history: [Message], model: String, systemPrompt: String = ""
    ) -> AsyncThrowingStream<(String, String?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let copilotToken = try await getCopilotToken()

                    guard let url = URL(string: "https://api.githubcopilot.com/chat/completions")
                    else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.addValue("Bearer \(copilotToken)", forHTTPHeaderField: "Authorization")
                    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.addValue("PrismApp/1.0", forHTTPHeaderField: "Editor-Version")
                    request.addValue("copilot-chat", forHTTPHeaderField: "Editor-Plugin-Version")
                    request.addValue(
                        "vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")

                    var messages: [[String: Any]] = []

                    if !systemPrompt.isEmpty {
                        messages.append(["role": "system", "content": systemPrompt])
                    }

                    messages.append(
                        contentsOf: history.map { msg in
                            [
                                "role": msg.isUser ? "user" : "assistant",
                                "content": msg.content,
                            ] as [String: Any]
                        })

                    let body: [String: Any] = [
                        "messages": messages,
                        "model": model,
                        "stream": true,
                        "temperature": 0.1,
                        "top_p": 1,
                        "n": 1,
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (result, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorMsg = ""
                        for try await line in result.lines {
                            errorMsg += line
                        }
                        continuation.finish(
                            throwing: NSError(
                                domain: "GitHubCopilot", code: httpResponse.statusCode,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Copilot API error (\(httpResponse.statusCode)): \(errorMsg)"
                                ]))
                        return
                    }

                    for try await line in result.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }

                        guard let data = dataStr.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            let choices = json["choices"] as? [[String: Any]],
                            let delta = choices.first?["delta"] as? [String: Any]
                        else {
                            continue
                        }

                        let content = delta["content"] as? String ?? ""
                        if !content.isEmpty {
                            continuation.yield((content, nil))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - GitHub Copilot Model Manager

class GitHubCopilotModelManager: ObservableObject {
    static let shared = GitHubCopilotModelManager()

    @Published var availableModels: [String] = [
        // Claude
        "claude-opus-4.6-fast",
        "claude-opus-4.6",
        "claude-sonnet-4",
        "claude-sonnet-4.5",
        "claude-opus-4.5",
        "claude-haiku-4.5",
        // GPT-5 Series
        "gpt-5.2-codex",
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5-mini",
        "gpt-5",
        "gpt-5-codex",
        // GPT-4 Series
        "gpt-4.1",
        "gpt-4.1-2025-04-14",
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4o-2024-11-20",
        "gpt-4o-2024-08-06",
        "gpt-4o-2024-05-13",
        "gpt-4o-mini-2024-07-18",
        "gpt-4-o-preview",
        "gpt-4",
        "gpt-4-0125-preview",
        // GPT-3.5
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-0613",
        // Gemini
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        "gemini-2.5-pro",
        // Grok
        "grok-code-fast-1",
        // OSWE
        "oswe-vscode-prime",
        "oswe-vscode-secondary",
        // Embeddings
        "text-embedding-3-small",
        "text-embedding-3-small-inference",
        "text-embedding-ada-002",
    ]

    static let displayNames: [String: String] = [
        "claude-opus-4.6-fast": "Claude Opus 4.6 Fast",
        "claude-opus-4.6": "Claude Opus 4.6",
        "claude-sonnet-4": "Claude Sonnet 4",
        "claude-sonnet-4.5": "Claude Sonnet 4.5",
        "claude-opus-4.5": "Claude Opus 4.5",
        "claude-haiku-4.5": "Claude Haiku 4.5",
        "gpt-5.2-codex": "GPT-5.2 Codex",
        "gpt-5.2": "GPT-5.2",
        "gpt-5.1": "GPT-5.1",
        "gpt-5.1-codex": "GPT-5.1 Codex",
        "gpt-5.1-codex-mini": "GPT-5.1 Codex Mini",
        "gpt-5.1-codex-max": "GPT-5.1 Codex Max",
        "gpt-5-mini": "GPT-5 Mini",
        "gpt-5": "GPT-5",
        "gpt-5-codex": "GPT-5 Codex",
        "gpt-4.1": "GPT-4.1",
        "gpt-4.1-2025-04-14": "GPT-4.1 (Apr 2025)",
        "gpt-4o": "GPT-4o",
        "gpt-4o-mini": "GPT-4o Mini",
        "gpt-4o-2024-11-20": "GPT-4o (Nov 2024)",
        "gpt-4o-2024-08-06": "GPT-4o (Aug 2024)",
        "gpt-4o-2024-05-13": "GPT-4o (May 2024)",
        "gpt-4o-mini-2024-07-18": "GPT-4o Mini (Jul 2024)",
        "gpt-4-o-preview": "GPT-4o Preview",
        "gpt-4": "GPT-4",
        "gpt-4-0125-preview": "GPT-4 (Jan 2025)",
        "gpt-3.5-turbo": "GPT-3.5 Turbo",
        "gpt-3.5-turbo-0613": "GPT-3.5 Turbo (Jun 2023)",
        "gemini-3-pro-preview": "Gemini 3 Pro",
        "gemini-3-flash-preview": "Gemini 3 Flash",
        "gemini-2.5-pro": "Gemini 2.5 Pro",
        "grok-code-fast-1": "Grok Code Fast",
        "oswe-vscode-prime": "OSWE Prime",
        "oswe-vscode-secondary": "OSWE Secondary",
        "text-embedding-3-small": "Embedding 3 Small",
        "text-embedding-3-small-inference": "Embedding 3 Small Inference",
        "text-embedding-ada-002": "Embedding Ada 002",
    ]

    /// Chat-capable models only (exclude embedding models)
    var chatModels: [String] {
        availableModels.filter { model in
            !model.hasPrefix("text-embedding") && !model.hasPrefix("oswe")
        }
    }

    func displayName(for model: String) -> String {
        return GitHubCopilotModelManager.displayNames[model] ?? model
    }

    func getProvider(for model: String) -> String {
        if model.hasPrefix("claude") { return "Anthropic" }
        if model.hasPrefix("gpt") { return "OpenAI" }
        if model.hasPrefix("gemini") { return "Google" }
        if model.hasPrefix("grok") { return "xAI" }
        if model.hasPrefix("oswe") { return "OpenAI" }
        return "Other"
    }
}
