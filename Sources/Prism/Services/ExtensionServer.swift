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
            let ollamaModels = OllamaModelManager.shared.allModels.map { 
                ["id": "ollama:\($0)", "name": "Ollama: \($0)"]
            }
            let geminiModels = GeminiModelManager.shared.availableModels.map { 
                ["id": "gemini:\($0)", "name": "Gemini: \(GeminiModelManager.shared.displayName(for: $0))"]
            }
            let appleModels = [["id": "apple:foundation", "name": "Apple Intelligence"]]
            
            let allModels = appleModels + ollamaModels + geminiModels
            
            var response = HttpResponse.ok(.json(allModels))
            return self.applyCORS(to: response)
        }
        
        server["/api/chat"] = { request in
            if request.method.uppercased() == "OPTIONS" {
                return self.applyCORS(to: .ok(.html("")))
            }
            
            // Expected body: { "model": "...", "messages": [{"role": "user", "content": "..."}] }
            let body = Data(request.body)
            guard let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
                  let modelId = json["model"] as? String,
                  let messagesArr = json["messages"] as? [[String: Any]],
                  let lastMessage = messagesArr.last,
                  let prompt = lastMessage["content"] as? String else {
                return self.applyCORS(to: .badRequest(nil))
            }
            
            // Determine backend
            let isOllama = modelId.hasPrefix("ollama:")
            let isGemini = modelId.hasPrefix("gemini:")
            let isApple = modelId.hasPrefix("apple:")
            
            let actualModel = modelId.components(separatedBy: ":").dropFirst().joined(separator: ":")
            
            // To stream with Swifter, we return a custom HttpResponse
            return HttpResponse.raw(200, "OK", ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"]) { writer in
                
                let group = DispatchGroup()
                group.enter()
                
                Task {
                    do {
                        let msg = Message(content: prompt, isUser: true)
                        
                        // NOTE: Ideally, we should also track this chat in ChatManager!
                        await MainActor.run {
                            ChatManager.shared.addMessage(msg)
                        }
                        
                        var aiMsg = Message(content: "", model: actualModel, isUser: false)
                        aiMsg.isStreaming = true
                        
                        await MainActor.run {
                            ChatManager.shared.addMessage(aiMsg)
                        }
                        
                        if isApple {
                            let summarizer = AppleFoundationService()
                            for try await chunk in summarizer.sendMessageStream(history: [msg], systemPrompt: "") {
                                let event = "data: \(try! self.jsonEscape(chunk))\n\n"
                                try? writer.write(Array(event.utf8))
                                aiMsg.content += chunk
                                await MainActor.run { ChatManager.shared.updateMessage(id: aiMsg.id, content: aiMsg.content, isStreaming: true) }
                            }
                        } else if isOllama {
                            let ollama = OllamaService()
                            let endpoint = UserDefaults.standard.string(forKey: "OllamaEndpoint") ?? "http://localhost:11434"
                            let stream = ollama.sendMessageStream(history: [msg], endpoint: endpoint, model: actualModel)
                            for try await (chunk, _) in stream {
                                let event = "data: \(try! self.jsonEscape(chunk))\n\n"
                                try? writer.write(Array(event.utf8))
                                aiMsg.content += chunk
                                await MainActor.run { ChatManager.shared.updateMessage(id: aiMsg.id, content: aiMsg.content, isStreaming: true) }
                            }
                        } else if isGemini {
                            let gemini = GeminiService()
                            let apiKey = UserDefaults.standard.string(forKey: "GeminiKey") ?? ""
                            if apiKey.isEmpty {
                                let event = "data: {\"error\": \"Gemini API Key missing. Set it in Prism Settings.\"}\n\n"
                                try? writer.write(Array(event.utf8))
                            } else {
                                let stream = gemini.sendMessageStream(history: [msg], apiKey: apiKey, model: actualModel)
                                for try await (chunk, _, _) in stream {
                                    if !chunk.isEmpty {
                                        let event = "data: \(try! self.jsonEscape(chunk))\n\n"
                                        try? writer.write(Array(event.utf8))
                                        aiMsg.content += chunk
                                        await MainActor.run { ChatManager.shared.updateMessage(id: aiMsg.id, content: aiMsg.content, isStreaming: true) }
                                    }
                                }
                            }
                        }
                        
                        aiMsg.isStreaming = false
                        await MainActor.run {
                            ChatManager.shared.updateMessage(id: aiMsg.id, content: aiMsg.content, isStreaming: false)
                            ChatManager.shared.saveSessions()
                        }
                        
                        let endEvent = "data: [DONE]\n\n"
                        try? writer.write(Array(endEvent.utf8))
                    } catch {
                        print("Error in ExtensionServer stream: \(error)")
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
            if case let .json(jsonObject) = body {
                let data = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [])) ?? Data()
                return .raw(200, "OK", ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type"]) { writer in
                    try? writer.write(Array(data))
                }
            } else if case let .html(htmlString) = body {
                return .raw(200, "OK", ["Content-Type": "text/html", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type"]) { writer in
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
}
