import SwiftUI

// MARK: - Comparison Slot Model

struct ComparisonSlot: Identifiable {
    let id = UUID()
    var provider: String  // "Gemini API", "Ollama", "Apple Foundation", etc.
    var model: String  // specific model name
    var response: String = ""
    var isLoading: Bool = false
    var error: String?
    var thinkingContent: String?
    var elapsedTime: TimeInterval?
    var thinkingLevel: String = "auto"
    var webSearchEnabled: Bool = false
}

// MARK: - Comparison State Manager (singleton to persist across view lifecycle)

class ComparisonStateManager: ObservableObject {
    static let shared = ComparisonStateManager()

    @Published var slots: [ComparisonSlot]
    @Published var synthesizedResponse: String = ""
    @Published var synthesizedThinking: String = ""
    @Published var showSynthesizePanel: Bool = false

    private init() {
        if let savedData = UserDefaults.standard.array(forKey: "ComparisonSlots")
            as? [[String: String]],
            savedData.count >= 2
        {
            slots = savedData.map {
                ComparisonSlot(
                    provider: $0["provider"] ?? "Gemini API",
                    model: $0["model"] ?? "gemini-2.5-flash",
                    thinkingLevel: $0["thinkingLevel"] ?? "auto",
                    webSearchEnabled: $0["webSearchEnabled"] == "true"
                )
            }
        } else {
            slots = [
                ComparisonSlot(provider: "Gemini API", model: "gemini-2.5-flash"),
                ComparisonSlot(provider: "Ollama", model: "llama3.3"),
            ]
        }
    }

    func saveSlotConfigurations() {
        let data = slots.map {
            [
                "provider": $0.provider,
                "model": $0.model,
                "thinkingLevel": $0.thinkingLevel,
                "webSearchEnabled": $0.webSearchEnabled ? "true" : "false",
            ]
        }
        UserDefaults.standard.set(data, forKey: "ComparisonSlots")
    }
}

// MARK: - Model Comparison View

struct ModelComparisonView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @ObservedObject private var copilotModelManager = GitHubCopilotModelManager.shared
    @ObservedObject private var geminiCLIService = GeminiCLIService.shared
    @ObservedObject private var state = ComparisonStateManager.shared

    @AppStorage("ComparePrompt") private var prompt: String = ""
    @State private var isComparing: Bool = false
    @State private var currentTasks: [UUID: Task<Void, Never>] = [:]
    @State private var isInputFocused: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    // Synthesize state
    @State private var isSynthesizing: Bool = false
    @State private var synthesizeProvider: String = "Gemini API"
    @State private var synthesizeModel: String = "gemini-2.5-flash"
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @State private var synthesizeTask: Task<Void, Never>?

    // Ollama comparison options
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @State private var compareWebSearchEnabled: Bool = false
    @State private var compareThinkingLevel: String = "medium"

    // Synthesize options
    @State private var synthesizeThinkingLevel: String = "medium"
    @State private var synthesizeWebSearchEnabled: Bool = false

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()
    private let nvidiaService = NvidiaService()
    private let webSearchService = WebSearchService()

    // Convenience accessor for slots
    private var slots: [ComparisonSlot] {
        state.slots
    }

    private func saveSlots() {
        state.saveSlotConfigurations()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let slotId = slot.id
                    ComparisonCard(
                        slot: slot,
                        index: index,
                        appTheme: appTheme,
                        onRemove: slots.count > 2
                            ? {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    removeSlot(at: idx)
                                }
                            } : nil,
                        onChangeProvider: { provider, model in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].provider = provider
                                state.slots[idx].model = model
                                saveSlots()
                            }
                        },
                        onChangeThinkingLevel: { level in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].thinkingLevel = level
                                saveSlots()
                            }
                        },
                        onChangeWebSearch: { enabled in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].webSearchEnabled = enabled
                                saveSlots()
                            }
                        },
                        ollamaManager: ollamaManager,
                        geminiManager: geminiManager,
                        nvidiaManager: nvidiaManager,
                        copilotModelManager: copilotModelManager,
                        geminiCLIService: geminiCLIService,
                        hasOllamaAPIKey: !ollamaAPIKey.isEmpty,
                        hasNvidiaKey: !nvidiaKey.isEmpty,
                        hasCopilotAuth: copilotService.isAuthenticated
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Synthesize button
                if slots.filter({ !$0.response.isEmpty && !$0.isLoading }).count >= 2 {
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            state.showSynthesizePanel.toggle()
                            if !state.showSynthesizePanel {
                                synthesizeTask?.cancel()
                                synthesizeTask = nil
                                isSynthesizing = false
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 15, weight: .semibold))
                            Text(
                                state.showSynthesizePanel
                                    ? "Hide Synthesis" : "Synthesize All Responses"
                            )
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Combine all responses into one using AI")
                    .padding(.top, 8)
                }

                // Inline synthesis panel
                if state.showSynthesizePanel {
                    synthesizeInlinePanel
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)).combined(
                                    with: .scale(scale: 0.95, anchor: .top)),
                                removal: .opacity.combined(
                                    with: .scale(scale: 0.95, anchor: .top))
                            ))
                }
            }
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            headerBar
        }
        .safeAreaInset(edge: .bottom) {
            comparisonInputBar
        }
        .background(Color.clear)
        .onDisappear {
            // Cancel all running tasks to prevent freeze when switching views
            for (_, task) in currentTasks {
                task.cancel()
            }
            currentTasks.removeAll()
            synthesizeTask?.cancel()
            synthesizeTask = nil
            for i in state.slots.indices {
                state.slots[i].isLoading = false
            }
            isComparing = false
            isSynthesizing = false
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Title pill
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Model Comparison")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            // Slot count indicator
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(
                            i < slots.count
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: appTheme.colors, startPoint: .top, endPoint: .bottom
                                    ))
                                : AnyShapeStyle(Color.gray.opacity(0.2))
                        )
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)

            // Add model button
            if slots.count < 4 {
                Button(action: addSlot) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add Model")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            }

            // Clear all
            if slots.contains(where: { !$0.response.isEmpty }) {
                Button(action: clearAll) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Clear all responses")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.clear)
    }

    // MARK: - Input Bar

    private var comparisonInputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Prompt field
                ZStack(alignment: .leading) {
                    if prompt.isEmpty && !isInputFocused {
                        Text("Enter a prompt to compare models...")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }
                    NativeTextInput(
                        text: $prompt,
                        isFocused: $isInputFocused,
                        font: .systemFont(ofSize: 15),
                        textColor: colorScheme == .dark ? .white : .black,
                        maxLines: 5,
                        onCommit: {
                            startComparison()
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Send/Stop Button — Liquid Glass orb
                Button(action: {
                    if isComparing {
                        stopComparison()
                    } else {
                        startComparison()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isComparing
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : prompt.isEmpty
                                            ? [
                                                Color.secondary.opacity(0.3),
                                                Color.secondary.opacity(0.15),
                                            ]
                                            : [
                                                Color.primary.opacity(0.85),
                                                Color.primary.opacity(0.65),
                                            ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 36, height: 36)
                            .overlay(
                                Ellipse()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.5), .white.opacity(0.0)],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .frame(width: 22, height: 14)
                                    .offset(y: -6)
                            )

                        Image(systemName: isComparing ? "stop.fill" : "arrow.up")
                            .font(.system(size: isComparing ? 12 : 14, weight: .bold))
                            .foregroundStyle(
                                isComparing
                                    ? Color.white
                                    : (colorScheme == .dark ? Color.black : Color.white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(prompt.isEmpty && !isComparing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Liquid Glass container
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(isInputFocused ? 0.5 : 0.3)
                    : Color.black.opacity(isInputFocused ? 0.12 : 0.06),
                radius: isInputFocused ? 30 : 16,
                x: 0,
                y: isInputFocused ? 12 : 6
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isInputFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.clear)
    }

    // MARK: - Inline Synthesis Panel

    private var synthesizeInlinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel header with provider picker
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Menu {
                    Button(action: {
                        synthesizeProvider = "Apple Foundation"
                        synthesizeModel = "Apple Foundation"
                    }) {
                        Label("Apple Foundation", systemImage: "apple.logo")
                    }
                    Divider()
                    Menu("Gemini API") {
                        ForEach(GeminiModelManager.modelGroups, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.models, id: \.self) { model in
                                    Button(action: {
                                        synthesizeProvider = "Gemini API"
                                        synthesizeModel = model
                                    }) {
                                        if synthesizeProvider == "Gemini API"
                                            && synthesizeModel == model
                                        {
                                            Label(
                                                geminiManager.displayName(for: model),
                                                systemImage: "checkmark")
                                        } else {
                                            Text(geminiManager.displayName(for: model))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Menu("Ollama") {
                        ForEach(ollamaManager.allModels, id: \.self) { model in
                            Button(action: {
                                synthesizeProvider = "Ollama"
                                synthesizeModel = model
                            }) {
                                if synthesizeProvider == "Ollama" && synthesizeModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                    if !nvidiaKey.isEmpty {
                        Menu("NVIDIA API") {
                            ForEach(NvidiaModelManager.modelGroups, id: \.name) { group in
                                Section(group.name) {
                                    ForEach(group.models, id: \.self) { model in
                                        Button(action: {
                                            synthesizeProvider = "NVIDIA API"
                                            synthesizeModel = model
                                        }) {
                                            if synthesizeProvider == "NVIDIA API"
                                                && synthesizeModel == model
                                            {
                                                Label(
                                                    nvidiaManager.displayName(for: model),
                                                    systemImage: "checkmark")
                                            } else {
                                                Text(nvidiaManager.displayName(for: model))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if copilotService.isAuthenticated {
                        Menu("GitHub Copilot") {
                            ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                Button(action: {
                                    synthesizeProvider = "GitHub Copilot"
                                    synthesizeModel = model
                                }) {
                                    if synthesizeProvider == "GitHub Copilot"
                                        && synthesizeModel == model
                                    {
                                        Label(
                                            copilotModelManager.displayName(for: model),
                                            systemImage: "checkmark")
                                    } else {
                                        Text(copilotModelManager.displayName(for: model))
                                    }
                                }
                            }
                        }
                    }
                    if geminiCLIService.isAvailable {
                        Menu("Gemini CLI") {
                            ForEach(GeminiCLIService.availableModels, id: \.id) { model in
                                Button(action: {
                                    synthesizeProvider = "Gemini CLI"
                                    synthesizeModel = model.id
                                }) {
                                    if synthesizeProvider == "Gemini CLI"
                                        && synthesizeModel == model.id
                                    {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: synthesizeProviderIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(synthesizeProvider) — \(synthesizeModel)")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if !isSynthesizing && state.synthesizedResponse.isEmpty {
                    Button(action: startSynthesis) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Generate")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: appTheme.colors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                } else if isSynthesizing {
                    Button(action: {
                        synthesizeTask?.cancel()
                        synthesizeTask = nil
                        isSynthesizing = false
                    }) {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Stop")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.red.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    // Has response - show copy/retry
                    HStack(spacing: 8) {
                        Button(action: {
                            state.synthesizedResponse = ""
                            state.synthesizedThinking = ""
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Retry")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                state.synthesizedResponse, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("Copy")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Synthesize options bar (thinking + web search)
            if synthesizeProvider == "Ollama" {
                HStack(spacing: 10) {
                    // Thinking level
                    if synthesizeHasThinkingCapability {
                        Menu {
                            Button("Low") { synthesizeThinkingLevel = "low" }
                            Button("Medium") { synthesizeThinkingLevel = "medium" }
                            Button("High") { synthesizeThinkingLevel = "high" }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Thinking: \(synthesizeThinkingLevel.capitalized)")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    // Web search toggle
                    if !ollamaAPIKey.isEmpty {
                        Button(action: { synthesizeWebSearchEnabled.toggle() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11, weight: .medium))
                                Text(
                                    synthesizeWebSearchEnabled
                                        ? "Web Search: On" : "Web Search: Off"
                                )
                                .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(
                                synthesizeWebSearchEnabled ? Color.blue : Color.secondary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(
                                        synthesizeWebSearchEnabled
                                            ? Color.blue.opacity(0.1)
                                            : Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Response content
            if state.synthesizedResponse.isEmpty && !isSynthesizing {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.2))
                        Text("Select a model and tap Generate")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                Divider().opacity(0.2).padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !state.synthesizedThinking.isEmpty {
                            DisclosureGroup {
                                Text(state.synthesizedThinking)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.system(size: 11))
                                    Text("Thinking")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.purple)
                            }
                            .padding(.bottom, 4)
                        }

                        MarkdownView(blocks: Message.parseMarkdown(state.synthesizedResponse))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(maxHeight: 350)
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.8), value: state.synthesizedResponse)

                if !state.synthesizedResponse.isEmpty && !isSynthesizing {
                    HStack {
                        Text("Synthesized by \(synthesizeProvider) — \(synthesizeModel)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var synthesizeProviderIcon: String {
        switch synthesizeProvider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "person.crop.circle"
        case "Gemini CLI": return "terminal"
        default: return "cpu"
        }
    }

    /// Whether any slot is an Ollama provider
    private var hasOllamaSlot: Bool {
        slots.contains(where: { $0.provider == "Ollama" })
    }

    /// Whether any Ollama slot has a thinking-capable model (deepseek, gpt-oss, r1)
    private var hasThinkingCapableOllamaSlot: Bool {
        slots.contains(where: { slot in
            guard slot.provider == "Ollama" else { return false }
            let lower = slot.model.lowercased()
            return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
        })
    }

    /// Whether the synthesize model has thinking capability
    private var synthesizeHasThinkingCapability: Bool {
        guard synthesizeProvider == "Ollama" else { return false }
        let lower = synthesizeModel.lowercased()
        return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
    }

    /// Compute the effective thinking level for a given provider/model.
    private func effectiveThinkingLevel(provider: String, model: String) -> String {
        return effectiveThinkingLevel(provider: provider, model: model, level: compareThinkingLevel)
    }

    private func effectiveThinkingLevel(provider: String, model: String, level: String) -> String {
        if provider == "Gemini API" {
            let lower = model.lowercased()
            if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-2.5") {
                return level  // auto, low, medium, high
            }
            return "none"
        } else if provider == "Ollama" {
            let lower = model.lowercased()
            if lower.contains("gpt-oss") {
                return level  // low, medium, high from setting
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return level == "high" ? "true" : "false"
            }
            return "false"
        }
        return "none"
    }

    private func startSynthesis() {
        let completedSlots = slots.filter { !$0.response.isEmpty && !$0.isLoading }
        guard completedSlots.count >= 2 else { return }

        state.synthesizedResponse = ""
        state.synthesizedThinking = ""
        isSynthesizing = true

        // Build the synthesis prompt
        var synthesisPrompt =
            "You are an expert at synthesizing information. Below are responses from multiple AI models to the same prompt. Combine them into one comprehensive, well-structured response that takes the best parts of each. Do not mention the models by name or that there were multiple responses — just produce the best possible unified answer.\n\n"
        synthesisPrompt += "Original prompt: \(prompt)\n\n"
        for (i, slot) in completedSlots.enumerated() {
            synthesisPrompt +=
                "--- Response \(i + 1) (\(slot.provider) / \(slot.model)) ---\n\(slot.response)\n\n"
        }

        let userMsg = Message(content: synthesisPrompt, isUser: true)
        let history = [userMsg]
        let synthThinking = effectiveThinkingLevel(
            provider: synthesizeProvider, model: synthesizeModel, level: synthesizeThinkingLevel)

        synthesizeTask = Task {
            do {
                // Web search augmentation for Ollama synthesis
                var synthSystemPrompt = ""
                if synthesizeProvider == "Ollama" && synthesizeWebSearchEnabled
                    && !ollamaAPIKey.isEmpty
                {
                    do {
                        let searchResults = try await webSearchService.search(
                            query: prompt, apiKey: ollamaAPIKey)
                        let searchContext = webSearchService.buildSearchContext(
                            results: searchResults)
                        if !searchContext.isEmpty {
                            synthSystemPrompt = searchContext
                        }
                    } catch {
                        print("Synthesize web search failed: \(error.localizedDescription)")
                    }
                }

                switch synthesizeProvider {
                case "Gemini API":
                    guard !geminiKey.isEmpty else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: No Gemini API key set."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    for try await (chunk, _, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: synthesizeModel,
                        systemPrompt: "",
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { state.synthesizedResponse = content }
                    }

                case "Ollama":
                    var full = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()
                    for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: synthesizeModel,
                        systemPrompt: synthSystemPrompt,
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        if let t = thinkChunk { fullThinking += t }

                        // Throttle UI updates to avoid blocking the stream
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            let thinking = fullThinking
                            await MainActor.run {
                                state.synthesizedResponse = content
                                if !thinking.isEmpty {
                                    state.synthesizedThinking = thinking
                                }
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    // Flush final content
                    let finalSynthContent = full
                    let finalSynthThinking = fullThinking
                    await MainActor.run {
                        state.synthesizedResponse = finalSynthContent
                        if !finalSynthThinking.isEmpty {
                            state.synthesizedThinking = finalSynthThinking
                        }
                    }

                case "Apple Foundation":
                    var full = ""
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { state.synthesizedResponse = content }
                    }

                case "NVIDIA API":
                    guard !nvidiaKey.isEmpty else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: No NVIDIA API key set."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    var lastUpdateTime = Date()
                    for try await (chunk, _) in nvidiaService.sendMessageStream(
                        history: history, apiKey: nvidiaKey, model: synthesizeModel,
                        systemPrompt: ""
                    ) {
                        full += chunk
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            await MainActor.run { state.synthesizedResponse = content }
                            lastUpdateTime = Date()
                        }
                    }
                    let finalNvidiaContent = full
                    await MainActor.run { state.synthesizedResponse = finalNvidiaContent }

                case "GitHub Copilot":
                    guard copilotService.isAuthenticated else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: GitHub Copilot not authenticated."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    var lastUpdateTime = Date()
                    for try await (chunk, _) in GitHubCopilotService.shared.sendMessageStream(
                        history: history, model: synthesizeModel, systemPrompt: ""
                    ) {
                        full += chunk
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            await MainActor.run { state.synthesizedResponse = content }
                            lastUpdateTime = Date()
                        }
                    }
                    let finalCopilotContent = full
                    await MainActor.run { state.synthesizedResponse = finalCopilotContent }

                case "Gemini CLI":
                    guard GeminiCLIService.shared.isAvailable else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: Gemini CLI not available."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    for try await chunk in GeminiCLIService.shared.sendMessageStream(
                        history: history, model: synthesizeModel, systemPrompt: ""
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { state.synthesizedResponse = content }
                    }

                default:
                    await MainActor.run {
                        state.synthesizedResponse = "Error: Provider not supported."
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        if state.synthesizedResponse.isEmpty {
                            state.synthesizedResponse = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            }
            await MainActor.run {
                isSynthesizing = false
            }
        }
    }

    // MARK: - Actions

    private func addSlot() {
        guard slots.count < 4 else { return }
        // Cycle through default providers
        let defaults: [(String, String)] = [
            ("Gemini API", "gemini-2.5-flash"),
            ("Ollama", "llama3.3"),
            ("Apple Foundation", "Apple Foundation"),
            ("Gemini API", "gemini-2.5-pro"),
        ]
        let newDefault = defaults[slots.count % defaults.count]
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.slots.append(ComparisonSlot(provider: newDefault.0, model: newDefault.1))
        }
        saveSlots()
    }

    private func removeSlot(at index: Int) {
        guard slots.count > 2, index < slots.count else { return }
        let slotId = state.slots[index].id
        currentTasks[slotId]?.cancel()
        currentTasks.removeValue(forKey: slotId)
        let _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            state.slots.remove(at: index)
        }
        saveSlots()
    }

    private func clearAll() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        withAnimation {
            for i in state.slots.indices {
                state.slots[i].response = ""
                state.slots[i].error = nil
                state.slots[i].isLoading = false
                state.slots[i].thinkingContent = nil
                state.slots[i].elapsedTime = nil
            }
        }
        isComparing = false
    }

    private func stopComparison() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        for i in state.slots.indices {
            state.slots[i].isLoading = false
        }
        isComparing = false
    }

    private func startComparison() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Clear the input field
        prompt = ""

        isComparing = true
        // Reset all slots
        for i in state.slots.indices {
            state.slots[i].response = ""
            state.slots[i].error = nil
            state.slots[i].isLoading = true
            state.slots[i].thinkingContent = nil
            state.slots[i].elapsedTime = nil
        }

        // Build a minimal history with just the user message
        let userMsg = Message(content: trimmed, isUser: true)
        let history = [userMsg]

        // Launch parallel tasks for each slot
        for i in state.slots.indices {
            let slotId = state.slots[i].id
            let provider = state.slots[i].provider
            let model = state.slots[i].model
            let slotThinkingLevel = state.slots[i].thinkingLevel
            let slotWebSearch = state.slots[i].webSearchEnabled

            let task = Task {
                let startTime = Date()
                do {
                    switch provider {
                    case "Gemini API":
                        guard !geminiKey.isEmpty else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "No Gemini API key set"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var fullThinking = ""
                        let geminiThinking = effectiveThinkingLevel(
                            provider: provider, model: model, level: slotThinkingLevel)
                        var lastGeminiUpdateTime = Date()
                        for try await (chunk, thinkChunk, _) in geminiService.sendMessageStream(
                            history: history, apiKey: geminiKey, model: model,
                            systemPrompt: systemPrompt, thinkingLevel: geminiThinking
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            if Date().timeIntervalSince(lastGeminiUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastGeminiUpdateTime = Date()
                            }
                        }
                        let elapsed = Date().timeIntervalSince(startTime)
                        let finalGeminiContent = fullContent
                        let finalGeminiThinking = fullThinking
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalGeminiContent
                                if !finalGeminiThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalGeminiThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Ollama":
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()
                        let ollamaThinking = effectiveThinkingLevel(
                            provider: provider, model: model, level: slotThinkingLevel)

                        // Web search augmentation for Ollama
                        var ollamaSystemPrompt = systemPrompt
                        if slotWebSearch && !ollamaAPIKey.isEmpty {
                            do {
                                let searchResults = try await webSearchService.search(
                                    query: trimmed, apiKey: ollamaAPIKey)
                                let searchContext = webSearchService.buildSearchContext(
                                    results: searchResults)
                                if !searchContext.isEmpty {
                                    ollamaSystemPrompt = systemPrompt + searchContext
                                }
                            } catch {
                                print("Compare web search failed: \(error.localizedDescription)")
                            }
                        }

                        for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                            history: history, endpoint: ollamaURL, model: model,
                            systemPrompt: ollamaSystemPrompt, thinkingLevel: ollamaThinking
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            // Throttle UI updates to avoid blocking the stream on every token
                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        // Flush final content
                        let finalContent = fullContent
                        let finalThinking = fullThinking
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalContent
                                if !finalThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Apple Foundation":
                        var fullContent = ""
                        for try await chunk in appleFoundationService.sendMessageStream(
                            history: history, systemPrompt: systemPrompt
                        ) {
                            fullContent += chunk
                            let content = fullContent
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].response = content
                                }
                            }
                        }
                        let afElapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = afElapsed
                            }
                        }

                    case "NVIDIA API":
                        guard !nvidiaKey.isEmpty else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "No NVIDIA API key set"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()
                        for try await (chunk, thinkChunk) in nvidiaService.sendMessageStream(
                            history: history, apiKey: nvidiaKey, model: model,
                            systemPrompt: systemPrompt
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let nvidiaElapsed = Date().timeIntervalSince(startTime)
                        let finalNvidiaContent = fullContent
                        let finalNvidiaThinking = fullThinking
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalNvidiaContent
                                if !finalNvidiaThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalNvidiaThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = nvidiaElapsed
                            }
                        }

                    case "GitHub Copilot":
                        guard copilotService.isAuthenticated else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "GitHub Copilot not authenticated"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var lastUpdateTime = Date()
                        for try await (chunk, _) in GitHubCopilotService.shared.sendMessageStream(
                            history: history, model: model, systemPrompt: systemPrompt
                        ) {
                            fullContent += chunk

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let copilotElapsed = Date().timeIntervalSince(startTime)
                        let finalCopilotContent = fullContent
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalCopilotContent
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = copilotElapsed
                            }
                        }

                    case "Gemini CLI":
                        guard GeminiCLIService.shared.isAvailable else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "Gemini CLI not available"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        for try await chunk in GeminiCLIService.shared.sendMessageStream(
                            history: history, model: model, systemPrompt: systemPrompt
                        ) {
                            fullContent += chunk
                            let content = fullContent
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].response = content
                                }
                            }
                        }
                        let cliElapsed = Date().timeIntervalSince(startTime)
                        let finalCLIContent = fullContent
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalCLIContent
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = cliElapsed
                            }
                        }

                    default:
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].error =
                                    "Provider '\(provider)' not supported for comparison"
                                state.slots[idx].isLoading = false
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].error = error.localizedDescription
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }
                    }
                }

                // Check if all done
                await MainActor.run {
                    if !slots.contains(where: { $0.isLoading }) {
                        isComparing = false
                    }
                }
            }

            currentTasks[slotId] = task
        }
    }
}

// MARK: - Comparison Card

struct ComparisonCard: View {
    let slot: ComparisonSlot
    let index: Int
    let appTheme: AppTheme
    var onRemove: (() -> Void)?
    var onChangeProvider: (String, String) -> Void
    var onChangeThinkingLevel: (String) -> Void
    var onChangeWebSearch: (Bool) -> Void

    @ObservedObject var ollamaManager: OllamaModelManager
    @ObservedObject var geminiManager: GeminiModelManager
    @ObservedObject var nvidiaManager: NvidiaModelManager
    @ObservedObject var copilotModelManager: GitHubCopilotModelManager
    @ObservedObject var geminiCLIService: GeminiCLIService
    var hasOllamaAPIKey: Bool = false
    var hasNvidiaKey: Bool = false
    var hasCopilotAuth: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovered: Bool = false
    @State private var showCopied: Bool = false

    private var accentColor: Color {
        let palette: [Color] = [.blue, .purple, .orange, .green]
        return palette[index % palette.count]
    }

    private var providerIcon: String {
        switch slot.provider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "person.crop.circle"
        case "Gemini CLI": return "terminal"
        default: return "cpu"
        }
    }

    /// Determine the thinking mode for this slot's provider/model
    private var slotThinkingMode: ThinkingMode {
        let lower = slot.model.lowercased()
        if slot.provider == "Gemini API" {
            if lower.hasPrefix("gemini-3-pro") {
                return .geminiPro
            } else if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-2.5") {
                return .geminiFlash
            }
        } else if slot.provider == "Ollama" {
            if lower.contains("gpt-oss") {
                return .threeState
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return .binary
            }
        }
        return .none
    }

    /// Whether this slot can show web search toggle
    private var slotCanWebSearch: Bool {
        slot.provider == "Ollama" && hasOllamaAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header
            cardHeader

            Divider()
                .opacity(0.3)

            // Card Body
            cardBody
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(
            color: Color.black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 16 : 8, x: 0,
            y: 4
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: slot.response)
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            // Provider icon with accent
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: providerIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            // Provider & Model selector
            VStack(alignment: .leading, spacing: 2) {
                providerMenu
                modelLabel
            }

            Spacer()

            // Thinking & web search controls
            HStack(spacing: 6) {
                if slotThinkingMode != .none {
                    Menu {
                        if slotThinkingMode == .binary {
                            Button {
                                onChangeThinkingLevel("high")
                            } label: {
                                if slot.thinkingLevel == "high" {
                                    Label("Reasoning: On", systemImage: "checkmark")
                                } else {
                                    Text("Reasoning: On")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("low")
                            } label: {
                                if slot.thinkingLevel != "high" {
                                    Label("Reasoning: Off", systemImage: "checkmark")
                                } else {
                                    Text("Reasoning: Off")
                                }
                            }
                        } else if slotThinkingMode == .geminiPro {
                            Button {
                                onChangeThinkingLevel("auto")
                            } label: {
                                if slot.thinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                } else {
                                    Text("Auto")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("low")
                            } label: {
                                if slot.thinkingLevel == "low" {
                                    Label("Low", systemImage: "checkmark")
                                } else {
                                    Text("Low")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("high")
                            } label: {
                                if slot.thinkingLevel == "high" {
                                    Label("High", systemImage: "checkmark")
                                } else {
                                    Text("High")
                                }
                            }
                        } else if slotThinkingMode == .geminiFlash {
                            Button {
                                onChangeThinkingLevel("auto")
                            } label: {
                                if slot.thinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                } else {
                                    Text("Auto")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("low")
                            } label: {
                                if slot.thinkingLevel == "low" {
                                    Label("Low", systemImage: "checkmark")
                                } else {
                                    Text("Low")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("medium")
                            } label: {
                                if slot.thinkingLevel == "medium" {
                                    Label("Medium", systemImage: "checkmark")
                                } else {
                                    Text("Medium")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("high")
                            } label: {
                                if slot.thinkingLevel == "high" {
                                    Label("High", systemImage: "checkmark")
                                } else {
                                    Text("High")
                                }
                            }
                        } else {
                            // threeState (Ollama gpt-oss)
                            Button {
                                onChangeThinkingLevel("low")
                            } label: {
                                if slot.thinkingLevel == "low" {
                                    Label("Low", systemImage: "checkmark")
                                } else {
                                    Text("Low")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("medium")
                            } label: {
                                if slot.thinkingLevel == "medium" {
                                    Label("Medium", systemImage: "checkmark")
                                } else {
                                    Text("Medium")
                                }
                            }
                            Button {
                                onChangeThinkingLevel("high")
                            } label: {
                                if slot.thinkingLevel == "high" {
                                    Label("High", systemImage: "checkmark")
                                } else {
                                    Text("High")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "brain")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.8))
                            .padding(5)
                            .background(
                                Circle()
                                    .fill(accentColor.opacity(0.1))
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Reasoning: \(slot.thinkingLevel.capitalized)")
                }

                if slotCanWebSearch {
                    Button(action: { onChangeWebSearch(!slot.webSearchEnabled) }) {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                slot.webSearchEnabled ? Color.blue : Color.secondary.opacity(0.6)
                            )
                            .padding(5)
                            .background(
                                Circle()
                                    .fill(
                                        slot.webSearchEnabled
                                            ? Color.blue.opacity(0.12)
                                            : Color.secondary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(slot.webSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }
            }

            // Status & actions
            HStack(spacing: 8) {
                if slot.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if let elapsed = slot.elapsedTime {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.1))
                        )
                }

                if let onRemove = onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(6)
                            .background(Circle().fill(Color.secondary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Provider Menu

    private var providerMenu: some View {
        Menu {
            Button(action: { onChangeProvider("Apple Foundation", "Apple Foundation") }) {
                Label("Apple Foundation", systemImage: "apple.logo")
            }
            Divider()
            Menu("Gemini API") {
                ForEach(GeminiModelManager.modelGroups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models, id: \.self) { model in
                            Button(action: { onChangeProvider("Gemini API", model) }) {
                                if slot.provider == "Gemini API" && slot.model == model {
                                    Label(
                                        geminiManager.displayName(for: model),
                                        systemImage: "checkmark")
                                } else {
                                    Text(geminiManager.displayName(for: model))
                                }
                            }
                        }
                    }
                }
            }
            Menu("Ollama") {
                ForEach(ollamaManager.allModels, id: \.self) { model in
                    Button(action: { onChangeProvider("Ollama", model) }) {
                        if slot.provider == "Ollama" && slot.model == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            }
            if hasNvidiaKey {
                Menu("NVIDIA API") {
                    ForEach(NvidiaModelManager.modelGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.models, id: \.self) { model in
                                Button(action: { onChangeProvider("NVIDIA API", model) }) {
                                    if slot.provider == "NVIDIA API" && slot.model == model {
                                        Label(
                                            nvidiaManager.displayName(for: model),
                                            systemImage: "checkmark")
                                    } else {
                                        Text(nvidiaManager.displayName(for: model))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if hasCopilotAuth {
                Menu("GitHub Copilot") {
                    ForEach(copilotModelManager.chatModels, id: \.self) { model in
                        Button(action: { onChangeProvider("GitHub Copilot", model) }) {
                            if slot.provider == "GitHub Copilot" && slot.model == model {
                                Label(
                                    copilotModelManager.displayName(for: model),
                                    systemImage: "checkmark")
                            } else {
                                Text(copilotModelManager.displayName(for: model))
                            }
                        }
                    }
                }
            }
            if geminiCLIService.isAvailable {
                Menu("Gemini CLI") {
                    ForEach(GeminiCLIService.availableModels, id: \.id) { model in
                        Button(action: { onChangeProvider("Gemini CLI", model.id) }) {
                            if slot.provider == "Gemini CLI" && slot.model == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(slot.provider)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Model Label

    private var modelLabel: some View {
        Text(slot.model)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Card Body

    @ViewBuilder
    private var cardBody: some View {
        if let error = slot.error {
            // Error state
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else if slot.response.isEmpty && !slot.isLoading {
            // Empty / waiting state
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary.opacity(0.3))
                Text("Response will appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else if slot.isLoading && slot.response.isEmpty {
            // Loading pulse
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(accentColor.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .scaleEffect(slot.isLoading ? 1.0 : 0.5)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.15),
                                value: slot.isLoading
                            )
                    }
                }
                Text("Generating...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else {
            // Response content
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let thinking = slot.thinkingContent, !thinking.isEmpty {
                        DisclosureGroup {
                            Text(thinking)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineSpacing(3)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11))
                                Text("Thinking")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.purple)
                        }
                        .padding(.bottom, 4)
                    }

                    MarkdownView(blocks: Message.parseMarkdown(slot.response))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .frame(minHeight: 120, maxHeight: 400)

            // Copy button + small model warning
            VStack(spacing: 6) {
                // Model disclaimer for all providers
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text("Information could be inaccurate")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

                HStack {
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(slot.response, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(showCopied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(showCopied ? Color.green : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                showCopied
                                    ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
                        )
                        .animation(.easeInOut(duration: 0.2), value: showCopied)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 10)
        }
    }
}
