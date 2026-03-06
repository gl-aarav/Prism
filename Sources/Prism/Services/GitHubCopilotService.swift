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
    @Published var signingInAccountId: UUID? = nil
    @Published var deviceCode: String? = nil
    @Published var verificationURL: URL? = nil
    @Published var errorMessage: String? = nil

    /// Per-account auth state: accountId -> (userName, avatarURL)
    @Published var accountAuthState: [UUID: (userName: String, avatarURL: String)] = [:]

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

        // Restore saved auth state (legacy default account)
        if let token = getStoredToken(), !token.isEmpty {
            isAuthenticated = true
            userName = UserDefaults.standard.string(forKey: userNameKey) ?? ""
            avatarURL = UserDefaults.standard.string(forKey: avatarKey) ?? ""
        }

        // Restore per-account auth state, deferred to next run loop iteration
        // to ensure dispatch_once lock for `shared` is fully released first
        DispatchQueue.main.async { [weak self] in
            self?.restoreAccountAuthStates()
        }
    }

    private func restoreAccountAuthStates() {
        for account in AccountManager.shared.copilotAccounts() {
            if let token = getStoredToken(accountId: account.id.uuidString), !token.isEmpty {
                let name =
                    UserDefaults.standard.string(forKey: "\(userNameKey)_\(account.id.uuidString)")
                    ?? ""
                let avatar =
                    UserDefaults.standard.string(forKey: "\(avatarKey)_\(account.id.uuidString)")
                    ?? ""
                accountAuthState[account.id] = (userName: name, avatarURL: avatar)
                if !isAuthenticated { isAuthenticated = true }
            }
        }
    }

    func isAccountAuthenticated(_ accountId: UUID) -> Bool {
        if let token = getStoredToken(accountId: accountId.uuidString), !token.isEmpty {
            return true
        }
        // Check default token for legacy/first account
        if accountId == AccountManager.shared.copilotAccounts().first?.id {
            if let token = getStoredToken(), !token.isEmpty { return true }
        }
        return false
    }

    // MARK: - Token Storage (Keychain)

    func getStoredToken(accountId: String? = nil) -> String? {
        let key = accountId.map { "\(tokenKey)_\($0)" } ?? tokenKey
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func storeToken(_ token: String, accountId: String? = nil) {
        let key = accountId.map { "\(tokenKey)_\($0)" } ?? tokenKey
        let data = token.data(using: .utf8)!

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteToken(accountId: String? = nil) {
        let key = accountId.map { "\(tokenKey)_\($0)" } ?? tokenKey
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: key,
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
    func completeSignIn(token: String, accountId: UUID? = nil) async throws {
        let acctIdStr = accountId?.uuidString
        storeToken(token, accountId: acctIdStr)

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
                if let acctId = accountId {
                    self.accountAuthState[acctId] = (userName: login, avatarURL: avatar)
                    UserDefaults.standard.set(
                        login, forKey: "\(self.userNameKey)_\(acctId.uuidString)")
                    UserDefaults.standard.set(
                        avatar, forKey: "\(self.avatarKey)_\(acctId.uuidString)")
                    AccountManager.shared.renameAccount(
                        id: acctId, newName: "GitHub Copilot (\(login))")
                } else {
                    self.userName = login
                    self.avatarURL = avatar
                    UserDefaults.standard.set(login, forKey: self.userNameKey)
                    UserDefaults.standard.set(avatar, forKey: self.avatarKey)
                    // If this was the first/legacy account without an ID, rename the first copilot account
                    if let firstCopilot = AccountManager.shared.copilotAccounts().first {
                        AccountManager.shared.renameAccount(
                            id: firstCopilot.id, newName: "GitHub Copilot (\(login))")
                    }
                }
                self.isAuthenticated = true
            }
        }
    }

    func signOut(accountId: UUID? = nil) {
        if let acctId = accountId {
            deleteToken(accountId: acctId.uuidString)
            accountAuthState.removeValue(forKey: acctId)
            UserDefaults.standard.removeObject(forKey: "\(userNameKey)_\(acctId.uuidString)")
            UserDefaults.standard.removeObject(forKey: "\(avatarKey)_\(acctId.uuidString)")
            cachedCopilotTokens.removeValue(forKey: acctId.uuidString)
            // Check if any accounts remain authenticated
            let hasAnyAuth =
                getStoredToken() != nil
                || AccountManager.shared.copilotAccounts().contains {
                    isAccountAuthenticated($0.id)
                }
            isAuthenticated = hasAnyAuth
        } else {
            deleteToken()
            isAuthenticated = false
            userName = ""
            avatarURL = ""
            UserDefaults.standard.removeObject(forKey: userNameKey)
            UserDefaults.standard.removeObject(forKey: avatarKey)
            cachedCopilotTokens.removeAll()
        }
    }

    /// Convenience: orchestrate the full device flow sign-in from UI
    func startSignIn(forAccountId accountId: UUID? = nil) {
        isSigningIn = true
        signingInAccountId = accountId
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
                try await completeSignIn(token: token, accountId: accountId)

                await MainActor.run {
                    self.isSigningIn = false
                    self.signingInAccountId = nil
                    self.deviceCode = nil
                    self.verificationURL = nil

                    // Auto-create copilot account if needed and no specific account was given
                    if accountId == nil {
                        if !AccountManager.shared.accounts.contains(where: {
                            $0.providerType == "copilot"
                        }) {
                            AccountManager.shared.addAccount(.copilotAccount())
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSigningIn = false
                    self.signingInAccountId = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Get Copilot Token (exchange GitHub token for Copilot API token)

    private var cachedCopilotTokens: [String: (token: String, expiry: Date)] = [:]

    func getCopilotToken(accountId: String? = nil) async throws -> String {
        let cacheKey = accountId ?? "__default__"

        // Return cached if still valid
        if let cached = cachedCopilotTokens[cacheKey], Date() < cached.expiry {
            return cached.token
        }

        // Try account-specific token, then fall back to default
        let githubToken: String
        if let acctId = accountId, let token = getStoredToken(accountId: acctId) {
            githubToken = token
        } else if let token = getStoredToken(accountId: accountId) ?? getStoredToken() {
            githubToken = token
        } else {
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
            await MainActor.run {
                if let acctIdStr = accountId, let uuid = UUID(uuidString: acctIdStr) {
                    self.signOut(accountId: uuid)
                } else {
                    self.signOut()
                }
            }
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

        // Token typically valid for ~30 minutes, refresh at 25
        cachedCopilotTokens[cacheKey] = (token: token, expiry: Date().addingTimeInterval(25 * 60))

        return token
    }

    // MARK: - Chat Streaming

    func sendMessageStream(
        history: [Message], model: String, systemPrompt: String = "", accountId: String? = nil
    ) -> AsyncThrowingStream<(String, String?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let copilotToken = try await getCopilotToken(accountId: accountId)

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
                            var msgDict: [String: Any] = ["role": msg.isUser ? "user" : "assistant"]

                            // Helper to compress image size
                            let compressImage: (Data) -> String? = { data in
                                guard let image = NSImage(data: data) else { return nil }

                                // Resize if larger than 1024px
                                let maxDimension: CGFloat = 1024.0
                                var targetSize = image.size

                                if image.size.width > maxDimension
                                    || image.size.height > maxDimension
                                {
                                    let aspectRatio = image.size.width / image.size.height
                                    if aspectRatio > 1 {
                                        targetSize.width = maxDimension
                                        targetSize.height = maxDimension / aspectRatio
                                    } else {
                                        targetSize.height = maxDimension
                                        targetSize.width = maxDimension * aspectRatio
                                    }
                                }

                                let newImage = NSImage(size: targetSize)
                                newImage.lockFocus()
                                image.draw(
                                    in: NSRect(origin: .zero, size: targetSize),
                                    from: NSRect(origin: .zero, size: image.size), operation: .copy,
                                    fraction: 1.0)
                                newImage.unlockFocus()

                                guard let tiff = newImage.tiffRepresentation,
                                    let bitmap = NSBitmapImageRep(data: tiff),
                                    let jpegData = bitmap.representation(
                                        using: .jpeg, properties: [.compressionFactor: 0.6])
                                else {
                                    return nil
                                }

                                return jpegData.base64EncodedString()
                            }

                            if let imageData = msg.imageData,
                                let base64String = compressImage(imageData)
                            {
                                msgDict["content"] = [
                                    ["type": "text", "text": msg.content],
                                    [
                                        "type": "image_url",
                                        "image_url": [
                                            "url": "data:image/jpeg;base64,\(base64String)"
                                        ],
                                    ],
                                ]
                            } else if let attachments = msg.attachments, !attachments.isEmpty {
                                // Extract images from attachments array
                                var contentArr: [[String: Any]] = [
                                    ["type": "text", "text": msg.content]
                                ]
                                for attachment in attachments {
                                    if attachment.type == "image",
                                        let base64String = compressImage(attachment.data)
                                    {
                                        contentArr.append([
                                            "type": "image_url",
                                            "image_url": [
                                                "url": "data:image/jpeg;base64,\(base64String)"
                                            ],
                                        ])
                                    }
                                }
                                if contentArr.count > 1 {
                                    msgDict["content"] = contentArr
                                } else {
                                    msgDict["content"] = msg.content
                                }
                            } else {
                                msgDict["content"] = msg.content
                            }
                            return msgDict
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
        "claude-opus-4.5",
        "claude-sonnet-4.6",
        "claude-sonnet-4.5",
        "claude-sonnet-4",
        "claude-haiku-4.5",
        // GPT-5 Series
        "gpt-5.4",
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5-mini",
        "gpt-5",
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
        "gemini-3.1-pro-preview",
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        "gemini-2.5-pro",
        // Grok & Others
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
        "claude-opus-4.5": "Claude Opus 4.5",
        "claude-sonnet-4.6": "Claude Sonnet 4.6",
        "claude-sonnet-4.5": "Claude Sonnet 4.5",
        "claude-sonnet-4": "Claude Sonnet 4",
        "claude-haiku-4.5": "Claude Haiku 4.5",
        "gpt-5.4": "GPT-5.4",
        "gpt-5.2": "GPT-5.2",
        "gpt-5.1": "GPT-5.1",
        "gpt-5-mini": "GPT-5 Mini",
        "gpt-5": "GPT-5",
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
        "gemini-3.1-pro-preview": "Gemini 3.1 Pro (Preview)",
        "gemini-3-pro-preview": "Gemini 3 Pro (Preview)",
        "gemini-3-flash-preview": "Gemini 3 Flash (Preview)",
        "gemini-2.5-pro": "Gemini 2.5 Pro",
        "grok-code-fast-1": "Grok Code Fast 1",
        "oswe-vscode-prime": "OSWE Prime",
        "oswe-vscode-secondary": "OSWE Secondary",
        "text-embedding-3-small": "Embedding 3 Small",
        "text-embedding-3-small-inference": "Embedding 3 Small Inference",
        "text-embedding-ada-002": "Embedding Ada 002",
    ]

    var chatModels: [String] {
        availableModels.filter { !$0.hasPrefix("text-embedding") }
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
