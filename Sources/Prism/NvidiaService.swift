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
                let modelName = model.isEmpty ? "meta/llama-3.1-70b-instruct" : model

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
                        var msgDict: [String: Any] = ["role": msg.isUser ? "user" : "assistant"]

                        let compressImage: (Data) -> String? = { data in
                            guard let image = NSImage(data: data) else { return nil }

                            let maxDimension: CGFloat = 2048.0
                            var targetSize = image.size

                            if image.size.width > maxDimension || image.size.height > maxDimension {
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
                                    using: .jpeg, properties: [.compressionFactor: 0.9])
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

                var body: [String: Any] = [
                    "model": modelName,
                    "messages": messages,
                    "max_tokens": 16384,
                    "temperature": 1.00,
                    "top_p": 1.00,
                    "stream": true,
                ]

                if enableThinking {
                    body["chat_template_kwargs"] = ["enable_thinking": true]
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
                    var insideThinkTag = false
                    var thinkTagBuffer = ""

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

                            // Handle reasoning_content field (NIM standard)
                            if let reasoning = delta["reasoning_content"] as? String,
                                !reasoning.isEmpty
                            {
                                continuation.yield(("", reasoning))
                            }

                            // Handle content with <think> tag fallback
                            if let content = delta["content"] as? String, !content.isEmpty {
                                var remaining = content
                                while !remaining.isEmpty {
                                    if insideThinkTag {
                                        if let endRange = remaining.range(of: "</think>") {
                                            let thought = remaining[
                                                remaining.startIndex..<endRange.lowerBound]
                                            thinkTagBuffer += thought
                                            continuation.yield(("", String(thinkTagBuffer)))
                                            thinkTagBuffer = ""
                                            insideThinkTag = false
                                            remaining = String(remaining[endRange.upperBound...])
                                        } else {
                                            thinkTagBuffer += remaining
                                            continuation.yield(("", remaining))
                                            remaining = ""
                                        }
                                    } else {
                                        if let startRange = remaining.range(of: "<think>") {
                                            let before = remaining[
                                                remaining.startIndex..<startRange.lowerBound]
                                            if !before.isEmpty {
                                                continuation.yield((String(before), nil))
                                            }
                                            insideThinkTag = true
                                            thinkTagBuffer = ""
                                            remaining = String(remaining[startRange.upperBound...])
                                        } else {
                                            continuation.yield((remaining, nil))
                                            remaining = ""
                                        }
                                    }
                                }
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
