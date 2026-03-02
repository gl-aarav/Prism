import AppKit
import Foundation

class NvidiaService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func sendMessageStream(
        history: [Message], apiKey: String, model: String, systemPrompt: String = "",
        enableThinking: Bool = false
    ) -> AsyncThrowingStream<(String, String?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let modelName = model.isEmpty ? "llama-3.1-70b-instruct" : model

                guard
                    let url = URL(
                        string: "https://integrate.api.nvidia.com/v1/chat/completions")
                else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

                var messages: [[String: Any]] = []

                if !systemPrompt.isEmpty {
                    messages.append([
                        "role": "system",
                        "content": systemPrompt,
                    ])
                }

                messages.append(
                    contentsOf: history.map { msg in
                        [
                            "role": msg.isUser ? "user" : "assistant",
                            "content": msg.content,
                        ] as [String: Any]
                    })

                var body: [String: Any] = [
                    "model": modelName,
                    "messages": messages,
                    "max_tokens": 16384,
                    "temperature": 1.00,
                    "top_p": 1.00,
                    "stream": true,
                ]

                if enableThinking {
                    body["chat_template_kwargs"] = ["thinking": true]
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (result, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorText = ""
                        for try await line in result.lines {
                            errorText += line
                        }
                        if let data = errorText.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            let errorObj = json["error"] as? [String: Any],
                            let msg = errorObj["message"] as? String
                        {
                            errorText = msg
                        }
                        continuation.finish(
                            throwing: NSError(
                                domain: "NvidiaError", code: httpResponse.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: errorText]))
                        return
                    }

                    // Parse SSE stream (OpenAI-compatible format)
                    for try await line in result.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" { break }

                            guard let data = jsonStr.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any],
                                let choices = json["choices"] as? [[String: Any]],
                                let delta = choices.first?["delta"] as? [String: Any]
                            else { continue }

                            // Handle thinking content if present
                            if let reasoning = delta["reasoning_content"] as? String,
                                !reasoning.isEmpty
                            {
                                continuation.yield(("", reasoning))
                            }

                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield((content, nil))
                            }
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
