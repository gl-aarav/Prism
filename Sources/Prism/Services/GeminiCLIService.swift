import Foundation

class GeminiCLIService: ObservableObject {
    static let shared = GeminiCLIService()

    @Published var isAvailable: Bool = false
    @Published var cliPath: String = ""

    init() {
        // Check for a user-configured custom path first
        if let customPath = UserDefaults.standard.string(forKey: "GeminiCLIPath"),
            !customPath.isEmpty,
            FileManager.default.isExecutableFile(atPath: customPath)
        {
            cliPath = customPath
            isAvailable = true
        } else {
            // Run fast file-system checks synchronously (non-blocking)
            detectCLIFast()
            // Defer the slow shell-based detection to a background thread
            // to avoid blocking app launch
            if !isAvailable {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.detectCLISlow()
                }
            }
        }
    }

    /// Fast detection: only check known file paths (no subprocess)
    private func detectCLIFast() {
        let homeDir = NSHomeDirectory()
        let searchPaths = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(homeDir)/.local/bin/gemini",
            "\(homeDir)/.npm-global/bin/gemini",
            "\(homeDir)/google-cloud-sdk/bin/gemini",
            "/usr/bin/gemini",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cliPath = path
                isAvailable = true
                return
            }
        }
    }

    /// Slow detection: spawns a login shell to resolve PATH. Called on a background thread.
    private func detectCLISlow() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "which gemini"]

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !path.isEmpty,
                FileManager.default.isExecutableFile(atPath: path)
            {
                DispatchQueue.main.async { [weak self] in
                    self?.cliPath = path
                    self?.isAvailable = true
                }
            }
        } catch {
            // CLI not found — leave isAvailable as false
        }
    }

    func detectCLI() {
        detectCLIFast()
        if !isAvailable {
            detectCLISlow()
        }
    }

    /// Allow manually setting the CLI path from settings
    func setCustomPath(_ path: String) {
        if FileManager.default.isExecutableFile(atPath: path) {
            cliPath = path
            isAvailable = true
            UserDefaults.standard.set(path, forKey: "GeminiCLIPath")
        }
    }

    static let availableModels: [(id: String, name: String)] = [
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro"),
        ("gemini-3-flash-preview", "Gemini 3.0 Flash"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite")
    ]

    func displayName(for modelId: String) -> String {
        return Self.availableModels.first(where: { $0.id == modelId })?.name ?? modelId
    }

    func sendMessage(
        prompt: String,
        model: String = "",
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
                                    "Gemini CLI not found. Install it with: npm install -g @google/gemini-cli"
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

                var args = ["-p", fullPrompt]
                if !model.isEmpty {
                    args += ["-m", model]
                }
                task.arguments = args

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
        model: String = "",
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

        return sendMessage(prompt: lastUserMessage, model: model, systemPrompt: systemPrompt)
    }
}
