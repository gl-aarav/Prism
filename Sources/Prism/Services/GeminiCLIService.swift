import Foundation

class GeminiCLIService: ObservableObject {
    static let shared = GeminiCLIService()

    @Published var isAvailable: Bool = false
    @Published var cliPath: String = ""

    init() {
        detectCLI()
    }

    func detectCLI() {
        let searchPaths = [
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "\(NSHomeDirectory())/.local/bin/gemini",
            "\(NSHomeDirectory())/google-cloud-sdk/bin/gemini",
            "/usr/bin/gemini",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cliPath = path
                isAvailable = true
                return
            }
        }

        // Try `which gemini`
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "gemini"]

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !path.isEmpty,
                FileManager.default.isExecutableFile(atPath: path)
            {
                cliPath = path
                isAvailable = true
            }
        } catch {
            isAvailable = false
        }
    }

    func sendMessage(
        prompt: String,
        systemPrompt: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                guard isAvailable else {
                    continuation.finish(
                        throwing: NSError(
                            domain: "GeminiCLI", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Gemini CLI not found. Install it with: npm install -g @anthropic-ai/gemini-cli or pip install google-gemini-cli"
                            ]))
                    return
                }

                let task = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = Pipe()

                task.standardOutput = outputPipe
                task.standardError = errorPipe
                task.standardInput = inputPipe
                task.executableURL = URL(fileURLWithPath: self.cliPath)

                // Build the full prompt
                var fullPrompt = ""
                if !systemPrompt.isEmpty {
                    fullPrompt += "System: \(systemPrompt)\n\n"
                }
                fullPrompt += prompt

                task.arguments = ["-p", fullPrompt]

                // Inherit PATH so gemini CLI can find its dependencies
                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                let extraPaths = [
                    "/usr/local/bin",
                    "/opt/homebrew/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/google-cloud-sdk/bin",
                ]
                if let existingPath = env["PATH"] {
                    env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                }
                task.environment = env

                do {
                    try task.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let handle = outputPipe.fileHandleForReading

                // Stream output chunk by chunk
                handle.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        continuation.yield(text)
                    }
                }

                task.terminationHandler = { process in
                    handle.readabilityHandler = nil

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg =
                            String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                        if !errorMsg.isEmpty {
                            continuation.finish(
                                throwing: NSError(
                                    domain: "GeminiCLI", code: Int(process.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: errorMsg]))
                        } else {
                            continuation.finish()
                        }
                    } else {
                        continuation.finish()
                    }
                }
            }
        }
    }

    func sendMessageStream(
        history: [Message],
        systemPrompt: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        // Build conversation transcript from history
        var transcript = ""
        for msg in history {
            if msg.isUser {
                transcript += "User: \(msg.content)\n\n"
            } else {
                transcript += "Assistant: \(msg.content)\n\n"
            }
        }

        let lastUserMessage =
            history.last(where: { $0.isUser })?.content ?? transcript

        return sendMessage(prompt: lastUserMessage, systemPrompt: systemPrompt)
    }
}
