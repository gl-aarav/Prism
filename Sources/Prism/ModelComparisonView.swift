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
}

// MARK: - Model Comparison View

struct ModelComparisonView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared

    @State private var slots: [ComparisonSlot] = ModelComparisonView.loadSavedSlots()
    @State private var prompt: String = ""
    @State private var isComparing: Bool = false
    @State private var currentTasks: [UUID: Task<Void, Never>] = [:]
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    // Synthesize state
    @State private var showSynthesizePanel: Bool = false
    @State private var synthesizedResponse: String = ""
    @State private var synthesizedThinking: String = ""
    @State private var isSynthesizing: Bool = false
    @State private var synthesizeProvider: String = "Gemini API"
    @State private var synthesizeModel: String = "gemini-2.5-flash"
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @State private var synthesizeTask: Task<Void, Never>?

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()

    // MARK: - Slot Persistence

    private static func loadSavedSlots() -> [ComparisonSlot] {
        if let savedData = UserDefaults.standard.array(forKey: "ComparisonSlots")
            as? [[String: String]],
            savedData.count >= 2
        {
            return savedData.map {
                ComparisonSlot(
                    provider: $0["provider"] ?? "Gemini API",
                    model: $0["model"] ?? "gemini-2.5-flash"
                )
            }
        }
        return [
            ComparisonSlot(provider: "Gemini API", model: "gemini-2.5-flash"),
            ComparisonSlot(provider: "Ollama", model: "llama3.3"),
        ]
    }

    private func saveSlots() {
        let data = slots.map { ["provider": $0.provider, "model": $0.model] }
        UserDefaults.standard.set(data, forKey: "ComparisonSlots")
    }

    // Liquid Glass palette (matching main InputView)
    private var innerGlowTop: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .white.opacity(0.7)
    }
    private var innerGlowBottom: Color {
        colorScheme == .dark ? .white.opacity(0.04) : .white.opacity(0.15)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            // Model Slots
            ScrollView {
                VStack(spacing: 16) {
                    // Model Cards Grid
                    let columns =
                        slots.count <= 2
                        ? Array(repeating: GridItem(.flexible(), spacing: 16), count: slots.count)
                        : Array(
                            repeating: GridItem(.flexible(), spacing: 16),
                            count: min(slots.count, 4))

                    LazyVGrid(columns: columns, spacing: 16) {
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
                                        slots[idx].provider = provider
                                        slots[idx].model = model
                                        saveSlots()
                                    }
                                },
                                ollamaManager: ollamaManager,
                                geminiManager: geminiManager
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Synthesize button
                    if slots.filter({ !$0.response.isEmpty && !$0.isLoading }).count >= 2 {
                        Button(action: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                showSynthesizePanel.toggle()
                                if !showSynthesizePanel {
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
                                    showSynthesizePanel
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
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                LinearGradient(
                                                    colors: appTheme.colors.map { $0.opacity(0.4) },
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 0.8
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Combine all responses into one using AI")
                        .padding(.top, 8)
                    }

                    // Inline synthesis panel
                    if showSynthesizePanel {
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
                .padding(.bottom, 100)
            }

            // Input Bar
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
            for i in slots.indices {
                slots[i].isLoading = false
            }
            isComparing = false
            isSynthesizing = false
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Title
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Model Comparison")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

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
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )

            // Add model button
            if slots.count < 4 {
                Button(action: addSlot) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add Model")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.primary.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            // Clear all
            if slots.contains(where: { !$0.response.isEmpty }) {
                Button(action: clearAll) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Clear all responses")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
                            .foregroundColor(.secondary.opacity(0.6))
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }
                    TextField("", text: $prompt, axis: .vertical)
                        .focused($isInputFocused)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .lineLimit(1...5)
                        .onKeyPress(.return) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                return .ignored
                            } else {
                                startComparison()
                                return .handled
                            }
                        }
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
                            .foregroundColor(
                                isComparing
                                    ? .white
                                    : (colorScheme == .dark ? .black : .white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(prompt.isEmpty && !isComparing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Liquid Glass container
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.06) : Color.white.opacity(0.4),
                                    Color.clear,
                                    colorScheme == .dark
                                        ? Color.black.opacity(0.08) : Color.black.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isInputFocused
                                ? [
                                    innerGlowTop,
                                    Color(hue: 0.6, saturation: 0.3, brightness: 1.0).opacity(0.3),
                                    innerGlowBottom,
                                    Color(hue: 0.8, saturation: 0.3, brightness: 1.0).opacity(0.2),
                                    innerGlowTop.opacity(0.5),
                                ]
                                : [innerGlowTop, innerGlowBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isInputFocused ? 1.2 : 0.8
                    )
                    .animation(.easeInOut(duration: 0.35), value: isInputFocused)
            )
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
                        ForEach(geminiManager.availableModels, id: \.self) { model in
                            Button(action: {
                                synthesizeProvider = "Gemini API"
                                synthesizeModel = model
                            }) {
                                if synthesizeProvider == "Gemini API" && synthesizeModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
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
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: synthesizeProviderIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(synthesizeProvider) — \(synthesizeModel)")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if !isSynthesizing && synthesizedResponse.isEmpty {
                    Button(action: startSynthesis) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Generate")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(colorScheme == .dark ? .black : .white)
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
                        .foregroundColor(.red)
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
                            synthesizedResponse = ""
                            synthesizedThinking = ""
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Retry")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(synthesizedResponse, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("Copy")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
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

            // Response content
            if synthesizedResponse.isEmpty && !isSynthesizing {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.2))
                        Text("Select a model and tap Generate")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                Divider().opacity(0.2).padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !synthesizedThinking.isEmpty {
                            DisclosureGroup {
                                Text(synthesizedThinking)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.system(size: 11))
                                    Text("Thinking")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.purple)
                            }
                            .padding(.bottom, 4)
                        }

                        Text(synthesizedResponse)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(maxHeight: 350)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: synthesizedResponse)

                if !synthesizedResponse.isEmpty && !isSynthesizing {
                    HStack {
                        Text("Synthesized by \(synthesizeProvider) — \(synthesizeModel)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.04)
                        : Color.white.opacity(0.6)
                )
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: appTheme.colors.map { $0.opacity(0.3) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var synthesizeProviderIcon: String {
        switch synthesizeProvider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        default: return "cpu"
        }
    }

    /// Compute the effective thinking level for a given provider/model.
    /// Gemini never gets thinking. Ollama gpt-oss gets the app-level thinkingLevel.
    /// DeepSeek gets true only when "high". All others get "false".
    private func effectiveThinkingLevel(provider: String, model: String) -> String {
        if provider == "Gemini API" {
            return "none"
        } else if provider == "Ollama" {
            let lower = model.lowercased()
            if lower.contains("gpt-oss") {
                return thinkingLevel  // low, medium, high from app setting
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return thinkingLevel == "high" ? "true" : "false"
            }
            return "false"
        }
        return "none"
    }

    private func startSynthesis() {
        let completedSlots = slots.filter { !$0.response.isEmpty && !$0.isLoading }
        guard completedSlots.count >= 2 else { return }

        synthesizedResponse = ""
        synthesizedThinking = ""
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
            provider: synthesizeProvider, model: synthesizeModel)

        synthesizeTask = Task {
            do {
                switch synthesizeProvider {
                case "Gemini API":
                    guard !geminiKey.isEmpty else {
                        await MainActor.run {
                            synthesizedResponse = "Error: No Gemini API key set."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    for try await (chunk, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: synthesizeModel,
                        systemPrompt: "",
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { synthesizedResponse = content }
                    }

                case "Ollama":
                    var full = ""
                    var fullThinking = ""
                    for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: synthesizeModel,
                        systemPrompt: "",
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        if let t = thinkChunk { fullThinking += t }
                        let content = full
                        let thinking = fullThinking
                        await MainActor.run {
                            synthesizedResponse = content
                            if !thinking.isEmpty {
                                synthesizedThinking = thinking
                            }
                        }
                    }

                case "Apple Foundation":
                    var full = ""
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { synthesizedResponse = content }
                    }

                default:
                    await MainActor.run {
                        synthesizedResponse = "Error: Provider not supported."
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        if synthesizedResponse.isEmpty {
                            synthesizedResponse = "Error: \(error.localizedDescription)"
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
            slots.append(ComparisonSlot(provider: newDefault.0, model: newDefault.1))
        }
        saveSlots()
    }

    private func removeSlot(at index: Int) {
        guard slots.count > 2, index < slots.count else { return }
        let slotId = slots[index].id
        currentTasks[slotId]?.cancel()
        currentTasks.removeValue(forKey: slotId)
        let _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            slots.remove(at: index)
        }
        saveSlots()
    }

    private func clearAll() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        withAnimation {
            for i in slots.indices {
                slots[i].response = ""
                slots[i].error = nil
                slots[i].isLoading = false
                slots[i].thinkingContent = nil
                slots[i].elapsedTime = nil
            }
        }
        isComparing = false
    }

    private func stopComparison() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        for i in slots.indices {
            slots[i].isLoading = false
        }
        isComparing = false
    }

    private func startComparison() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isComparing = true
        // Reset all slots
        for i in slots.indices {
            slots[i].response = ""
            slots[i].error = nil
            slots[i].isLoading = true
            slots[i].thinkingContent = nil
            slots[i].elapsedTime = nil
        }

        // Build a minimal history with just the user message
        let userMsg = Message(content: trimmed, isUser: true)
        let history = [userMsg]

        // Launch parallel tasks for each slot
        for i in slots.indices {
            let slotId = slots[i].id
            let provider = slots[i].provider
            let model = slots[i].model

            let task = Task {
                let startTime = Date()
                do {
                    switch provider {
                    case "Gemini API":
                        guard !geminiKey.isEmpty else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    slots[idx].error = "No Gemini API key set"
                                    slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        let geminiThinking = effectiveThinkingLevel(
                            provider: provider, model: model)
                        for try await (chunk, _) in geminiService.sendMessageStream(
                            history: history, apiKey: geminiKey, model: model,
                            systemPrompt: systemPrompt, thinkingLevel: geminiThinking
                        ) {
                            fullContent += chunk
                            let content = fullContent
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    slots[idx].response = content
                                }
                            }
                        }
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                slots[idx].isLoading = false
                                slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Ollama":
                        var fullContent = ""
                        var fullThinking = ""
                        let ollamaThinking = effectiveThinkingLevel(
                            provider: provider, model: model)
                        for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                            history: history, endpoint: ollamaURL, model: model,
                            systemPrompt: systemPrompt, thinkingLevel: ollamaThinking
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }
                            let content = fullContent
                            let thinking = fullThinking
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    slots[idx].response = content
                                    if !thinking.isEmpty {
                                        slots[idx].thinkingContent = thinking
                                    }
                                }
                            }
                        }
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                slots[idx].isLoading = false
                                slots[idx].elapsedTime = elapsed
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
                                    slots[idx].response = content
                                }
                            }
                        }
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                slots[idx].isLoading = false
                                slots[idx].elapsedTime = elapsed
                            }
                        }

                    default:
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                slots[idx].error =
                                    "Provider '\(provider)' not supported for comparison"
                                slots[idx].isLoading = false
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                slots[idx].error = error.localizedDescription
                                slots[idx].isLoading = false
                                slots[idx].elapsedTime = elapsed
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

    @ObservedObject var ollamaManager: OllamaModelManager
    @ObservedObject var geminiManager: GeminiModelManager
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
        default: return "cpu"
        }
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.04)
                        : Color.white.opacity(0.6)
                )
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isHovered
                        ? accentColor.opacity(0.4)
                        : (colorScheme == .dark
                            ? Color.white.opacity(0.1) : Color.black.opacity(0.06)),
                    lineWidth: isHovered ? 1.5 : 0.8
                )
        )
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
                    .foregroundColor(accentColor)
            }

            // Provider & Model selector
            VStack(alignment: .leading, spacing: 2) {
                providerMenu
                modelLabel
            }

            Spacer()

            // Status & actions
            HStack(spacing: 8) {
                if slot.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if let elapsed = slot.elapsedTime {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary.opacity(0.6))
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
                ForEach(geminiManager.availableModels, id: \.self) { model in
                    Button(action: { onChangeProvider("Gemini API", model) }) {
                        if slot.provider == "Gemini API" && slot.model == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
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
        } label: {
            HStack(spacing: 4) {
                Text(slot.provider)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Model Label

    private var modelLabel: some View {
        Text(slot.model)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
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
                    .foregroundColor(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary.opacity(0.3))
                Text("Response will appear here")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))
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
                    .foregroundColor(.secondary)
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
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineSpacing(3)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11))
                                Text("Thinking")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.purple)
                        }
                        .padding(.bottom, 4)
                    }

                    Text(slot.response)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                }
                .padding(14)
            }
            .frame(minHeight: 120, maxHeight: 400)

            // Copy button
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
                    .foregroundColor(showCopied ? .green : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            showCopied ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
                    )
                    .animation(.easeInOut(duration: 0.2), value: showCopied)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }
}
