import Foundation
import Swifter

class ExtensionServer {
    static let shared = ExtensionServer()
    private let server = HttpServer()

    // We keep a reference to active streams if needed to clean them up, but Swifter closures handle their own lifecycle.

    private init() {
        setupRoutes()
    }

    func start() {
        do {
            try server.start(8080)
            print("Extension server started on port 8080")
        } catch {
            print("Failed to start extension server: \(error)")
        }
    }

    func stop() {
        server.stop()
    }

    private func setupRoutes() {
        // CORS Middleware approach for Swifter: we add headers to responses.

        server["/api/models"] = { request in
            if request.method.uppercased() == "OPTIONS" {
                return self.applyCORS(to: .ok(.html("")))
            }

            var allModels: [[String: String]] = []

            // Apple Intelligence (always available)
            allModels.append(["id": "apple:foundation", "name": "Apple Intelligence"])

            // Gemini accounts - only show if API key is configured
            let geminiAccounts = AccountManager.shared.geminiAccounts().filter {
                !$0.apiKey.isEmpty
            }
            for account in geminiAccounts {
                let prefix = geminiAccounts.count > 1 ? "\(account.displayName): " : "Gemini: "
                for model in GeminiModelManager.shared.availableModels {
                    allModels.append([
                        "id": "gemini:\(model)|\(account.id.uuidString)",
                        "name": "\(prefix)\(GeminiModelManager.shared.displayName(for: model))",
                    ])
                }
            }

            // Ollama accounts - only show if configured
            let ollamaAccounts = AccountManager.shared.ollamaAccounts()
            for account in ollamaAccounts {
                let prefix = ollamaAccounts.count > 1 ? "\(account.displayName): " : "Ollama: "
                for model in OllamaModelManager.shared.allModels {
                    allModels.append([
                        "id": "ollama:\(model)|\(account.id.uuidString)",
                        "name": "\(prefix)\(model)",
                    ])
                }
            }

            // GitHub Copilot - show per-account if multiple
            if GitHubCopilotService.shared.isAuthenticated {
                let copilotAccounts = AccountManager.shared.copilotAccounts()
                if copilotAccounts.count <= 1 {
                    for model in GitHubCopilotModelManager.shared.chatModels {
                        allModels.append([
                            "id": "copilot:\(model)",
                            "name":
                                "Copilot: \(GitHubCopilotModelManager.shared.displayName(for: model))",
                        ])
                    }
                } else {
                    for account in copilotAccounts {
                        let acctName =
                            GitHubCopilotService.shared.accountAuthState[account.id]?.userName
                            ?? account.displayName
                        for model in GitHubCopilotModelManager.shared.chatModels {
                            allModels.append([
                                "id": "copilot:\(model)|\(account.id.uuidString)",
                                "name":
                                    "\(acctName): \(GitHubCopilotModelManager.shared.displayName(for: model))",
                            ])
                        }
                    }
                }
            }

            // Gemini CLI - only show if available
            if GeminiCLIService.shared.isAvailable {
                for model in GeminiCLIService.availableModels {
                    allModels.append([
                        "id": "geminicli:\(model.id)",
                        "name": "Gemini CLI: \(model.name)",
                    ])
                }
            }

            let response = HttpResponse.ok(.json(allModels))
            return self.applyCORS(to: response)
        }

        // Receive chat from extension to forward to app
        server["/api/forward-chat"] = { request in
            if request.method.uppercased() == "OPTIONS" {
                return self.applyCORS(to: .ok(.html("")))
            }

            let body = Data(request.body)
            guard
                let json = try? JSONSerialization.jsonObject(with: body, options: [])
                    as? [String: Any],
                let messagesArr = json["messages"] as? [[String: Any]]
            else {
                return self.applyCORS(to: .badRequest(nil))
            }

            let agentActions = json["agentActions"] as? [[String: Any]] ?? []
            let modelUsed = json["model"] as? String ?? "Extension"

            // Convert to Message objects and add to a new chat session
            DispatchQueue.main.async {
                let chatManager = ChatManager.shared
                chatManager.createNewSession()

                for msgDict in messagesArr {
                    guard let role = msgDict["role"] as? String,
                        let content = msgDict["content"] as? String
                    else { continue }

                    let msg = Message(
                        content: content,
                        model: role == "assistant" ? modelUsed : nil,
                        isUser: role == "user"
                    )
                    chatManager.addMessage(msg)
                }

                // If there were agent actions, add a summary message
                if !agentActions.isEmpty {
                    var summaryLines: [String] = ["**Browser Agent Actions:**"]
                    for action in agentActions {
                        if let summary = action["summary"] as? String {
                            summaryLines.append("• \(summary)")
                        }
                    }
                    let summaryMsg = Message(
                        content: summaryLines.joined(separator: "\n"),
                        model: "Browser Agent",
                        isUser: false
                    )
                    chatManager.addMessage(summaryMsg)
                }
            }

            let response: [String: Any] = ["status": "ok"]
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            return self.applyCORS(
                to: .raw(
                    200, "OK",
                    ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"],
                    { writer in
                        try? writer.write(Array(data))
                    }))
        }

        server["/api/chat"] = { request in
            if request.method.uppercased() == "OPTIONS" {
                return self.applyCORS(to: .ok(.html("")))
            }

            // Expected body: { "model": "...", "messages": [...], "thinkingLevel": "medium" }
            let body = Data(request.body)
            guard
                let json = try? JSONSerialization.jsonObject(with: body, options: [])
                    as? [String: Any],
                let modelId = json["model"] as? String,
                let messagesArr = json["messages"] as? [[String: Any]]
            else {
                return self.applyCORS(to: .badRequest(nil))
            }

            let thinkingLevel = json["thinkingLevel"] as? String ?? "medium"
            let webSearchEnabled = json["webSearch"] as? Bool ?? false

            // Convert all messages to Message objects for full history context
            let history: [Message] = messagesArr.compactMap { msgDict in
                guard let role = msgDict["role"] as? String,
                    let content = msgDict["content"] as? String
                else { return nil }
                return Message(content: content, isUser: role == "user")
            }

            guard !history.isEmpty else {
                return self.applyCORS(to: .badRequest(nil))
            }

            // Determine backend
            let isOllama = modelId.hasPrefix("ollama:")
            let isGemini = modelId.hasPrefix("gemini:")
            let isApple = modelId.hasPrefix("apple:")
            let isCopilot = modelId.hasPrefix("copilot:")
            let isGeminiCLI = modelId.hasPrefix("geminicli:")

            // Parse model name and optional account ID (format: "provider:model|accountUUID")
            let afterPrefix = modelId.components(separatedBy: ":").dropFirst().joined(
                separator: ":")
            let modelParts = afterPrefix.components(separatedBy: "|")
            let actualModel = modelParts[0]
            let accountId = modelParts.count > 1 ? modelParts[1] : nil
            let systemPrompt = UserDefaults.standard.string(forKey: "SystemPrompt") ?? ""

            // Stream response via SSE — extension manages its own chat history
            return HttpResponse.raw(
                200, "OK",
                [
                    "Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                    "Access-Control-Allow-Origin": "*",
                ]
            ) { writer in

                let group = DispatchGroup()
                group.enter()

                Task {
                    do {
                        if isApple {
                            let service = AppleFoundationService()
                            for try await chunk in service.sendMessageStream(
                                history: history, systemPrompt: systemPrompt)
                            {
                                let event = "data: \(try self.jsonEscape(chunk))\n\n"
                                try? writer.write(Array(event.utf8))
                            }
                        } else if isOllama {
                            let ollama = OllamaService()
                            // Resolve endpoint from account if multi-account
                            var endpoint =
                                UserDefaults.standard.string(forKey: "OllamaURL")
                                ?? "http://localhost:11434"
                            if let accId = accountId, let uuid = UUID(uuidString: accId),
                                let account = AccountManager.shared.accounts.first(where: {
                                    $0.id == uuid
                                })
                            {
                                endpoint = account.endpoint
                            }

                            var currentHistory = history
                            if webSearchEnabled {
                                let ollamaAPIKey =
                                    UserDefaults.standard.string(forKey: "OllamaAPIKey") ?? ""
                                if !ollamaAPIKey.isEmpty,
                                    let lastUserMsg = currentHistory.last(where: { $0.isUser })
                                {
                                    let webSearchService = WebSearchService()
                                    do {
                                        let searchResults = try await webSearchService.search(
                                            query: lastUserMsg.content, apiKey: ollamaAPIKey)
                                        let searchContext = webSearchService.buildSearchContext(
                                            results: searchResults)
                                        if let lastIndex = currentHistory.lastIndex(where: {
                                            $0.isUser
                                        }) {
                                            currentHistory[lastIndex].content =
                                                searchContext + "\n"
                                                + currentHistory[lastIndex].content
                                        }
                                    } catch {
                                        print("Web search failed: \(error)")
                                    }
                                }
                            }

                            let stream = ollama.sendMessageStream(
                                history: currentHistory, endpoint: endpoint, model: actualModel,
                                systemPrompt: systemPrompt, thinkingLevel: thinkingLevel)
                            for try await (chunk, thinkingChunk) in stream {
                                if let thinking = thinkingChunk, !thinking.isEmpty {
                                    let thinkEvent =
                                        "data: \(try self.jsonEscapeDict(["thinking": thinking]))\n\n"
                                    try? writer.write(Array(thinkEvent.utf8))
                                }
                                if !chunk.isEmpty {
                                    let event = "data: \(try self.jsonEscape(chunk))\n\n"
                                    try? writer.write(Array(event.utf8))
                                }
                            }
                        } else if isGemini {
                            let gemini = GeminiService()
                            // Resolve API key from account if multi-account
                            var apiKey = UserDefaults.standard.string(forKey: "GeminiKey") ?? ""
                            if let accId = accountId, let uuid = UUID(uuidString: accId),
                                let account = AccountManager.shared.accounts.first(where: {
                                    $0.id == uuid
                                })
                            {
                                apiKey = account.apiKey
                            }
                            if apiKey.isEmpty {
                                let event =
                                    "data: \(try self.jsonEscapeDict(["error": "Gemini API Key missing. Set it in Prism Settings."]))\n\n"
                                try? writer.write(Array(event.utf8))
                            } else {
                                let stream = gemini.sendMessageStream(
                                    history: history, apiKey: apiKey, model: actualModel,
                                    systemPrompt: systemPrompt, thinkingLevel: thinkingLevel)
                                for try await (chunk, thinkingChunk, _) in stream {
                                    if let thinking = thinkingChunk, !thinking.isEmpty {
                                        let thinkEvent =
                                            "data: \(try self.jsonEscapeDict(["thinking": thinking]))\n\n"
                                        try? writer.write(Array(thinkEvent.utf8))
                                    }
                                    if !chunk.isEmpty {
                                        let event = "data: \(try self.jsonEscape(chunk))\n\n"
                                        try? writer.write(Array(event.utf8))
                                    }
                                }
                            }
                        } else if isCopilot {
                            // GitHub Copilot
                            if !GitHubCopilotService.shared.isAuthenticated {
                                let event =
                                    "data: \(try self.jsonEscapeDict(["error": "Not signed in to GitHub Copilot. Sign in from Prism Settings."]))\n\n"
                                try? writer.write(Array(event.utf8))
                            } else {
                                let stream = GitHubCopilotService.shared.sendMessageStream(
                                    history: history, model: actualModel,
                                    systemPrompt: systemPrompt,
                                    accountId: accountId
                                )
                                for try await (chunk, _) in stream {
                                    if !chunk.isEmpty {
                                        let event = "data: \(try self.jsonEscape(chunk))\n\n"
                                        try? writer.write(Array(event.utf8))
                                    }
                                }
                            }
                        } else if isGeminiCLI {
                            // Gemini CLI
                            if !GeminiCLIService.shared.isAvailable {
                                let event =
                                    "data: \(try self.jsonEscapeDict(["error": "Gemini CLI not found. Install it first."]))\n\n"
                                try? writer.write(Array(event.utf8))
                            } else {
                                for try await chunk in GeminiCLIService.shared.sendMessageStream(
                                    history: history, model: actualModel, systemPrompt: systemPrompt
                                ) {
                                    if !chunk.isEmpty {
                                        let event = "data: \(try self.jsonEscape(chunk))\n\n"
                                        try? writer.write(Array(event.utf8))
                                    }
                                }
                            }
                        }

                        let endEvent = "data: [DONE]\n\n"
                        try? writer.write(Array(endEvent.utf8))
                    } catch {
                        let errorEvent =
                            "data: \((try? self.jsonEscapeDict(["error": error.localizedDescription])) ?? "{\"error\":\"Unknown error\"}")\n\n"
                        try? writer.write(Array(errorEvent.utf8))
                    }
                    group.leave()
                }

                group.wait()
            }
        }
    }

    private func applyCORS(to response: HttpResponse) -> HttpResponse {
        // Wrapper for Swifter responses to add CORS headers
        switch response {
        case .ok(let body):
            if case .json(let jsonObject) = body {
                let data =
                    (try? JSONSerialization.data(withJSONObject: jsonObject, options: [])) ?? Data()
                return .raw(
                    200, "OK",
                    [
                        "Content-Type": "application/json", "Access-Control-Allow-Origin": "*",
                        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                        "Access-Control-Allow-Headers": "Content-Type",
                    ]
                ) { writer in
                    try? writer.write(Array(data))
                }
            } else if case .html(let htmlString) = body {
                return .raw(
                    200, "OK",
                    [
                        "Content-Type": "text/html", "Access-Control-Allow-Origin": "*",
                        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                        "Access-Control-Allow-Headers": "Content-Type",
                    ]
                ) { writer in
                    try? writer.write(Array(htmlString.utf8))
                }
            }
        case .badRequest:
            return .raw(400, "Bad Request", ["Access-Control-Allow-Origin": "*"]) { _ in }
        default:
            return response
        }
        return response
    }

    private func jsonEscape(_ string: String) throws -> String {
        let dict = ["text": string]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jsonEscapeDict(_ dict: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
