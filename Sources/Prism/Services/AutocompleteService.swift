import Foundation

/// Lightweight service for generating short inline autocomplete suggestions.
/// Reuses existing Ollama / Gemini / Apple Foundation patterns but with
/// tight timeouts and a completion-focused system prompt.
class AutocompleteService {
    static let shared = AutocompleteService()

    private let session: URLSession

    /// The system prompt that instructs the model to produce ONLY the continuation.
    static let defaultSystemPrompt = """
        You are a highly constrained inline text autocomplete engine. Your ONLY job is to predict the immediate next characters or words that follow the user's input. \
        You are NOT a chatbot. You must NEVER behave like a conversational AI. \
        \
        CRITICAL RULES: \
        1. Output ONLY the exact continuation. Do NOT output any greetings, pleasantries, or AI conversational filler (e.g. NEVER output "how can I help you?"). \
        2. Do NOT repeat any part of the input text. Output ONLY the new continuation. \
        3. Do NOT add quotes, markdown formatting, explanations, or metadata. \
        4. Keep completions extremely short — finish the current word, phrase, or sentence (1 sentence maximum). \
        5. If the last word is incomplete, first complete that word, then continue naturally. \
        \
        Example — Input: "Thank you for your" → Output: " email regarding the project timeline." \
        Example — Input: "Hi Alex,\\n\\nI wanted to fol" → Output: "low up on our conversation from yesterday." \
        Example — Input: "def calculate_" → Output: "total(items):\\n    return sum(item.price for item in items)" \
        Example — Input: "hi" → Output: " there! I hope you're having a good day."
        """

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10  // Short timeout for responsiveness
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Backend Selection

    enum Backend: String, CaseIterable, Identifiable {
        case ollama = "Ollama"
        case gemini = "Gemini"
        case appleFoundation = "Apple Intelligence"

        var id: String { rawValue }
    }

    // MARK: - Completion Generation

    /// Generate an autocomplete suggestion by streaming from the selected backend.
    /// Returns an `AsyncThrowingStream` of partial completion text.
    func generateCompletion(
        context: String,
        backend: Backend,
        model: String,
        customInstruction: String = "",
        length: String = "Medium (~ 2 - 4 words)"
    ) -> AsyncThrowingStream<String, Error> {
        var systemPrompt = AutocompleteService.defaultSystemPrompt

        // Adjust prompt based on requested length
        if length.contains("Short") {
            systemPrompt += "\n\nCRITICAL: Keep the completion VERY SHORT (1-2 words max). Stop immediately after."
        } else if length.contains("Long") {
            systemPrompt += "\n\nCRITICAL: You may write slightly longer completions (up to a full sentence or ~10 words) if it naturally finishes the thought."
        } else {
            systemPrompt += "\n\nCRITICAL: Keep the completion brief, around 2-4 words."
        }

        // Append custom instruction if present
        if !customInstruction.isEmpty {
            systemPrompt += "\n\nAdditional style instruction: \(customInstruction)"
        }

        // Append writing memory context if enabled
        if UserDefaults.standard.bool(forKey: "CotypistMemoryEnabled") {
            let memoryContext = WritingMemory.shared.getStyleContext()
            if !memoryContext.isEmpty {
                systemPrompt += "\n\n\(memoryContext)"
            }
        }

        let userPrompt = String(context.suffix(500))  // Last 500 chars of context

        switch backend {
        case .ollama:
            return streamFromOllama(prompt: userPrompt, systemPrompt: systemPrompt, model: model)
        case .gemini:
            return streamFromGemini(prompt: userPrompt, systemPrompt: systemPrompt, model: model)
        case .appleFoundation:
            return streamFromAppleFoundation(prompt: userPrompt, systemPrompt: systemPrompt)
        }
    }

    // MARK: - Ollama

    private func streamFromOllama(
        prompt: String, systemPrompt: String, model: String
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let ollamaURL =
                    UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://localhost:11434"
                let baseURL = ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(baseURL)/api/generate") else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "model": model.isEmpty ? "llama3.2" : model,
                    "prompt": prompt,
                    "system": systemPrompt,
                    "stream": true,
                    "options": [
                        "num_predict": 80,  // Limit output length
                        "temperature": 0.3,  // Lower temp for more predictable completions
                    ],
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                        httpResponse.statusCode == 200
                    else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(
                            throwing: NSError(
                                domain: "AutocompleteService",
                                code: status,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Ollama returned status \(status)"
                                ]
                            ))
                        return
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let text = json["response"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                        if let done = json["done"] as? Bool, done {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Gemini

    private func streamFromGemini(
        prompt: String, systemPrompt: String, model: String
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let apiKey = UserDefaults.standard.string(forKey: "GeminiKey") ?? ""
                guard !apiKey.isEmpty else {
                    continuation.finish(
                        throwing: NSError(
                            domain: "AutocompleteService",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Gemini API key not set"]
                        ))
                    return
                }

                let modelName = model.isEmpty ? "gemini-2.5-flash" : model
                guard
                    let url = URL(
                        string:
                            "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?key=\(apiKey)&alt=sse"
                    )
                else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "system_instruction": [
                        "parts": [["text": systemPrompt]]
                    ],
                    "contents": [
                        [
                            "role": "user",
                            "parts": [["text": prompt]],
                        ]
                    ],
                    "generationConfig": [
                        "maxOutputTokens": 80,
                        "temperature": 0.3,
                    ],
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                        httpResponse.statusCode == 200
                    else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(
                            throwing: NSError(
                                domain: "AutocompleteService",
                                code: status,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Gemini returned status \(status)"
                                ]
                            ))
                        return
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data: ") else { continue }
                        let jsonString = String(trimmed.dropFirst(6))
                        guard let data = jsonString.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let candidates = json["candidates"] as? [[String: Any]],
                            let first = candidates.first,
                            let content = first["content"] as? [String: Any],
                            let parts = content["parts"] as? [[String: Any]],
                            let text = parts.first?["text"] as? String
                        {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Apple Foundation

    private func streamFromAppleFoundation(
        prompt: String, systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        let service = AppleFoundationService()
        let message = Message(content: prompt, isUser: true)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in service.sendMessageStream(
                        history: [message], systemPrompt: systemPrompt)
                    {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
