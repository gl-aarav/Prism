import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// A wrapper class available to all targets
class AppleFoundationService {
    private var _handler: Any?

    init() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            self._handler = InnerFoundationHandler()
        }
        #endif
    }

    func sendMessageStream(
        history: [Message],
        systemPrompt: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *), let handler = self._handler as? InnerFoundationHandler {
                    do {
                        for try await text in handler.stream(history: history, systemPrompt: systemPrompt) {
                            continuation.yield(text)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } else {
                    continuation.finish(throwing: NSError(
                        domain: "AppleFoundationService",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models are not available on this macOS version (Requires macOS 26.0+)"]
                    ))
                }
                #else
                continuation.finish(throwing: NSError(
                    domain: "AppleFoundationService",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework is not imported."]
                ))
                #endif
            }
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private class InnerFoundationHandler {
        private var session: LanguageModelSession?

        init() {
            self.session = LanguageModelSession(instructions: Instructions("You are a helpful assistant found in the Prism menu bar app."))
            Task {
                self.session?.prewarm()
            }
        }

        func stream(history: [Message], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
            return AsyncThrowingStream { continuation in
                Task {
                    guard let session = self.session else {
                        continuation.finish(throwing: NSError(domain: "AppleFoundationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session not initialized"]))
                        return
                    }

                    // Separate valid history from the last new message
                    let validHistory = history.filter { !$0.content.isEmpty }
                    let pastMessages = validHistory.dropLast()
                    let lastMessage = validHistory.last
                    
                    let contextString = pastMessages.map { msg in
                        let role = msg.isUser ? "User" : "Assistant"
                        return "\(role): \(msg.content)" 
                    }.joined(separator: "\n")
                    
                    let currentPrompt = lastMessage?.content ?? ""
                    let sysInstruction = systemPrompt.isEmpty ? "You are a helpful and friendly AI assistant." : systemPrompt

                    let finalPrompt = """
                     SYSTEM INSTRUCTIONS:
                     \(sysInstruction)
                     
                     CONTEXT:
                     \(contextString)
                     
                     CURRENT REQUEST:
                     User: \(currentPrompt)
                     
                     INSTRUCTIONS:
                     Respond to the CURRENT REQUEST. Use the CONTEXT for continuity but do not repeat it.
                     Provide a direct, helpful response in Markdown format.
                     Do not start with "Assistant:" or "User:".
                     """
                    
                    do {
                        let stream = session.streamResponse(
                            generating: String.self,
                            includeSchemaInPrompt: false,
                            options: GenerationOptions(sampling: .random(top: 1)),
                            prompt: {
                                Prompt(finalPrompt)
                            }
                        )
                        
                        var lastLength = 0
                        for try await partialResponse in stream {
                            // Convert partialResponse to String.
                            // 'String(describing:)' produced 'Snapshot(...)', so we need a cleaner way.
                            // Since ChatDetailView uses it as a String (via coalescing), we treat it as such.
                            // We attempt to utilize string interpolation simply, but if that fails (Snapshot...),
                            // we must find the content.
                            // Given 'Snapshot(content: "...")', we parse it as a fallback.
                            
                            let rawDescription = String(describing: partialResponse)
                            let currentText: String
                            
                            if rawDescription.hasPrefix("Snapshot(content: \"") {
                                // Extract content from: Snapshot(content: "TEXT", rawContent: ...)
                                // Simplistic parsing:
                                if let rangeStart = rawDescription.range(of: "content: \""),
                                   let rangeEnd = rawDescription.range(of: "\", rawContent:", range: rangeStart.upperBound..<rawDescription.endIndex) {
                                    let content = rawDescription[rangeStart.upperBound..<rangeEnd.lowerBound]
                                    currentText = String(content)
                                        .replacingOccurrences(of: "\\\"", with: "\"")
                                        .replacingOccurrences(of: "\\'", with: "'") 
                                        .replacingOccurrences(of: "\\\\", with: "\\")
                                        .replacingOccurrences(of: "\\n", with: "\n")
                                        .replacingOccurrences(of: "\\t", with: "\t")
                                } else {
                                    currentText = rawDescription
                                }
                            } else {
                                currentText = rawDescription
                            }
                            
                            let currentLength = currentText.count
                            
                            if currentLength > lastLength {
                                let deltaIndex = currentText.index(currentText.startIndex, offsetBy: lastLength)
                                let delta = String(currentText[deltaIndex...])
                                continuation.yield(delta)
                                lastLength = currentLength
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
    #endif
}
