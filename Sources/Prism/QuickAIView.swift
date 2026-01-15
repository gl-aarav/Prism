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
    @State private var selectedStyle: String = "Animation"
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
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String = "Generate Image ChatGPT"
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
    private let appleFoundationService = AppleFoundationService()
    @State private var showOpacityPopover: Bool = false

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
        ZStack {
            VStack(spacing: 0) {
                if isExpanded {
                    VStack(spacing: 12) {
                        // Header
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
                                withAnimation(collapseAnimation) {
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
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .opacity(expandedContentOpacity)
                        .offset(y: headerOffset)

                        // Messages
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(chatManager.getCurrentMessages()) { message in
                                        QuickAIMessageView(message: message)
                                            .equatable()
                                    }
                                    if isLoading {
                                        // Loading indicator removed in favor of streaming cursor
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
                        .opacity(expandedContentOpacity)
                        .offset(y: messagesOffset)
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
                    .scaleEffect(backgroundScale, anchor: .bottom)
                    .blur(radius: backgroundBlur)
                    .padding(.bottom, 10)
                    .transition(
                        .asymmetric(
                            insertion: .modifier(
                                active: ExpandedPanelModifier(opacity: 0, offsetY: 40, scale: 0.88, blur: 8),
                                identity: ExpandedPanelModifier(opacity: 1, offsetY: 0, scale: 1, blur: 0)
                            ),
                            removal: .modifier(
                                active: ExpandedPanelModifier(opacity: 0, offsetY: 25, scale: 0.92, blur: 6),
                                identity: ExpandedPanelModifier(opacity: 1, offsetY: 0, scale: 1, blur: 0)
                            )
                        )
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

                        // Image Creation Tools
                        if selectedProvider == "Image Creation" {
                             // Style Picker
                             Menu {
                                 Section("Apple Intelligence") {
                                     Button(action: { selectedStyle = "Animation" }) {
                                         if selectedStyle == "Animation" { Label("Animation", systemImage: "checkmark") } else { Text("Animation") }
                                     }
                                     Button(action: { selectedStyle = "Illustration" }) {
                                         if selectedStyle == "Illustration" { Label("Illustration", systemImage: "checkmark") } else { Text("Illustration") }
                                     }
                                     Button(action: { selectedStyle = "Sketch" }) {
                                         if selectedStyle == "Sketch" { Label("Sketch", systemImage: "checkmark") } else { Text("Sketch") }
                                     }
                                 }
                                 Divider()
                                 Section("ChatGPT") {
                                     Button(action: { selectedStyle = "ChatGPT" }) {
                                         if selectedStyle == "ChatGPT" { Label("ChatGPT (Default)", systemImage: "checkmark") } else { Text("ChatGPT (Default)") }
                                     }
                                     Button(action: { selectedStyle = "Oil Painting (ChatGPT)" }) {
                                         if selectedStyle == "Oil Painting (ChatGPT)" { Label("Oil Painting", systemImage: "checkmark") } else { Text("Oil Painting") }
                                     }
                                     Button(action: { selectedStyle = "Watercolor (ChatGPT)" }) {
                                         if selectedStyle == "Watercolor (ChatGPT)" { Label("Watercolor", systemImage: "checkmark") } else { Text("Watercolor") }
                                     }
                                     Button(action: { selectedStyle = "Vector (ChatGPT)" }) {
                                         if selectedStyle == "Vector (ChatGPT)" { Label("Vector", systemImage: "checkmark") } else { Text("Vector") }
                                     }
                                     Button(action: { selectedStyle = "Anime (ChatGPT)" }) {
                                         if selectedStyle == "Anime (ChatGPT)" { Label("Anime", systemImage: "checkmark") } else { Text("Anime") }
                                     }
                                     Button(action: { selectedStyle = "Print (ChatGPT)" }) {
                                         if selectedStyle == "Print (ChatGPT)" { Label("Print", systemImage: "checkmark") } else { Text("Print") }
                                     }
                                 }
                             } label: {
                                 Image(systemName: "paintpalette")
                                     .font(.system(size: 16))
                                     .foregroundColor(selectedStyle.isEmpty ? .secondary : .orange)
                                     .padding(6)
                                     .background(Color.white.opacity(0.10))
                                     .clipShape(Circle())
                             }
                             .menuStyle(.borderlessButton)
                             .help("Image Style")
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
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
        case "Image Creation": return "paintbrush"
        case "ChatGPT": return "message"
        default: return "cpu"
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
        let style = selectedStyle
        inputText = ""
        selectedPDF = nil
        recalcPanelSize()

        let userMsg = Message(content: content, image: nil, pdfData: pdfData, isUser: true)
        chatManager.addMessage(userMsg)
        isLoading = true

        chatManager.currentTask = Task {
            if selectedProvider == "Image Creation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", isUser: false)
                aiMsg.isGeneratingImage = true
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    // Switch shortcut based on style/mode
                    let targetShortcut = style.contains("ChatGPT") ? shortcutImageGenChatGPT : shortcutImageGen
                    
                    let result = try await shortcutService.runShortcut(
                        name: targetShortcut, input: content, style: style, image: nil)

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: result.0, image: result.1, isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)", isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Gemini API" {
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
                                    thinkingContent: thinkingToUpdate, isStreaming: true)
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
                    for try await contentSnapshot in appleFoundationService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), systemPrompt: systemPrompt
                    ) {
                        accumulatedContent += contentSnapshot
                        let contentToUpdate = accumulatedContent
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: contentToUpdate, isStreaming: true)
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
    private func styleButton(_ title: String, value: String) -> some View {
        Button(action: { selectedStyle = value }) {
            if selectedStyle == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

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

struct QuickAIMessageView: View, Equatable {
    let message: Message
    @State private var isCopied = false
    @State private var isCursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    static func == (lhs: QuickAIMessageView, rhs: QuickAIMessageView) -> Bool {
        return lhs.message == rhs.message
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
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if message.isGeneratingImage == true {
                        GeneratingImagePlaceholder()
                    } else {
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
                                        copyImage(image)
                                    }
                                    Button("Go to chat") {
                                        openInMainWindow()
                                    }
                                }
                        }

                        if !message.content.isEmpty || message.isStreaming {
                            if message.isStreaming {
                                MarkdownView(
                                    blocks: Message.parseMarkdown(
                                        message.content + (isCursorVisible ? " ▋" : "")))
                            } else {
                                MarkdownView(blocks: message.blocks)
                            }
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
           let png = bitmap.representation(using: .png, properties: [:]) {
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

struct GeneratingImagePlaceholder: View {
    @State private var phase: CGFloat = 0
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.black : Color.white)
            
            // Shimmering Effect
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        .clear,
                        (colorScheme == .dark ? Color.white : Color.black).opacity(0.1),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(45))
                .offset(x: -geo.size.width + (geo.size.width * 2 * phase))
            }
            .mask(RoundedRectangle(cornerRadius: 16))
            
            // Border
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.5) : Color.black.opacity(0.5),
                    lineWidth: 2
                )
        }
        .frame(width: 200, height: 200)
        .onAppear {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
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
    var animatableData: AnimatablePair<AnimatablePair<Double, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
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
