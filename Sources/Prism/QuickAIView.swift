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
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @AppStorage("GeminiThinkingLevel") private var geminiThinkingLevel: String = "auto"
    @State private var isExpanded: Bool = false
    @State private var expandedContentOpacity: Double = 0
    @State private var headerOffset: CGFloat = 20
    @State private var messagesOffset: CGFloat = 30
    @State private var backgroundScale: CGFloat = 0.92
    @State private var backgroundBlur: CGFloat = 0
    @State private var selectedAttachments: [Attachment] = []
    @State private var isFocused: Bool = false
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
        min(max(backgroundOpacity, 0.05), 1.0)
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
                                    .foregroundStyle(.orange)
                                Text("Currently viewing **\(activeToolName)** tool")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.primary.opacity(0.8))
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

                        messagesSection
                            .safeAreaInset(edge: .top) {
                                headerSection
                            }
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

        // Add extra height for attachment previews
        if !selectedAttachments.isEmpty {
            targetHeight += 100  // attachment strip height + padding
        }

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
        guard
            !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedAttachments.isEmpty
        else { return }

        if !isExpanded {
            withAnimation(expandAnimation) {
                isExpanded = true
            }
        }

        let content = inputText
        let currentAttachments = selectedAttachments
        inputText = ""
        selectedAttachments = []
        recalcPanelSize()

        // Build message attachments
        var legacyImage: NSImage?
        var legacyPDF: Data?
        var msgAttachments: [MessageAttachment] = []
        var augmentedContent = content
        for attachment in currentAttachments {
            let typeStr: String
            switch attachment.type {
            case .image: typeStr = "image"
            case .pdf: typeStr = "pdf"
            case .text: typeStr = "text"
            }
            msgAttachments.append(
                MessageAttachment(
                    type: typeStr, data: attachment.data, fileName: attachment.fileName))
            if attachment.type == .image && legacyImage == nil {
                legacyImage = NSImage(data: attachment.data)
            } else if attachment.type == .pdf && legacyPDF == nil {
                legacyPDF = attachment.data
            }
            if attachment.type == .text, let text = String(data: attachment.data, encoding: .utf8) {
                let name = attachment.fileName ?? "file"
                augmentedContent +=
                    "\n\n--- Contents of \(name) ---\n\(text)\n--- End of \(name) ---"
            }
        }

        let userMsg = Message(
            content: content, image: legacyImage, pdfData: legacyPDF,
            attachments: msgAttachments.isEmpty ? nil : msgAttachments, isUser: true)
        chatManager.addMessage(userMsg)

        performSend()
    }

    func regenerateResponse(for messageId: UUID) {
        var existingVersions: [MessageVersion]? = nil
        let messages = chatManager.getCurrentMessages()
        if let aiMsg = messages.first(where: { $0.id == messageId }) {
            let currentVersion = MessageVersion(
                content: aiMsg.content,
                thinkingContent: aiMsg.thinkingContent,
                imageData: aiMsg.imageData,
                model: aiMsg.model
            )
            if var vers = aiMsg.versions {
                if let idx = aiMsg.currentVersionIndex, idx < vers.count - 1 {
                    vers.removeSubrange((idx + 1)...)
                }
                if vers.last?.content != currentVersion.content
                    || vers.last?.imageData != currentVersion.imageData
                {
                    vers.append(currentVersion)
                }
                existingVersions = vers
            } else {
                existingVersions = [currentVersion]
            }
        }
        chatManager.truncateHistory(from: messageId)

        performSend(existingVersions: existingVersions)
    }

    func editAndResend(message: Message, newContent: String) {
        let currentMessages = chatManager.getCurrentMessages()
        if let lastMessage = currentMessages.last, !lastMessage.isUser {
            chatManager.removeLastMessage()
        }
        chatManager.removeLastMessage()

        let userMsg = Message(
            content: newContent,
            image: message.image,
            pdfData: message.pdfData,
            attachments: message.attachments,
            isUser: true
        )
        chatManager.addMessage(userMsg)

        performSend()
    }

    func performSend(existingVersions: [MessageVersion]? = nil) {
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
                        var receivedImage: NSImage? = nil
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk, imageData)
                            in geminiService.sendMessageStream(
                                history: chatManager.getCurrentMessages(), apiKey: geminiKey,
                                model: geminiModel, systemPrompt: systemPrompt,
                                thinkingLevel: geminiThinkingLevel)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }
                            if let imgData = imageData, let img = NSImage(data: imgData) {
                                receivedImage = img
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentToUpdate = fullContent
                                let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking
                                let imgToUpdate = receivedImage

                                DispatchQueue.main.async {
                                    self.chatManager.updateMessage(
                                        id: aiMsgId, content: contentToUpdate,
                                        thinkingContent: thinkingToUpdate,
                                        image: imgToUpdate,
                                        isStreaming: true)
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let finalImage = receivedImage
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: fullContent,
                                thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                                image: finalImage,
                                isStreaming: false)
                            if let versions = existingVersions {
                                self.chatManager.attachVersions(versions, to: aiMsgId)
                            }
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
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
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
                let searchQuery =
                    chatManager.getCurrentMessages().last(where: { $0.isUser })?.content ?? ""
                var ollamaSystemPrompt = systemPrompt
                if webSearchEnabled && !ollamaAPIKey.isEmpty {
                    do {
                        let searchResults = try await webSearchService.search(
                            query: searchQuery, apiKey: ollamaAPIKey)
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
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
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
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.accentColor)
                }
            }
        }
    }

    func geminiThinkingOption(title: String, value: String) -> some View {
        Button(action: { geminiThinkingLevel = value }) {
            HStack {
                Text(title)
                Spacer()
                if geminiThinkingLevel == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.accentColor)
                }
            }
        }
    }
}

struct QuickAIMessageView: View, Equatable {
    let message: Message
    var liveContent: String? = nil
    var liveThinking: String? = nil
    var onRegenerate: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var canEdit: Bool = false
    var onSwitchVersion: ((Int) -> Void)?
    @State private var isCopied = false
    @State private var isPasted = false
    @State private var isCursorVisible = true
    @State private var isThinkingExpanded = false
    @State private var isEditing = false
    @State private var editText = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    static func == (lhs: QuickAIMessageView, rhs: QuickAIMessageView) -> Bool {
        return lhs.message == rhs.message && lhs.liveContent == rhs.liveContent
            && lhs.liveThinking == rhs.liveThinking && lhs.canEdit == rhs.canEdit
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

                    // Show additional attachments (PDFs, text files)
                    if let attachments = message.attachments {
                        let nonImageAttachments = attachments.filter { $0.type != "image" }
                        if !nonImageAttachments.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(nonImageAttachments) { att in
                                    HStack(spacing: 4) {
                                        Image(
                                            systemName: att.type == "pdf"
                                                ? "doc.text.fill" : "doc.plaintext"
                                        )
                                        .font(.system(size: 11))
                                        .foregroundStyle(att.type == "pdf" ? .red : .blue)
                                        Text(att.fileName ?? (att.type == "pdf" ? "PDF" : "File"))
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.secondary.opacity(0.1))
                                    )
                                }
                            }
                        }
                    }

                    if isEditing {
                        // Inline editing mode
                        VStack(alignment: .trailing, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.blue)
                                Text("Editing message")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }

                            TextEditor(text: $editText)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 60, maxHeight: 200)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.05)
                                                : Color.black.opacity(0.03))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
                                )

                            HStack(spacing: 8) {
                                Button(action: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isEditing = false
                                        editText = ""
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("Cancel")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.gray.opacity(0.15))
                                    )
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    if let onEdit = onEdit,
                                        !editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                    {
                                        onEdit(editText)
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isEditing = false
                                            editText = ""
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("Save & Send")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                                    .shadow(color: Color.blue.opacity(0.3), radius: 3, y: 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )
                    } else if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 14))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: appTheme.colors.map { $0.opacity(0.18) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))

                        // User message action buttons
                        HStack(spacing: 8) {
                            if canEdit {
                                ExpandingActionButton(
                                    title: "Edit",
                                    icon: "pencil",
                                    font: .caption2,
                                    action: {
                                        editText = message.content
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isEditing = true
                                        }
                                    }
                                )
                            }

                            ExpandingActionButton(
                                title: isCopied ? "Copied!" : "Copy",
                                icon: isCopied ? "checkmark" : "doc.on.doc",
                                color: isCopied ? .green : .secondary,
                                font: .caption2,
                                action: {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(message.content, forType: .string)
                                    isCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        isCopied = false
                                    }
                                }
                            )
                        }
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
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
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

                        // Action Buttons
                        HStack(spacing: 8) {
                            ExpandingActionButton(
                                title: isCopied ? "Copied!" : "Copy",
                                icon: isCopied ? "checkmark" : "doc.on.doc",
                                color: isCopied ? .green : .secondary,
                                font: .caption2,
                                action: {
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
                                }
                            )

                            // Paste to App button (only for text content)
                            if message.image == nil && !message.content.isEmpty {
                                ExpandingActionButton(
                                    title: "Paste to App",
                                    icon: "arrow.up.doc",
                                    font: .caption2,
                                    action: {
                                        QuickAIManager.shared.pasteToActiveApp(
                                            text: message.content)
                                    }
                                )
                            }

                            if let onRegenerate = onRegenerate {
                                ExpandingActionButton(
                                    title: "Regenerate",
                                    icon: "arrow.counterclockwise",
                                    font: .caption2,
                                    action: onRegenerate
                                )
                            }

                            // Version navigator
                            if let versions = message.versions, versions.count > 1 {
                                let currentIdx = message.currentVersionIndex ?? (versions.count - 1)
                                HStack(spacing: 5) {
                                    Button(action: {
                                        if currentIdx > 0 {
                                            onSwitchVersion?(currentIdx - 1)
                                        }
                                    }) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(
                                                currentIdx > 0
                                                    ? Color.primary : Color.secondary.opacity(0.3))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(currentIdx <= 0)

                                    Text("\(currentIdx + 1)/\(versions.count)")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()

                                    Button(action: {
                                        if currentIdx < versions.count - 1 {
                                            onSwitchVersion?(currentIdx + 1)
                                        }
                                    }) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(
                                                currentIdx < versions.count - 1
                                                    ? Color.primary : Color.secondary.opacity(0.3))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(currentIdx >= versions.count - 1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.08)
                                                : Color.black.opacity(0.05))
                                )
                            }

                            Spacer()
                        }

                        // Model disclaimer
                        if let model = message.model {
                            let displayModel = GeminiModelManager.displayNames[model] ?? model
                            Text("Model used: \(displayModel). Information could be inaccurate.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.8))
                                .padding(.top, 2)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))

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
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("QuickAICommandBarVibrancy") private var commandBarVibrancy: Double = 0.55
    @AppStorage("QuickAIChatBarTintIntensity") private var chatBarTintIntensity: Double = 0.5

    private var clampedVibrancy: Double {
        min(max(commandBarVibrancy, 0.05), 1.0)
    }

    private var clampedChatBarTint: Double {
        min(max(chatBarTintIntensity, 0.0), 1.0)
    }

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        ZStack {
            // Theme tint layer
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            startColor.opacity(clampedVibrancy * 0.25 * clampedChatBarTint * 2),
                            endColor.opacity(clampedVibrancy * 0.18 * clampedChatBarTint * 2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Ultra thin material — opacity driven by vibrancy slider
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(clampedVibrancy)
        }
    }
}

struct ExpandedPanelBackground: View {
    var cornerRadius: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuickAIBackgroundOpacity") private var backgroundOpacity: Double = 0.18
    @AppStorage("QuickAITintIntensity") private var tintIntensity: Double = 0.5
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.05), 1.0)
    }

    private var clampedTintIntensity: Double {
        min(max(tintIntensity, 0.0), 1.0)
    }

    var body: some View {
        let colors = appTheme.colors

        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        let baseDarkStart = 0.08
        let baseDarkEnd = 0.05
        let baseLightStart = 0.12
        let baseLightEnd = 0.08

        // Much subtler gradient for the message area
        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(
                        (colorScheme == .dark ? baseDarkStart : baseLightStart)
                            * clampedTintIntensity * 2),
                    location: 0.0),
                .init(
                    color: endColor.opacity(
                        (colorScheme == .dark ? baseDarkEnd : baseLightEnd) * clampedTintIntensity
                            * 2),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            // Gradient tint
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)

            // Liquid glass
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .opacity(
                    colorScheme == .dark
                        ? clampedBackgroundOpacity + 0.16
                        : clampedBackgroundOpacity + 0.12
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
                        .fill(Color.clear)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: .circle)
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
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    Text(selectedProvider)
                        .font(.headline)
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .glassEffect(.regular, in: .capsule)
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
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    .glassEffect(.regular, in: .capsule)
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
                    let messages = chatManager.getCurrentMessages()
                    ForEach(messages) { message in
                        let isLast = message.id == messages.last?.id
                        let isLastUserMessage =
                            message.isUser && messages.last(where: { $0.isUser })?.id == message.id
                        QuickAIMessageView(
                            message: message,
                            liveContent: streamBuffer[message.id],
                            liveThinking: streamThinkingBuffer[message.id],
                            onRegenerate: (!message.isUser && !isLoading && isLast)
                                ? { regenerateResponse(for: message.id) }
                                : nil,
                            onEdit: (isLastUserMessage && !isLoading)
                                ? { newContent in
                                    editAndResend(message: message, newContent: newContent)
                                }
                                : nil,
                            canEdit: isLastUserMessage && !isLoading,
                            onSwitchVersion: (!message.isUser && message.versions != nil
                                && (message.versions?.count ?? 0) > 1)
                                ? { versionIndex in
                                    chatManager.switchVersion(
                                        messageId: message.id, to: versionIndex)
                                }
                                : nil
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
        VStack(spacing: 0) {
            // Attachment previews inside the command bar
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selectedAttachments) { attachment in
                            QuickAIAttachmentPreview(attachment: attachment) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedAttachments.removeAll { $0.id == attachment.id }
                                    recalcPanelSize()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text(" Request... (type / for commands)")
                            .font(.system(size: 16))
                            .foregroundStyle(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.5)
                                    : Color.black.opacity(0.45)
                            )
                            .allowsHitTesting(false)
                    }
                    NativeTextInput(
                        text: $inputText,
                        isFocused: $isFocused,
                        font: .systemFont(ofSize: 16),
                        textColor: colorScheme == .dark ? .white : .black,
                        maxLines: 6,
                        onCommit: {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                applySlashCommand(slashMatches[slashSelectedIndex])
                            } else {
                                sendMessage()
                            }
                        },
                        onEscape: {
                            if showSlashAutocomplete {
                                showSlashAutocomplete = false
                            }
                        },
                        onArrowUp: {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                slashSelectedIndex = max(0, slashSelectedIndex - 1)
                                return true
                            }
                            return false
                        },
                        onArrowDown: {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                slashSelectedIndex = min(
                                    slashMatches.count - 1, slashSelectedIndex + 1)
                                return true
                            }
                            return false
                        },
                        onTab: {
                            if showSlashAutocomplete && !slashMatches.isEmpty {
                                applySlashCommand(slashMatches[slashSelectedIndex])
                                return true
                            }
                            return false
                        },
                        onPasteNonText: { pasteboard in
                            // Handle image paste
                            if let objects = pasteboard.readObjects(
                                forClasses: [NSImage.self], options: nil) as? [NSImage],
                                let image = objects.first, let tiff = image.tiffRepresentation
                            {
                                DispatchQueue.main.async {
                                    self.selectedAttachments.append(
                                        Attachment(type: .image, data: tiff))
                                    self.recalcPanelSize()
                                }
                                return true
                            }
                            // Handle file URL paste
                            if let urls = pasteboard.readObjects(
                                forClasses: [NSURL.self], options: nil) as? [URL]
                            {
                                var handled = false
                                for url in urls {
                                    let ext = url.pathExtension.lowercased()
                                    if ext == "pdf", let data = try? Data(contentsOf: url) {
                                        DispatchQueue.main.async {
                                            self.selectedAttachments.append(
                                                Attachment(type: .pdf, data: data))
                                            self.recalcPanelSize()
                                        }
                                        handled = true
                                    } else if [
                                        "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                                    ].contains(ext), let data = try? Data(contentsOf: url) {
                                        DispatchQueue.main.async {
                                            self.selectedAttachments.append(
                                                Attachment(type: .image, data: data))
                                            self.recalcPanelSize()
                                        }
                                        handled = true
                                    }
                                }
                                if handled { return true }
                            }
                            // Handle raw PDF data paste
                            if pasteboard.canReadItem(withDataConformingToTypes: ["com.adobe.pdf"]),
                                let data = pasteboard.data(forType: .init("com.adobe.pdf"))
                            {
                                DispatchQueue.main.async {
                                    self.selectedAttachments.append(
                                        Attachment(type: .pdf, data: data))
                                    self.recalcPanelSize()
                                }
                                return true
                            }
                            return false
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: inputText) { _, newValue in
                        updateSlashAutocomplete(newValue)
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
                                            .foregroundStyle(
                                                colorScheme == .dark ? Color.white : Color.primary)
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
                                                    .foregroundStyle(
                                                        colorScheme == .dark
                                                            ? Color.white : Color.primary)
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
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .padding(6)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .glassEffect(.regular, in: .circle)
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
                                            .foregroundStyle(
                                                colorScheme == .dark ? Color.white : Color.primary)
                                    } else {
                                        Text("Reasoning: On")
                                    }
                                }
                                Button {
                                    thinkingLevel = "low"
                                } label: {
                                    if thinkingLevel != "high" {
                                        Label("Reasoning: Off", systemImage: "checkmark")
                                            .foregroundStyle(
                                                colorScheme == .dark ? Color.white : Color.primary)
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
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .padding(6)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .glassEffect(.regular, in: .circle)
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
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "checkmark"
                                        )
                                        .foregroundStyle(
                                            colorScheme == .dark ? Color.white : Color.primary)
                                    } else {
                                        Text(geminiManager.displayName(for: model))
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
                                                Label(
                                                    geminiManager.displayName(for: model),
                                                    systemImage: "checkmark"
                                                )
                                                .foregroundStyle(
                                                    colorScheme == .dark
                                                        ? Color.white : Color.primary)
                                            } else {
                                                Text(geminiManager.displayName(for: model))
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
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "star.fill")
                                    } else {
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "star")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .padding(6)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .glassEffect(.regular, in: .circle)
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
                                geminiThinkingLevel = "auto"
                            } label: {
                                if geminiThinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                        .foregroundStyle(
                                            colorScheme == .dark ? Color.white : Color.primary)
                                } else {
                                    Text("Auto")
                                }
                            }
                            geminiThinkingOption(title: "Low", value: "low")
                            if !isGemini3Pro {
                                geminiThinkingOption(title: "Medium", value: "medium")
                            }
                            geminiThinkingOption(title: "High", value: "high")
                        } label: {
                            Image(systemName: "brain")
                                .font(.system(size: 16))
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .padding(6)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .glassEffect(.regular, in: .circle)
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
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .padding(6)
                            .background(
                                Circle().fill(
                                    webSearchEnabled
                                        ? Color.blue.opacity(0.15)
                                        : Color.primary.opacity(0.06)
                                )
                            )
                            .glassEffect(.regular, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help(webSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                }
                .buttonStyle(.plain)
                .disabled((inputText.isEmpty && selectedAttachments.isEmpty) || isLoading)
            }
            .padding(16)
            .background(CommandBarBackground(cornerRadius: 20))
        }
    }
}

// MARK: - QuickAI Attachment Preview

struct QuickAIAttachmentPreview: View {
    let attachment: Attachment
    var onRemove: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment.type {
                case .image:
                    if let image = NSImage(data: attachment.data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                case .pdf:
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                        Text(attachment.fileName ?? "PDF")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 80, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                case .text:
                    VStack(spacing: 4) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                        Text(attachment.fileName ?? "File")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 80, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // X button — always visible, larger hit target
            Button(action: onRemove) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 22, height: 22)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            colorScheme == .dark ? .white.opacity(0.8) : .black.opacity(0.6))
                }
                .contentShape(Circle().scale(1.5))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .opacity(isHovered ? 1 : 0.7)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
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
