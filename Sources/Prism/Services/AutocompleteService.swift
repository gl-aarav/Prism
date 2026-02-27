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
        1. Output ONLY the exact continuation text. Do NOT output any greetings, pleasantries, or conversational filler. \
        2. Do NOT repeat, echo, or re-state ANY part of the input text. Output ONLY the NEW continuation. \
        3. Do NOT add quotes, markdown formatting, explanations, code fences, or metadata. \
        4. If the input looks like code, continue the code naturally (completing the line, adding the next line, etc.). \
        5. If the input looks like prose/email/chat, continue the sentence or thought naturally. \
        6. If the last word is incomplete, FIRST complete that word, then optionally continue. \
        7. NEVER start your output with text that already appears at the end of the input. \
        8. Do NOT output empty lines or leading whitespace unless continuing an indented code block. \
        \
        Examples: \
        Input: "Thank you for your" → Output: " email regarding the project timeline." \
        Input: "Hi Alex,\\n\\nI wanted to fol" → Output: "low up on our conversation from yesterday." \
        Input: "def calculate_" → Output: "total(items):\\n    return sum(item.price for item in items)" \
        Input: "const result = arr.fil" → Output: "ter(item => item.active)" \
        Input: "import " → Output: "Foundation"
        """

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
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
            systemPrompt += "\n\nCRITICAL LENGTH CONSTRAINT: Keep the completion VERY SHORT — 1-2 words maximum. Stop immediately after completing the current thought fragment."
        } else if length.contains("Long") {
            systemPrompt += "\n\nLENGTH GUIDANCE: You may write longer completions — up to a full sentence or two (~10-20 words) if it naturally finishes the thought. Include line breaks for code."
        } else {
            systemPrompt += "\n\nLENGTH GUIDANCE: Keep the completion brief — around 2-4 words, finishing the current phrase or statement."
        }

        // Append custom instruction if present
        if !customInstruction.isEmpty {
            systemPrompt += "\n\nAdditional style instruction: \(customInstruction)"
        }

        // Append writing memory context if enabled
        if UserDefaults.standard.bool(forKey: "AIAutocompleteMemoryEnabled") {
            let memoryContext = WritingMemory.shared.getStyleContext()
            if !memoryContext.isEmpty {
                systemPrompt += "\n\n\(memoryContext)"
            }
        }

        // Send more context (last 1500 chars) for better predictions
        let userPrompt = String(context.suffix(1500))

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
                        "num_predict": 120,
                        "temperature": 0.25,
                        "top_p": 0.9,
                        "repeat_penalty": 1.2,
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
                        "maxOutputTokens": 120,
                        "temperature": 0.25,
                        "topP": 0.9,
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
