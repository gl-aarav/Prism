import AppKit
import SwiftUI

struct QuickAIView: View {
    var onResize: ((CGSize) -> Void)?
    var onClose: (() -> Void)?

    @ObservedObject var chatManager = ChatManager.shared
    @State private var inputText: String = ""
    @State private var inputLineCount: Int = 1
    @State private var isLoading: Bool = false
    @State private var selectedProvider: String = "Ollama 1"
    @State private var thinkingLevel: String = "medium"
    @State private var isExpanded: Bool = false
    @State private var selectedPDF: Data? = nil
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) var colorScheme

    // Settings
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("OllamaModel") private var ollamaModel: String = "gpt-oss:120b-cloud"
    @AppStorage("OllamaModel2") private var ollamaModel2: String = "gpt-oss:20b-cloud"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"
    @AppStorage("ShortcutOnDevice") private var shortcutOnDevice: String = "Ask AI Device"
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("QuickAIBackgroundOpacity") private var backgroundOpacity: Double = 0.18
    @AppStorage("QuickAICommandBarVibrancy") private var commandBarVibrancy: Double = 0.55
    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.05), 0.55)
    }
    private var clampedCommandBarVibrancy: Double {
        min(max(commandBarVibrancy, 0.05), 0.9)
    }

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let shortcutService = ShortcutService()
    @State private var showOpacityPopover: Bool = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isExpanded {
                    VStack(spacing: 12) {
                        // Header
                        HStack {
                            Menu {
                                Section("API") {
                                    Button(action: { selectedProvider = "Gemini API" }) {
                                        Label(
                                            "Gemini API", systemImage: getProviderIcon("Gemini API")
                                        )
                                    }
                                    Button(action: { selectedProvider = "Ollama 1" }) {
                                        Label("Ollama 1", systemImage: getProviderIcon("Ollama"))
                                    }
                                    Button(action: { selectedProvider = "Ollama 2" }) {
                                        Label("Ollama 2", systemImage: getProviderIcon("Ollama"))
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
                                Section("Tools") {
                                    Button(action: { selectedProvider = "Image Creation" }) {
                                        Label(
                                            "Image Creation",
                                            systemImage: getProviderIcon("Image Creation"))
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: getProviderIcon(selectedProvider))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [.blue, .green], startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
                                    Text(selectedProvider)
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                                chatManager.createNewSession()
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    isExpanded = false
                                }
                            }) {
                                Image(systemName: "square.and.pencil")
                                    .foregroundColor(.secondary)
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

                            // Opacity control
                            Button(action: { showOpacityPopover.toggle() }) {
                                Image(systemName: "paintbrush.pointed")
                                    .foregroundColor(.secondary)
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
                            .popover(isPresented: $showOpacityPopover, arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Background Opacity")
                                        .font(.headline)
                                    Slider(
                                        value: Binding(
                                            get: { backgroundOpacity },
                                            set: { backgroundOpacity = min(max($0, 0.05), 0.55) }
                                        ),
                                        in: 0.05...0.55
                                    )
                                    HStack {
                                        Text("Clear")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Opaque")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Current: \(Int((backgroundOpacity) * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Divider().padding(.vertical, 4)

                                    Text("Chat Bar Vibrancy")
                                        .font(.headline)
                                    Slider(
                                        value: Binding(
                                            get: { commandBarVibrancy },
                                            set: { commandBarVibrancy = min(max($0, 0.05), 0.9) }
                                        ),
                                        in: 0.05...0.9
                                    )
                                    HStack {
                                        Text("Subtle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Punchy")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Current: \(Int((commandBarVibrancy) * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                                .frame(width: 240)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                        // Messages
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(chatManager.getCurrentMessages()) { message in
                                        QuickAIMessageView(message: message)
                                    }
                                    if isLoading {
                                        HStack {
                                            TypingIndicator()
                                            Spacer()
                                        }
                                        .padding(.horizontal)
                                        .id("loading")
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
                            .onChange(of: isLoading) { _, loading in
                                if loading {
                                    withAnimation {
                                        proxy.scrollTo("loading", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(
                                (colorScheme == .dark ? Color.black : Color.white).opacity(
                                    colorScheme == .dark
                                        ? clampedBackgroundOpacity + 0.08
                                        : clampedBackgroundOpacity
                                )
                            )
                            .background(
                                .ultraThinMaterial.opacity(
                                    colorScheme == .dark
                                        ? clampedBackgroundOpacity + 0.16
                                        : clampedBackgroundOpacity + 0.12
                                )
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .compositingGroup()
                    .padding(.bottom, 10)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                }

                // Input Area
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
                        TextField("Request...", text: $inputText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .lineLimit(1...6)
                            .multilineTextAlignment(.leading)
                            .focused($isFocused)
                            .onChange(of: inputText) { _, _ in
                                recalcPanelSize()
                            }
                            .onSubmit { sendMessage() }
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

                        // Thinking Level Selector
                        if selectedProvider.contains("Ollama") || selectedProvider == "Gemini API" {
                            Menu {
                                thinkingOption(title: "Low", value: "low")
                                thinkingOption(title: "Medium", value: "medium")
                                thinkingOption(title: "High", value: "high")
                            } label: {
                                Image(systemName: "brain")
                                    .font(.system(size: 16))
                                    .foregroundColor(
                                        thinkingLevel == "medium" ? Color.teal : Color.green
                                    )
                                    .padding(6)
                                    .background(Color.white.opacity(0.10))
                                    .clipShape(Circle())
                            }
                            .menuStyle(.borderlessButton)
                            .help("Reasoning Effort")
                        }

                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    sendButtonStyle(darkened: true),
                                    Color.black.opacity(colorScheme == .dark ? 0.35 : 0.28)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(inputText.isEmpty || isLoading)
                    }
                    .padding(16)
                    .background(CommandBarBackground(cornerRadius: 26))
                }
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
            recalcPanelSize()
        }
        .onChange(of: chatManager.getCurrentMessages().count) { _, count in
            // Auto-expand when messages arrive and keep the panel height consistent
            if count > 0 && !isExpanded {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded = true
                }
            }
            recalcPanelSize()
        }
    }

    private func sendButtonStyle(darkened: Bool = false) -> AnyShapeStyle {
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

    private func recalcPanelSize() {
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
        let targetHeight = baseHeight + CGFloat(max(0, lines - 1)) * extraHeightPerLine

        onResize?(CGSize(width: baseWidth, height: targetHeight))
    }

    func getProviderIcon(_ provider: String) -> String {
        switch provider {
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
        case "Image Creation": return "paintpalette"
        case "ChatGPT": return "message"
        default: return "cpu"
        }
    }

    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if !isExpanded {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
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
            if selectedProvider == "Image Creation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "Generating image...", isUser: false)
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    let result = try await shortcutService.runShortcut(
                        name: shortcutImageGen, input: content, image: nil)

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: result.0, image: result.1)
                        self.chatManager.finalizeMessageUpdate()
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
            } else if selectedProvider == "Gemini API" {
                if !geminiKey.isEmpty {
                    let aiMsgId = UUID()
                    var aiMsg = Message(content: "", isUser: false)
                    aiMsg.id = aiMsgId

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""

                        for try await (contentChunk, thinkingChunk)
                            in geminiService.sendMessageStream(
                                history: chatManager.getCurrentMessages(), apiKey: geminiKey,
                                model: geminiModel, systemPrompt: systemPrompt,
                                thinkingLevel: thinkingLevel)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            let contentToUpdate = fullContent
                            let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                            DispatchQueue.main.async {
                                self.chatManager.updateMessage(
                                    id: aiMsgId, content: contentToUpdate,
                                    thinkingContent: thinkingToUpdate)
                            }
                        }
                        DispatchQueue.main.async {
                            self.chatManager.finalizeMessageUpdate()
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
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Please set your API Key in the main app settings.",
                            isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            } else if selectedProvider.contains("Ollama") {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", isUser: false)
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                let activeModel = (selectedProvider == "Ollama 2") ? ollamaModel2 : ollamaModel

                do {
                    var fullContent = ""
                    var fullThinking = ""

                    for try await (contentChunk, thinkingChunk) in ollamaService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), endpoint: ollamaURL,
                        model: activeModel, systemPrompt: systemPrompt, thinkingLevel: thinkingLevel
                    ) {
                        fullContent += contentChunk
                        if let thinking = thinkingChunk {
                            fullThinking += thinking
                        }

                        let contentToUpdate = fullContent
                        let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: contentToUpdate,
                                thinkingContent: thinkingToUpdate)
                        }
                    }
                    DispatchQueue.main.async {
                        self.chatManager.finalizeMessageUpdate()
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
    private func thinkingOption(title: String, value: String) -> some View {
        Button(action: { thinkingLevel = value }) {
            HStack {
                Text(title)
                Spacer()
                if thinkingLevel == value {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

struct QuickAIMessageView: View {
    let message: Message
    @State private var isCopied = false

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
                            .contextMenu {
                                Button("Copy Image") {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.writeObjects([image])
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
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .green], startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    )
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.ultraThinMaterial))

                VStack(alignment: .leading, spacing: 8) {
                    if let thinking = message.thinkingContent {
                        DisclosureGroup {
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
                            .foregroundColor(.secondary)
                        }
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
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.writeObjects([image])
                                }
                            }
                    }

                    if !message.content.isEmpty {
                        MarkdownView(blocks: message.blocks)
                    }

                    // Copy Button
                    HStack {
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
                        Spacer()
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer()
            }
        }
    }
}

struct CommandBarBackground: View {
    var cornerRadius: CGFloat = 26
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuickAICommandBarVibrancy") private var commandBarVibrancy: Double = 0.55

    var body: some View {
        let gradient = LinearGradient(
            stops: [
                .init(
                    color: Color.blue.opacity(colorScheme == .dark ? 0.34 : 0.44),
                    location: 0.0),
                .init(
                    color: Color.green.opacity(colorScheme == .dark ? 0.30 : 0.38),
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
                        ? Color.black.opacity(0.35)
                        : Color.white.opacity(0.28),
                    lineWidth: 1
                )
        }
        .drawingGroup()
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        // Mask shadow and contents to a fixed-radius rect so added height doesn't overly round corners
        .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
