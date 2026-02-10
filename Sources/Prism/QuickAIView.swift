import AppKit
import SwiftUI

struct QuickAIView: View {
    var onResize: ((CGSize) -> Void)?
    var onClose: (() -> Void)?

    @ObservedObject var chatManager = ChatManager.shared
    @State private var inputText: String = ""
    @State private var inputLineCount: Int = 1
    @State private var isLoading: Bool = false
    @AppStorage("selectedProvider") private var selectedProvider: String = "Apple Foundation Model"
    @State private var thinkingLevel: String = "medium"
    @State private var isExpanded: Bool = false
    @State private var expandedContentOpacity: Double = 0
    @State private var headerOffset: CGFloat = 20
    @State private var messagesOffset: CGFloat = 30
    @State private var backgroundScale: CGFloat = 0.92
    @State private var backgroundBlur: CGFloat = 0
    @State private var selectedPDF: Data? = nil
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var slashCommandManager = SlashCommandManager.shared
    @State private var slashMatches: [SlashCommand] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var showSlashAutocomplete: Bool = false

    // Settings
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @State private var streamBuffer: [UUID: String] = [:]  // live text per message
    @State private var streamThinkingBuffer: [UUID: String] = [:]  // live reasoning per message
    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"
    @AppStorage("ShortcutOnDevice") private var shortcutOnDevice: String = "Ask AI Device"
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("QuickAIBackgroundOpacity") private var backgroundOpacity: Double = 0.18
    @AppStorage("QuickAICommandBarVibrancy") private var commandBarVibrancy: Double = 0.55
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""
    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.05), 0.55)
    }
    private var clampedCommandBarVibrancy: Double {
        min(max(commandBarVibrancy, 0.05), 0.9)
    }

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let shortcutService = ShortcutService()
    private let appleFoundationService = AppleFoundationService()
    private let webSearchService = WebSearchService()
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("WebSearchEnabled") private var webSearchEnabled: Bool = false
    @State private var showOpacityPopover: Bool = false
    @AppStorage("ActiveToolName") private var activeToolName: String = ""

    // Custom spring animation for ultra-smooth transitions
    private var expandAnimation: Animation {
        .spring(response: 0.5, dampingFraction: 0.82, blendDuration: 0.1)
    }

    private var staggeredExpandAnimation: Animation {
        .spring(response: 0.55, dampingFraction: 0.78, blendDuration: 0.08)
    }

    private var collapseAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.05)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isExpanded {
                    VStack(spacing: 12) {
                        // Tool access banner
                        if !activeToolName.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("Currently viewing **\(activeToolName)** tool")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    activeToolName = ""
                                    chatManager.createNewSession()
                                    withAnimation(collapseAnimation) {
                                        isExpanded = false
                                    }
                                }) {
                                    Text("New Chat")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary.opacity(0.8))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(Color.secondary.opacity(0.12))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.orange.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.orange.opacity(0.15), lineWidth: 0.5)
                                    )
                            )
                        }

                        headerSection
                        messagesSection
                    }
                    // ...existing code...
                    .padding(10)
                    .background(ExpandedPanelBackground(cornerRadius: 20))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    // ...existing code...
                    .compositingGroup()
                    .scaleEffect(backgroundScale, anchor: .bottom)
                    .blur(radius: backgroundBlur)
                    .padding(.bottom, 10)
                    .transition(
                        .asymmetric(
                            insertion: .modifier(
                                active: ExpandedPanelModifier(
                                    opacity: 0, offsetY: 40, scale: 0.88, blur: 8),
                                identity: ExpandedPanelModifier(
                                    opacity: 1, offsetY: 0, scale: 1, blur: 0)
                            ),
                            removal: .modifier(
                                active: ExpandedPanelModifier(
                                    opacity: 0, offsetY: 25, scale: 0.92, blur: 6),
                                identity: ExpandedPanelModifier(
                                    opacity: 1, offsetY: 0, scale: 1, blur: 0)
                            )
                        )
                    )
                }

                inputSection
            }

            // Floating slash command autocomplete - overlays above input
            if showSlashAutocomplete && !slashMatches.isEmpty {
                VStack {
                    Spacer()
                    SlashCommandAutocomplete(
                        matches: slashMatches,
                        selectedIndex: slashSelectedIndex,
                        onSelect: { command in
                            applySlashCommand(command)
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, isExpanded ? 72 : 62)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: 700)
        .onAppear {
            isFocused = true
            // Auto-expand if there's chat history
            if !chatManager.getCurrentMessages().isEmpty {
                isExpanded = true
            }

            recalcPanelSize()
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                // Staggered entrance animations
                withAnimation(staggeredExpandAnimation.delay(0.02)) {
                    backgroundScale = 1.0
                    backgroundBlur = 0
                }
                withAnimation(staggeredExpandAnimation.delay(0.06)) {
                    expandedContentOpacity = 1.0
                    headerOffset = 0
                }
                withAnimation(staggeredExpandAnimation.delay(0.1)) {
                    messagesOffset = 0
                }
            } else {
                // Smooth collapse animations
                withAnimation(collapseAnimation) {
                    messagesOffset = 15
                    expandedContentOpacity = 0
                    headerOffset = 10
                }
                withAnimation(collapseAnimation.delay(0.04)) {
                    backgroundScale = 0.94
                    backgroundBlur = 4
                }
            }
            recalcPanelSize()
        }
        .onChange(of: chatManager.getCurrentMessages().count) { _, count in
            // Auto-expand when messages arrive and keep the panel height consistent
            if count > 0 && !isExpanded {
                withAnimation(expandAnimation) {
                    isExpanded = true
                }
            } else if count == 0 && isExpanded {
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            }
            recalcPanelSize()
        }
    }

    func sendButtonStyle(darkened: Bool = false) -> AnyShapeStyle {
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 19 || hour < 7
        // In dark mode or at night, use a brighter punchy gradient for contrast
        if colorScheme == .dark || isNight {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(darkened ? 0.9 : 0.95),
                        Color.green.opacity(darkened ? 0.9 : 0.85),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.black.opacity(darkened ? 0.85 : 0.9),
                        Color.black.opacity(darkened ? 0.75 : 0.8),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    func recalcPanelSize() {
        let baseWidth: CGFloat = 700

        let font = NSFont.systemFont(ofSize: 16)
        let textToMeasure = inputText.isEmpty ? "Request..." : inputText
        let measureWidth = baseWidth - 32  // Horizontal padding

        let bounding = textToMeasure.boundingRect(
            with: CGSize(width: measureWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)

        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        let lines = min(6, max(1, Int(ceil(bounding.height / max(1, lineHeight)))))
        inputLineCount = lines

        let extraHeightPerLine = lineHeight * 0.82
        // Increased base heights to accommodate shadows and prevent clipping
        let baseHeight: CGFloat = isExpanded ? 550 : 110
        var targetHeight = baseHeight + CGFloat(max(0, lines - 1)) * extraHeightPerLine

        // Add extra height when slash command autocomplete is showing
        if showSlashAutocomplete && !slashMatches.isEmpty {
            let autocompleteHeight = min(CGFloat(slashMatches.count) * 44 + 40, 280)
            targetHeight += autocompleteHeight
        }

        onResize?(CGSize(width: baseWidth, height: targetHeight))
    }

    func getProviderIcon(_ provider: String) -> String {
        switch provider {
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "ChatGPT": return "message"
        default: return "cpu"
        }
    }

    // MARK: - Slash Command Helpers

    private func updateSlashAutocomplete(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            let matches = slashCommandManager.matches(for: trimmed)
            slashMatches = matches
            slashSelectedIndex = 0
            showSlashAutocomplete = !matches.isEmpty
        } else {
            showSlashAutocomplete = false
            slashMatches = []
        }
        // Single deferred resize after all state is settled
        DispatchQueue.main.async { [self] in
            recalcPanelSize()
        }
    }

    private func applySlashCommand(_ command: SlashCommand) {
        showSlashAutocomplete = false
        slashMatches = []

        if slashCommandManager.isActionCommand(command.trigger) {
            inputText = ""
            switch command.trigger {
            case "/clear":
                activeToolName = ""
                chatManager.deleteCurrentSession()
                chatManager.createNewSession()
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            case "/quit":
                NSApplication.shared.terminate(nil)
            case "/new":
                activeToolName = ""
                chatManager.createNewSession()
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            default:
                break
            }
        } else {
            inputText = command.expansion + " "
        }
        DispatchQueue.main.async {
            recalcPanelSize()
        }
    }

    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if !isExpanded {
            withAnimation(expandAnimation) {
                isExpanded = true
            }
        }

        let content = inputText
        let pdfData = selectedPDF
        inputText = ""
        selectedPDF = nil
        recalcPanelSize()

        let userMsg = Message(content: content, image: nil, pdfData: pdfData, isUser: true)
        chatManager.addMessage(userMsg)
        isLoading = true

        chatManager.currentTask = Task {
            if selectedProvider == "Gemini API" {
                if !geminiKey.isEmpty {
                    let aiMsgId = UUID()
                    var aiMsg = Message(content: "", model: geminiModel, isUser: false)
                    aiMsg.id = aiMsgId
                    aiMsg.isStreaming = true

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk, _)
                            in geminiService.sendMessageStream(
                                history: chatManager.getCurrentMessages(), apiKey: geminiKey,
                                model: geminiModel, systemPrompt: systemPrompt,
                                thinkingLevel: thinkingLevel)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentToUpdate = fullContent
                                let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.chatManager.updateMessage(
                                        id: aiMsgId, content: contentToUpdate,
                                        thinkingContent: thinkingToUpdate, isStreaming: true)
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: fullContent,
                                thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: "Error: \(error.localizedDescription)",
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Please set your API Key in the main app settings.",
                            isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Apple Foundation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", model: "Apple Foundation", isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    var accumulatedContent = ""
                    var lastUpdateTime = Date()

                    for try await contentSnapshot in appleFoundationService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), systemPrompt: systemPrompt
                    ) {
                        accumulatedContent += contentSnapshot

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentToUpdate = accumulatedContent
                            DispatchQueue.main.async {
                                self.chatManager.updateMessage(
                                    id: aiMsgId, content: contentToUpdate, isStreaming: true)
                            }
                            lastUpdateTime = Date()
                        }
                    }

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: accumulatedContent, isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider.contains("Ollama") {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", isUser: false)
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                    self.streamBuffer[aiMsgId] = ""
                    self.streamThinkingBuffer[aiMsgId] = ""
                }

                let activeModel = selectedOllamaModel

                // Web search augmentation (Ollama only)
                var ollamaSystemPrompt = systemPrompt
                if webSearchEnabled && !ollamaAPIKey.isEmpty {
                    do {
                        let searchResults = try await webSearchService.search(
                            query: content, apiKey: ollamaAPIKey)
                        let searchContext = webSearchService.buildSearchContext(
                            results: searchResults)
                        if !searchContext.isEmpty {
                            ollamaSystemPrompt = systemPrompt + searchContext
                        }
                    } catch {
                        print("Web search failed: \(error.localizedDescription)")
                    }
                }

                do {
                    var fullContent = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()

                    for try await (contentChunk, thinkingChunk) in ollamaService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), endpoint: ollamaURL,
                        model: activeModel, systemPrompt: ollamaSystemPrompt,
                        thinkingLevel: thinkingLevel
                    ) {
                        fullContent += contentChunk
                        if let thinking = thinkingChunk {
                            fullThinking += thinking
                        }

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            // Update live buffers only (avoid heavy state writes)
                            let contentSnapshot = fullContent
                            let thinkingSnapshot = fullThinking
                            DispatchQueue.main.async {
                                self.streamBuffer[aiMsgId] = contentSnapshot
                                if thinkingSnapshot.isEmpty {
                                    self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                                } else {
                                    self.streamThinkingBuffer[aiMsgId] = thinkingSnapshot
                                }
                            }
                            lastUpdateTime = Date()
                        }
                    }

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId,
                            content: fullContent,
                            thinkingContent: fullThinking.isEmpty ? nil : fullThinking
                        )
                        self.chatManager.finalizeMessageUpdate()
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)")
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else {
                // Shortcuts
                let shortcutName: String
                switch selectedProvider {
                case "Private Cloud": shortcutName = shortcutPrivateCloud
                case "On-Device": shortcutName = shortcutOnDevice
                case "ChatGPT": shortcutName = shortcutChatGPT
                default: shortcutName = shortcutPrivateCloud
                }

                // Build transcript
                var transcript = "Please reply to the last message:\n\n"
                for msg in chatManager.getCurrentMessages().suffix(5) {
                    let role = msg.isUser ? "User" : "Assistant"
                    transcript += "\(role): \(msg.content)\n"
                }
                transcript += "Assistant:"

                do {
                    let result = try await shortcutService.runShortcut(
                        name: shortcutName, input: transcript, image: nil)
                    DispatchQueue.main.async {
                        let aiMsg = Message(content: result.0, image: nil, isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Error: \(error.localizedDescription)", isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

extension QuickAIView {
    @ViewBuilder
    func thinkingOption(title: String, value: String) -> some View {
        Button(action: { thinkingLevel = value }) {
            HStack {
                Text(title)
                Spacer()
                if thinkingLevel == value {
                    Image(systemName: "checkmark")
                        .foregroundColor(colorScheme == .dark ? .white : .accentColor)
                }
            }
        }
    }
}

struct QuickAIMessageView: View, Equatable {
    let message: Message
    var liveContent: String? = nil
    var liveThinking: String? = nil
    @State private var isCopied = false
    @State private var isPasted = false
    @State private var isCursorVisible = true
    @State private var isThinkingExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    static func == (lhs: QuickAIMessageView, rhs: QuickAIMessageView) -> Bool {
        return lhs.message == rhs.message && lhs.liveContent == rhs.liveContent
            && lhs.liveThinking == rhs.liveThinking
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let image = message.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture {
                                previewImage(image)
                            }
                            .contextMenu {
                                Button("Copy Image") {
                                    copyImage(image)
                                }
                                Button("Take me to chat") {
                                    openInMainWindow()
                                }
                            }
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 14))
                            .padding(12)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.92), Color.cyan.opacity(0.7)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if message.isGeneratingImage == true {
                        GeneratingImagePlaceholder()
                    } else {
                        if let thinking = (liveThinking ?? message.thinkingContent) {
                            DisclosureGroup(isExpanded: $isThinkingExpanded) {
                                Text(thinking)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.caption)
                                    Text("Reasoning Process")
                                        .font(.caption)
                                }
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .contentShape(Rectangle())
                            }
                            .animation(
                                .spring(response: 0.35, dampingFraction: 0.86),
                                value: isThinkingExpanded
                            )
                            .padding(.bottom, 4)
                        }

                        if let image = message.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 300, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    Button("Copy Image") {
                                        copyImage(image)
                                    }
                                    Button("Go to chat") {
                                        openInMainWindow()
                                    }
                                }
                        }

                        let activeContent = liveContent ?? message.content

                        if message.isStreaming && activeContent.isEmpty
                            && (liveThinking ?? message.thinkingContent) == nil
                        {
                            ThinkingIndicator()
                        } else if !activeContent.isEmpty || message.isStreaming {
                            let displayContent =
                                activeContent + (message.isStreaming && isCursorVisible ? " ▋" : "")
                            MarkdownView(blocks: Message.parseMarkdown(displayContent))
                                .fixedSize(horizontal: false, vertical: true)
                                .id("streamingMarkdown")
                        }

                        // Copy Button
                        HStack(spacing: 8) {
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                if let image = message.image {
                                    pasteboard.writeObjects([image])
                                } else {
                                    pasteboard.setString(message.content, forType: .string)
                                }
                                isCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    isCopied = false
                                }
                            }) {
                                Label(
                                    isCopied ? "Copied" : "Copy",
                                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                                )
                                .font(.caption2)
                                .foregroundColor(isCopied ? .green : .secondary)
                                .padding(4)
                                .background(Color.black.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            // Paste to App button (only for text content)
                            if message.image == nil && !message.content.isEmpty {
                                Button(action: {
                                    QuickAIManager.shared.pasteToActiveApp(text: message.content)
                                }) {
                                    Label(
                                        "Paste to App",
                                        systemImage: "arrow.up.doc"
                                    )
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(4)
                                    .background(Color.black.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .help("Paste this response into the previous app")
                            }

                            Spacer()
                        }

                        // Model disclaimer
                        if let model = message.model {
                            let displayModel = GeminiModelManager.displayNames[model] ?? model
                            Text("Model used: \(displayModel). Information could be inaccurate.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.8))
                                .padding(.top, 2)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer()
            }
        }
        .onReceive(cursorTimer) { _ in
            if message.isStreaming {
                isCursorVisible.toggle()
            }
        }
        .onChange(of: liveThinking) { _, newValue in
            if let val = newValue, !val.isEmpty, liveContent == nil || liveContent!.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = true
                }
            }
        }
        .onChange(of: liveContent) { _, newValue in
            if let val = newValue, !val.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = false
                }
            }
        }
    }

    private func copyImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func previewImage(_ image: NSImage) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("Prism_Preview_\(UUID().uuidString).png")
        if let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try? png.write(to: fileURL)
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func openInMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find main window (approximate by filtering out panels) and order front
        // In a typical app, the main window is the one that's not the QuickAI panel
        // and usually isn't an NSPanel unless it's a utility style
        // We'll trust NSApp.activate to do most of the work, but we should unhide the app
        NSApp.unhide(nil)

        for window in NSApp.windows {
            // Filter out QuickAI Panel by its known frame size or controller type if possible,
            // or just order forward normal windows.
            // Since we can't easily check 'is QuickAIPanel' due to type scope, checking title or style helps.
            // But relying on unhide + activate is usually sufficient for single-window apps.
            // If the main window was closed, we might need new implementation, but let's assume it's just hidden/backgrounded.
            if window.isVisible && !(window.styleMask.contains(.nonactivatingPanel)) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

struct CommandBarBackground: View {
    var cornerRadius: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuickAICommandBarVibrancy") private var commandBarVibrancy: Double = 0.55
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    var body: some View {
        let colors = appTheme.colors

        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(colorScheme == .dark ? 0.34 : 0.44),
                    location: 0.0),
                .init(
                    color: endColor.opacity(colorScheme == .dark ? 0.30 : 0.38),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial.opacity(min(max(commandBarVibrancy, 0.05), 0.9)))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5)
        }
    }
}

struct ExpandedPanelBackground: View {
    var cornerRadius: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuickAIBackgroundOpacity") private var backgroundOpacity: Double = 0.18
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.05), 0.55)
    }

    var body: some View {
        let colors = appTheme.colors

        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        // Much subtler gradient for the message area
        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(colorScheme == .dark ? 0.08 : 0.12),
                    location: 0.0),
                .init(
                    color: endColor.opacity(colorScheme == .dark ? 0.05 : 0.08),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            // Base layer - adaptive fill
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    (colorScheme == .dark ? Color.black : Color.white).opacity(
                        colorScheme == .dark
                            ? clampedBackgroundOpacity + 0.08
                            : clampedBackgroundOpacity
                    )
                )

            // Gradient tint
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)

            // Material blur
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    .ultraThinMaterial.opacity(
                        colorScheme == .dark
                            ? clampedBackgroundOpacity + 0.16
                            : clampedBackgroundOpacity + 0.12
                    )
                )
        }
    }
}

struct GeneratingImagePlaceholder: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) var colorScheme

    @State private var orbPhase1: CGFloat = 0
    @State private var orbPhase2: CGFloat = 0
    @State private var orbPhase3: CGFloat = 0
    @State private var pulseScale: CGFloat = 0.92
    @State private var shimmerPhase: CGFloat = 0
    @State private var rotationAngle: Double = 0

    private var themeColors: (Color, Color) {
        let colors = appTheme.colors
        return (colors.first ?? .blue, colors.last ?? .purple)
    }

    var body: some View {
        let (startColor, endColor) = themeColors
        let midColor = Color(
            hue: 0.5,
            saturation: 0.6,
            brightness: colorScheme == .dark ? 0.8 : 0.9
        )

        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.5)
                        : Color.white.opacity(0.5)
                )

            // Aurora gradient layer - slowly rotating
            ZStack {
                // Orb 1 - top-left drift
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                startColor.opacity(0.6),
                                startColor.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .offset(
                        x: -40 + 30 * cos(orbPhase1 * .pi * 2),
                        y: -40 + 25 * sin(orbPhase1 * .pi * 2 * 1.3)
                    )
                    .blur(radius: 30)
                    .animation(
                        .linear(duration: 4.0).repeatForever(autoreverses: false), value: orbPhase1)

                // Orb 2 - bottom-right drift
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                endColor.opacity(0.55),
                                endColor.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                    .offset(
                        x: 35 + 25 * sin(orbPhase2 * .pi * 2),
                        y: 35 + 30 * cos(orbPhase2 * .pi * 2 * 0.8)
                    )
                    .blur(radius: 25)
                    .animation(
                        .linear(duration: 5.5).repeatForever(autoreverses: false), value: orbPhase2)

                // Orb 3 - center float
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                midColor.opacity(0.45),
                                midColor.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .offset(
                        x: 15 * sin(orbPhase3 * .pi * 2 * 1.5),
                        y: -10 + 20 * cos(orbPhase3 * .pi * 2)
                    )
                    .blur(radius: 20)
                    .animation(
                        .linear(duration: 6.0).repeatForever(autoreverses: false), value: orbPhase3)
            }
            .rotationEffect(.degrees(rotationAngle))
            .animation(
                .linear(duration: 20.0).repeatForever(autoreverses: false), value: rotationAngle
            )
            .scaleEffect(pulseScale)
            .animation(
                .easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulseScale)

            // Mesh-like overlay shimmer
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        .clear,
                        (colorScheme == .dark ? Color.white : Color.black).opacity(
                            colorScheme == .dark ? 0.08 : 0.12),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: geo.size.width * 1.0 - geo.size.width * 1.3 * shimmerPhase)
                .animation(
                    .easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: shimmerPhase
                )
                .rotationEffect(.degrees(25))
            }
            .mask(RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Center icon
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 48, height: 48)
                        .shadow(
                            color: startColor.opacity(0.3),
                            radius: 12, x: 0, y: 4
                        )

                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(pulseScale > 0.96 ? 1.05 : 0.95)
                        .animation(
                            .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                            value: pulseScale)
                }

                Text("Generating")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark ? .white : .primary,
                                .secondary,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                // Animated dots — sequential left-to-right wave
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let cycleDuration: Double = 1.2
                    let dotDelay: Double = 0.2
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            let phase =
                                ((now - Double(i) * dotDelay).truncatingRemainder(
                                    dividingBy: cycleDuration)) / cycleDuration
                            // Smooth bump: rises then falls, spending time at rest
                            let bump = max(0, sin(phase * .pi * 2 - .pi * 0.5) * 0.5 + 0.5)
                            let scale = 0.6 + 0.8 * bump
                            let opacity = 0.3 + 0.7 * bump
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [startColor, endColor],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 5, height: 5)
                                .scaleEffect(scale)
                                .opacity(opacity)
                        }
                    }
                }
            }

            // Glass border
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.15)
                                : Color.white.opacity(0.6),
                            colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.black.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(
            color: startColor.opacity(colorScheme == .dark ? 0.2 : 0.1),
            radius: 20, x: 0, y: 8
        )
        .onAppear {
            orbPhase1 = 1
            orbPhase2 = 1
            orbPhase3 = 1
            pulseScale = 1.04
            shimmerPhase = 1
            rotationAngle = 360
        }
    }
}

// MARK: - Custom Transition Modifier for Smooth Expand/Collapse

struct ExpandedPanelModifier: ViewModifier {
    var opacity: Double
    var offsetY: CGFloat
    var scale: CGFloat
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offsetY)
            .scaleEffect(scale, anchor: .bottom)
            .blur(radius: blur)
    }
}

extension ExpandedPanelModifier: Animatable {
    var animatableData:
        AnimatablePair<AnimatablePair<Double, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    {
        get {
            AnimatablePair(AnimatablePair(opacity, offsetY), AnimatablePair(scale, blur))
        }
        set {
            opacity = newValue.first.first
            offsetY = newValue.first.second
            scale = newValue.second.first
            blur = newValue.second.second
        }
    }
}

extension QuickAIView {

    private var headerSection: some View {
        HStack {
            Menu {
                Section("Apple Intelligence") {
                    Button(action: { selectedProvider = "Apple Foundation" }) {
                        Label(
                            "Apple Foundation",
                            systemImage: getProviderIcon("Apple Foundation"))
                    }
                }
                .opacity(expandedContentOpacity)
                .offset(y: headerOffset)
                Section("API") {
                    Button(action: { selectedProvider = "Gemini API" }) {
                        Label(
                            "Gemini API", systemImage: getProviderIcon("Gemini API")
                        )
                    }
                    Button(action: { selectedProvider = "Ollama" }) {
                        Label("Ollama", systemImage: getProviderIcon("Ollama"))
                    }
                }
                Section("Shortcuts") {
                    Button(action: { selectedProvider = "Private Cloud" }) {
                        Label(
                            "Private Cloud",
                            systemImage: getProviderIcon("Private Cloud"))
                    }
                    Button(action: { selectedProvider = "On-Device" }) {
                        Label(
                            "On-Device", systemImage: getProviderIcon("On-Device"))
                    }
                    Button(action: { selectedProvider = "ChatGPT" }) {
                        Label("ChatGPT", systemImage: getProviderIcon("ChatGPT"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: getProviderIcon(selectedProvider))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                    Text(selectedProvider)
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.gray.opacity(colorScheme == .dark ? 0.18 : 0.14)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    Color.white.opacity(
                                        colorScheme == .dark ? 0.22 : 0.18),
                                    lineWidth: 0.8
                                )
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // New Chat
            Button(action: {
                activeToolName = ""
                chatManager.createNewSession()
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            }) {
                Image(systemName: "square.and.pencil")
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                Color.gray.opacity(
                                    colorScheme == .dark ? 0.18 : 0.14)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        Color.white.opacity(
                                            colorScheme == .dark ? 0.22 : 0.18),
                                        lineWidth: 0.8
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(expandedContentOpacity)
        .offset(y: headerOffset)
    }

    private var messagesSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(chatManager.getCurrentMessages()) { message in
                        QuickAIMessageView(
                            message: message,
                            liveContent: streamBuffer[message.id],
                            liveThinking: streamThinkingBuffer[message.id]
                        )
                        .equatable()
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: chatManager.getCurrentMessages().count) { _, _ in
                if let lastId = chatManager.getCurrentMessages().last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            // Auto-scroll during generation
            .onChange(of: chatManager.getCurrentMessages().last?.content.count) { _, _ in
                if let lastId = chatManager.getCurrentMessages().last?.id,
                    chatManager.getCurrentMessages().last?.isStreaming == true
                {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: streamBuffer) { _, _ in
                if let lastId = chatManager.getCurrentMessages().last?.id, isLoading {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: isLoading) { _, loading in
                if loading {
                    withAnimation {
                        proxy.scrollTo("loading", anchor: .bottom)
                    }
                }
            }
        }
        .opacity(expandedContentOpacity)
        .offset(y: messagesOffset)
    }

    private var inputSection: some View {
        VStack(spacing: 8) {
            if let pdfData = selectedPDF {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(.red)
                    Text("PDF attached (\(pdfData.count / 1024) KB)")
                        .font(.caption)
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: { selectedPDF = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("Request... (type / for commands)")
                            .font(.system(size: 16))
                            .foregroundColor(
                                colorScheme == .dark ? .white.opacity(0.4) : .black.opacity(0.4)
                            )
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .lineLimit(1...6)
                        .multilineTextAlignment(.leading)
                        .focused($isFocused)
                        .onChange(of: inputText) { _, newValue in
                            updateSlashAutocomplete(newValue)
                        }
                        .onKeyPress(.upArrow) {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                slashSelectedIndex = max(0, slashSelectedIndex - 1)
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.downArrow) {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                slashSelectedIndex = min(
                                    slashMatches.count - 1, slashSelectedIndex + 1)
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.tab) {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                applySlashCommand(slashMatches[slashSelectedIndex])
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.escape) {
                            if showSlashAutocomplete {
                                showSlashAutocomplete = false
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.return) {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                applySlashCommand(slashMatches[slashSelectedIndex])
                                return .handled
                            }
                            sendMessage()
                            return .handled
                        }
                        .onPasteCommand(of: [.fileURL, .pdf]) { providers in
                            for provider in providers {
                                if provider.hasItemConformingToTypeIdentifier("com.adobe.pdf") {
                                    provider.loadItem(
                                        forTypeIdentifier: "com.adobe.pdf", options: nil
                                    ) { urlData, _ in
                                        if let urlData = urlData as? Data,
                                            let url = URL(
                                                dataRepresentation: urlData, relativeTo: nil),
                                            let data = try? Data(contentsOf: url)
                                        {
                                            DispatchQueue.main.async {
                                                self.selectedPDF = data
                                            }
                                        }
                                    }
                                } else if provider.hasItemConformingToTypeIdentifier(
                                    "public.file-url")
                                {
                                    provider.loadItem(
                                        forTypeIdentifier: "public.file-url", options: nil
                                    ) { urlData, _ in
                                        if let urlData = urlData as? Data,
                                            let url = URL(
                                                dataRepresentation: urlData, relativeTo: nil)
                                        {
                                            if url.pathExtension.lowercased() == "pdf",
                                                let data = try? Data(contentsOf: url)
                                            {
                                                DispatchQueue.main.async {
                                                    self.selectedPDF = data
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                }

                // Thinking Level Selector
                if selectedProvider.contains("Ollama") {
                    Menu {
                        Section("Favorites") {
                            ForEach(ollamaManager.favoriteModels, id: \.self) { model in
                                Button(action: { selectedOllamaModel = model }) {
                                    if selectedOllamaModel == model {
                                        Label(model, systemImage: "checkmark")
                                            .foregroundColor(
                                                colorScheme == .dark ? .white : .primary)
                                    } else {
                                        Text(model)
                                    }
                                }
                            }
                        }

                        ForEach(ollamaManager.sortedManufacturers, id: \.self) { manufacturer in
                            let models = ollamaManager.availableModels
                                .filter { !ollamaManager.isFavorite($0) }
                                .filter { ollamaManager.getManufacturer(for: $0) == manufacturer }

                            if !models.isEmpty {
                                Section(manufacturer) {
                                    ForEach(models, id: \.self) { model in
                                        Button(action: { selectedOllamaModel = model }) {
                                            if selectedOllamaModel == model {
                                                Label(model, systemImage: "checkmark")
                                                    .foregroundColor(
                                                        colorScheme == .dark ? .white : .primary)
                                            } else {
                                                Text(model)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("Manage Favorites") {
                            ForEach(ollamaManager.allModels, id: \.self) { model in
                                Button(action: { ollamaManager.toggleFavorite(model) }) {
                                    if ollamaManager.isFavorite(model) {
                                        Label(model, systemImage: "star.fill")
                                    } else {
                                        Label(model, systemImage: "star")
                                    }
                                }
                            }
                        }

                        Button(action: { showAddCustomOllamaModel = true }) {
                            Label("Add Custom Model...", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(6)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(colorScheme == .dark ? .white : .black)
                    .help("Select Ollama Model")
                    .alert("Add Custom Ollama Model", isPresented: $showAddCustomOllamaModel) {
                        TextField("Model Name (e.g., llama3:70b)", text: $newCustomModelName)
                        Button("Add") {
                            ollamaManager.addCustomModel(newCustomModelName)
                            selectedOllamaModel = newCustomModelName
                            newCustomModelName = ""
                        }
                        Button("Cancel", role: .cancel) {
                            newCustomModelName = ""
                        }
                    } message: {
                        Text("Enter the name of the model as it appears in Ollama.")
                    }

                    // Thinking logic
                    let lower = selectedOllamaModel.lowercased()
                    let mode: ThinkingMode =
                        lower.contains("deepseek")
                        ? .binary : (lower.contains("gpt-oss") ? .threeState : .none)

                    if mode != .none {
                        Menu {
                            if mode == .binary {
                                Button {
                                    thinkingLevel = "high"
                                } label: {
                                    if thinkingLevel == "high" {
                                        Label("Reasoning: On", systemImage: "checkmark")
                                            .foregroundColor(
                                                colorScheme == .dark ? .white : .primary)
                                    } else {
                                        Text("Reasoning: On")
                                    }
                                }
                                Button {
                                    thinkingLevel = "low"
                                } label: {
                                    if thinkingLevel != "high" {
                                        Label("Reasoning: Off", systemImage: "checkmark")
                                            .foregroundColor(
                                                colorScheme == .dark ? .white : .primary)
                                    } else {
                                        Text("Reasoning: Off")
                                    }
                                }
                            } else {
                                thinkingOption(title: "Low", value: "low")
                                thinkingOption(title: "Medium", value: "medium")
                                thinkingOption(title: "High", value: "high")
                            }
                        } label: {
                            Image(systemName: "brain")
                                .font(.system(size: 16))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .padding(6)
                                .background(Color.white.opacity(0.10))
                                .clipShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .tint(colorScheme == .dark ? .white : .black)
                        .help("Reasoning Effort")
                    }
                } else if selectedProvider == "Gemini API" {
                    Menu {
                        Section("Favorites") {
                            ForEach(geminiManager.favoriteModels, id: \.self) { model in
                                Button(action: { geminiModel = model }) {
                                    if geminiModel == model {
                                        Label(model, systemImage: "checkmark")
                                            .foregroundColor(
                                                colorScheme == .dark ? .white : .primary)
                                    } else {
                                        Text(model)
                                    }
                                }
                            }
                        }

                        ForEach(GeminiModelManager.modelGroups, id: \.name) { group in
                            let nonFavModels = group.models.filter { !geminiManager.isFavorite($0) }
                            if !nonFavModels.isEmpty {
                                Section(group.name) {
                                    ForEach(nonFavModels, id: \.self) { model in
                                        Button(action: { geminiModel = model }) {
                                            if geminiModel == model {
                                                Label(model, systemImage: "checkmark")
                                                    .foregroundColor(
                                                        colorScheme == .dark ? .white : .primary)
                                            } else {
                                                Text(model)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("Manage Favorites") {
                            ForEach(geminiManager.availableModels, id: \.self) { model in
                                Button(action: { geminiManager.toggleFavorite(model) }) {
                                    if geminiManager.isFavorite(model) {
                                        Label(model, systemImage: "star.fill")
                                    } else {
                                        Label(model, systemImage: "star")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(6)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(colorScheme == .dark ? .white : .black)
                    .help("Select Gemini Model")

                    // Gemini thinking menu
                    if geminiModel.lowercased().hasPrefix("gemini-3")
                        || geminiModel.lowercased().hasPrefix("gemini-2.5")
                    {
                        let isGemini3Pro = geminiModel.lowercased().hasPrefix("gemini-3-pro")
                        Menu {
                            Button {
                                thinkingLevel = "auto"
                            } label: {
                                if thinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                                } else {
                                    Text("Auto")
                                }
                            }
                            thinkingOption(title: "Low", value: "low")
                            if !isGemini3Pro {
                                thinkingOption(title: "Medium", value: "medium")
                            }
                            thinkingOption(title: "High", value: "high")
                        } label: {
                            Image(systemName: "brain")
                                .font(.system(size: 16))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .padding(6)
                                .background(Color.white.opacity(0.10))
                                .clipShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .tint(colorScheme == .dark ? .white : .black)
                        .help("Reasoning Effort")
                    }
                }

                // Web Search Toggle (Ollama only)
                if !ollamaAPIKey.isEmpty && selectedProvider.contains("Ollama") {
                    Button(action: { webSearchEnabled.toggle() }) {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(6)
                            .background(
                                webSearchEnabled
                                    ? Color.blue.opacity(0.15)
                                    : Color.white.opacity(0.10)
                            )
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(webSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.monochrome)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || isLoading)
            }
            .padding(16)
            .background(CommandBarBackground(cornerRadius: 20))
        }
    }
}

struct ThinkingIndicator: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @State private var isAnimating = false

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .purple

        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [startColor, endColor], startPoint: .topLeading,
                            endPoint: .bottomTrailing), lineWidth: 2
                    )
                    .frame(width: 16, height: 16)
                    .opacity(isAnimating ? 0.3 : 1.0)
                    .scaleEffect(isAnimating ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: isAnimating)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [startColor, endColor], startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    )
                    .frame(width: 8, height: 8)
                    .scaleEffect(isAnimating ? 0.8 : 1.2)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: isAnimating)
            }
            .onAppear {
                isAnimating = true
            }

            Text("Thinking...")
                .font(.system(size: 14))
                .foregroundStyle(
                    LinearGradient(
                        colors: [startColor.opacity(0.8), endColor.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing)
                )
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}
