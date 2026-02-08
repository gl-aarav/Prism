import SwiftUI

// MARK: - Quiz Data Models

struct QuizQuestion: Identifiable, Codable {
    var id = UUID()
    let question: String
    let options: [String]
    let correctIndex: Int
    let explanation: String
}

// MARK: - Quiz Me View

struct QuizMeView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    // Persisted quiz state
    @AppStorage("QuizProvider") private var quizProvider: String = "Gemini API"
    @AppStorage("QuizModel") private var quizModel: String = "gemini-2.5-flash"
    @AppStorage("QuizTopic") private var topic: String = ""
    @AppStorage("QuizNumberOfQuestions") private var numberOfQuestions: Int = 5
    @AppStorage("QuizCurrentIndex") private var currentQuestionIndex: Int = 0
    @AppStorage("QuizScore") private var score: Int = 0
    @AppStorage("QuizFinished") private var quizFinished: Bool = false
    @AppStorage("QuizSelectedAnswer") private var persistedSelectedAnswer: Int = -1
    @AppStorage("QuizShowExplanation") private var showExplanation: Bool = false

    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared

    @State private var questions: [QuizQuestion] = []
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil
    @State private var generateTask: Task<Void, Never>?
    @State private var showCustomQuestionSheet: Bool = false
    @State private var customQuestion: String = ""
    @State private var customOptionA: String = ""
    @State private var customOptionB: String = ""
    @State private var customOptionC: String = ""
    @State private var customOptionD: String = ""
    @State private var customCorrectAnswer: String = "A"
    @State private var customExplanation: String = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var selectedAnswer: Int? {
        persistedSelectedAnswer >= 0 ? persistedSelectedAnswer : nil
    }

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            quizHeader

            if questions.isEmpty && !isGenerating {
                // Setup screen
                quizSetup
            } else if isGenerating {
                generatingView
            } else if quizFinished {
                quizResults
            } else {
                quizQuestionView
            }
        }
        .background(Color.clear)
        .onAppear { loadQuestions() }
        .onDisappear {
            generateTask?.cancel()
            generateTask = nil
            isGenerating = false
        }
        .sheet(isPresented: $showCustomQuestionSheet) {
            customQuestionSheet
        }
    }

    // MARK: - Question Persistence

    private func saveQuestions() {
        if let data = try? JSONEncoder().encode(questions) {
            UserDefaults.standard.set(data, forKey: "QuizQuestions")
        }
    }

    private func loadQuestions() {
        if let data = UserDefaults.standard.data(forKey: "QuizQuestions"),
            let saved = try? JSONDecoder().decode([QuizQuestion].self, from: data),
            !saved.isEmpty
        {
            questions = saved
        }
    }

    private func clearSavedQuestions() {
        UserDefaults.standard.removeObject(forKey: "QuizQuestions")
    }

    // MARK: - Header

    private var quizHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Quiz Me")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            Spacer()

            if !questions.isEmpty {
                // Progress indicator
                HStack(spacing: 4) {
                    Text("\(min(currentQuestionIndex + 1, questions.count))/\(questions.count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))

                // Score
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                    Text("\(score)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))

                // Reset
                Button(action: resetQuiz) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("New Quiz")

                // Add custom question
                Button(action: { showCustomQuestionSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Add Custom Question")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Setup Screen

    private var quizSetup: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: appTheme.colors.map { $0.opacity(0.15) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 6) {
                    Text("Test Your Knowledge")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("Enter a topic and AI will generate a quiz for you")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                // Topic input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Topic")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField(
                        "e.g. Quantum Physics, World History, Swift Programming...", text: $topic
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.8)
                    )
                    .focused($isInputFocused)
                    .onSubmit { startQuiz() }
                }
                .frame(maxWidth: 400)

                // Number of questions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Questions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $numberOfQuestions) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                .frame(maxWidth: 400)

                // Provider selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Provider")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)

                    Menu {
                        Button(action: {
                            quizProvider = "Apple Foundation"
                            quizModel = "Apple Foundation"
                        }) {
                            Label("Apple Foundation", systemImage: "apple.logo")
                        }
                        Divider()
                        Menu("Gemini API") {
                            ForEach(geminiManager.availableModels, id: \.self) { model in
                                Button(action: {
                                    quizProvider = "Gemini API"
                                    quizModel = model
                                }) {
                                    Text(model)
                                }
                            }
                        }
                        Menu("Ollama") {
                            ForEach(ollamaManager.allModels, id: \.self) { model in
                                Button(action: {
                                    quizProvider = "Ollama"
                                    quizModel = model
                                }) {
                                    Text(model)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: providerIcon)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(quizProvider) — \(quizModel)")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.8)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
                .frame(maxWidth: 400)

                // Small model warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Results may be less accurate when using small or local models.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: 400, alignment: .leading)

                if let error = generationError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(8)
                        .frame(maxWidth: 400)
                }

                // Start button
                Button(action: startQuiz) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                        Text("Start Quiz")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
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
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)

                Text("or")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))

                Button(action: { showCustomQuestionSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13))
                        Text("Create Custom Quiz")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.primary.opacity(0.7))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Generating View

    private var generatingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Generating quiz on \"\(topic)\"...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
            Text("Using \(quizProvider) — \(quizModel)")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.6))
            Button("Cancel") {
                generateTask?.cancel()
                generateTask = nil
                isGenerating = false
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            Spacer()
        }
    }

    // MARK: - Question View

    private var quizQuestionView: some View {
        let question = questions[currentQuestionIndex]

        return ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 20)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 6)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: appTheme.colors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: geo.size.width * CGFloat(currentQuestionIndex)
                                    / CGFloat(questions.count),
                                height: 6
                            )
                            .animation(.spring(response: 0.4), value: currentQuestionIndex)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 20)

                // Question card
                VStack(alignment: .leading, spacing: 16) {
                    Text("Question \(currentQuestionIndex + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)

                    MarkdownView(blocks: Message.parseMarkdown(question.question))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.04) : Color.white.opacity(0.6)
                        )
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 0.8)
                )
                .padding(.horizontal, 20)

                // Options
                VStack(spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button(action: {
                            guard selectedAnswer == nil else { return }
                            persistedSelectedAnswer = index
                            showExplanation = true
                            if index == question.correctIndex {
                                score += 1
                            }
                        }) {
                            HStack(spacing: 12) {
                                // Letter indicator
                                ZStack {
                                    Circle()
                                        .fill(
                                            optionBackgroundColor(
                                                for: index, correct: question.correctIndex)
                                        )
                                        .frame(width: 32, height: 32)
                                    Text(String(Character(UnicodeScalar(65 + index)!)))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(
                                            optionTextColor(
                                                for: index, correct: question.correctIndex))
                                }

                                Text(option)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)

                                Spacer()

                                if let selected = selectedAnswer {
                                    if index == question.correctIndex {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else if index == selected {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        optionRowBackground(
                                            for: index, correct: question.correctIndex))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        optionBorderColor(
                                            for: index, correct: question.correctIndex),
                                        lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.2), value: selectedAnswer)
                    }
                }
                .padding(.horizontal, 20)

                // Explanation
                if showExplanation {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: selectedAnswer == question.correctIndex
                                    ? "lightbulb.fill" : "exclamationmark.circle"
                            )
                            .foregroundColor(
                                selectedAnswer == question.correctIndex ? .yellow : .orange)
                            Text(selectedAnswer == question.correctIndex ? "Correct!" : "Not quite")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(
                                    selectedAnswer == question.correctIndex ? .green : .red)
                        }
                        MarkdownView(blocks: Message.parseMarkdown(question.explanation))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                (selectedAnswer == question.correctIndex
                                    ? Color.green : Color.orange).opacity(0.06)
                            )
                    )
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    // Next button
                    Button(action: nextQuestion) {
                        HStack(spacing: 6) {
                            Text(
                                currentQuestionIndex < questions.count - 1
                                    ? "Next Question" : "See Results"
                            )
                            .font(.system(size: 14, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
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
                    .padding(.top, 4)
                }

                Spacer().frame(height: 40)
            }
        }
    }

    // MARK: - Results View

    private var quizResults: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: appTheme.colors.map { $0.opacity(0.15) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                    VStack(spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: appTheme.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("/ \(questions.count)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Text(scoreMessage)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Topic: \(topic)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                // Small model warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Results may be less accurate when using small or local models.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                HStack(spacing: 12) {
                    Button(action: resetQuiz) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("New Quiz")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)

                    Button(action: retryQuiz) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.2.squarepath")
                            Text("Retry Same Topic")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
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
                }

                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Helpers

    private var scoreMessage: String {
        let percentage = Double(score) / Double(questions.count)
        if percentage >= 0.9 { return "Outstanding! 🌟" }
        if percentage >= 0.7 { return "Great job! 👏" }
        if percentage >= 0.5 { return "Not bad! 💪" }
        return "Keep learning! 📚"
    }

    private var providerIcon: String {
        switch quizProvider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        default: return "cpu"
        }
    }

    private func optionBackgroundColor(for index: Int, correct: Int) -> Color {
        guard let selected = selectedAnswer else {
            return Color.secondary.opacity(0.1)
        }
        if index == correct { return Color.green.opacity(0.2) }
        if index == selected { return Color.red.opacity(0.2) }
        return Color.secondary.opacity(0.1)
    }

    private func optionTextColor(for index: Int, correct: Int) -> Color {
        guard let selected = selectedAnswer else {
            return .primary
        }
        if index == correct { return .green }
        if index == selected { return .red }
        return .primary
    }

    private func optionRowBackground(for index: Int, correct: Int) -> Color {
        guard let selected = selectedAnswer else {
            return colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)
        }
        if index == correct { return Color.green.opacity(0.06) }
        if index == selected { return Color.red.opacity(0.06) }
        return colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)
    }

    private func optionBorderColor(for index: Int, correct: Int) -> Color {
        guard let selected = selectedAnswer else {
            return Color.secondary.opacity(0.1)
        }
        if index == correct { return Color.green.opacity(0.4) }
        if index == selected { return Color.red.opacity(0.4) }
        return Color.secondary.opacity(0.1)
    }

    // MARK: - Actions

    private func resetQuiz() {
        generateTask?.cancel()
        generateTask = nil
        withAnimation {
            questions = []
            currentQuestionIndex = 0
            persistedSelectedAnswer = -1
            showExplanation = false
            score = 0
            quizFinished = false
            isGenerating = false
            generationError = nil
            topic = ""
        }
        clearSavedQuestions()
    }

    private func retryQuiz() {
        withAnimation {
            questions = []
            currentQuestionIndex = 0
            persistedSelectedAnswer = -1
            showExplanation = false
            score = 0
            quizFinished = false
        }
        clearSavedQuestions()
        startQuiz()
    }

    private func nextQuestion() {
        if currentQuestionIndex < questions.count - 1 {
            withAnimation {
                currentQuestionIndex += 1
                persistedSelectedAnswer = -1
                showExplanation = false
            }
        } else {
            withAnimation {
                quizFinished = true
            }
        }
    }

    private func addCustomQuestion() {
        let correctIdx: Int
        switch customCorrectAnswer {
        case "A": correctIdx = 0
        case "B": correctIdx = 1
        case "C": correctIdx = 2
        case "D": correctIdx = 3
        default: correctIdx = 0
        }
        let newQ = QuizQuestion(
            question: customQuestion.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [
                customOptionA.trimmingCharacters(in: .whitespacesAndNewlines),
                customOptionB.trimmingCharacters(in: .whitespacesAndNewlines),
                customOptionC.trimmingCharacters(in: .whitespacesAndNewlines),
                customOptionD.trimmingCharacters(in: .whitespacesAndNewlines),
            ],
            correctIndex: correctIdx,
            explanation: customExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        withAnimation {
            questions.append(newQ)
            if quizFinished {
                quizFinished = false
            }
        }
        saveQuestions()

        // Clear form
        customQuestion = ""
        customOptionA = ""
        customOptionB = ""
        customOptionC = ""
        customOptionD = ""
        customCorrectAnswer = "A"
        customExplanation = ""
        showCustomQuestionSheet = false
    }

    // MARK: - Custom Question Sheet

    private var customQuestionSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Add Custom Question")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button(action: { showCustomQuestionSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Question")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("Enter your question...", text: $customQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Options")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text("A)").font(.system(size: 12, weight: .semibold)).foregroundColor(
                        .secondary
                    ).frame(width: 22)
                    TextField("Option A", text: $customOptionA)
                        .textFieldStyle(.plain).font(.system(size: 13)).padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                }
                HStack(spacing: 6) {
                    Text("B)").font(.system(size: 12, weight: .semibold)).foregroundColor(
                        .secondary
                    ).frame(width: 22)
                    TextField("Option B", text: $customOptionB)
                        .textFieldStyle(.plain).font(.system(size: 13)).padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                }
                HStack(spacing: 6) {
                    Text("C)").font(.system(size: 12, weight: .semibold)).foregroundColor(
                        .secondary
                    ).frame(width: 22)
                    TextField("Option C", text: $customOptionC)
                        .textFieldStyle(.plain).font(.system(size: 13)).padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                }
                HStack(spacing: 6) {
                    Text("D)").font(.system(size: 12, weight: .semibold)).foregroundColor(
                        .secondary
                    ).frame(width: 22)
                    TextField("Option D", text: $customOptionD)
                        .textFieldStyle(.plain).font(.system(size: 13)).padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Correct Answer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $customCorrectAnswer) {
                        Text("A").tag("A")
                        Text("B").tag("B")
                        Text("C").tag("C")
                        Text("D").tag("D")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Explanation (optional)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("Why is this the correct answer?", text: $customExplanation)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
            }

            HStack {
                Spacer()
                Button(action: addCustomQuestion) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("Add Question")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
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
                .disabled(
                    customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || customOptionA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || customOptionB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || customOptionC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || customOptionD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func startQuiz() {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true
        generationError = nil

        let prompt = """
            Generate exactly \(numberOfQuestions) multiple choice quiz questions about: \(trimmed)

            Format your response EXACTLY as follows, with no extra text before or after:

            Q: [question text]
            A) [option A]
            B) [option B]
            C) [option C]
            D) [option D]
            CORRECT: [A, B, C, or D]
            EXPLANATION: [brief explanation]

            Q: [next question]
            ...

            Make the questions varied in difficulty. Ensure exactly 4 options per question.
            """

        let userMsg = Message(content: prompt, isUser: true)
        let history = [userMsg]

        generateTask = Task {
            do {
                var fullContent = ""

                switch quizProvider {
                case "Gemini API":
                    guard !geminiKey.isEmpty else {
                        await MainActor.run {
                            generationError = "No Gemini API key set. Please configure in Settings."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: quizModel,
                        systemPrompt: "", thinkingLevel: "none"
                    ) {
                        fullContent += chunk
                    }

                case "Ollama":
                    for try await (chunk, _) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: quizModel,
                        systemPrompt: "", thinkingLevel: "false"
                    ) {
                        fullContent += chunk
                    }

                case "Apple Foundation":
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }

                default:
                    await MainActor.run {
                        generationError = "Provider not supported."
                        isGenerating = false
                    }
                    return
                }

                let parsed = parseQuizResponse(fullContent)
                await MainActor.run {
                    if parsed.isEmpty {
                        generationError =
                            "Failed to parse quiz questions. Try a different topic or model."
                        isGenerating = false
                    } else {
                        questions = parsed
                        currentQuestionIndex = 0
                        persistedSelectedAnswer = -1
                        showExplanation = false
                        score = 0
                        quizFinished = false
                        isGenerating = false
                        saveQuestions()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        generationError = "Error: \(error.localizedDescription)"
                        isGenerating = false
                    }
                }
            }
        }
    }

    // MARK: - Parser

    private func parseQuizResponse(_ text: String) -> [QuizQuestion] {
        var questions: [QuizQuestion] = []
        let lines = text.components(separatedBy: "\n")

        var currentQuestion: String?
        var options: [String] = []
        var correctIndex: Int?
        var explanation: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("Q:") || trimmed.hasPrefix("Q ") {
                // Save previous question
                if let q = currentQuestion, options.count == 4, let ci = correctIndex {
                    questions.append(
                        QuizQuestion(
                            question: q,
                            options: options,
                            correctIndex: ci,
                            explanation: explanation ?? ""
                        ))
                }
                currentQuestion = String(trimmed.dropFirst(2)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                options = []
                correctIndex = nil
                explanation = nil
            } else if trimmed.hasPrefix("A)") || trimmed.hasPrefix("A.") {
                options.append(
                    String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("B)") || trimmed.hasPrefix("B.") {
                options.append(
                    String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("C)") || trimmed.hasPrefix("C.") {
                options.append(
                    String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("D)") || trimmed.hasPrefix("D.") {
                options.append(
                    String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.uppercased().hasPrefix("CORRECT:") {
                let answer = trimmed.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                switch answer.first {
                case "A": correctIndex = 0
                case "B": correctIndex = 1
                case "C": correctIndex = 2
                case "D": correctIndex = 3
                default: break
                }
            } else if trimmed.uppercased().hasPrefix("EXPLANATION:") {
                explanation = String(trimmed.dropFirst(12)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            } else if currentQuestion != nil && options.isEmpty {
                // Continuation of question
                currentQuestion = (currentQuestion ?? "") + " " + trimmed
            } else if let existing = explanation {
                explanation = existing + " " + trimmed
            }
        }

        // Don't forget the last question
        if let q = currentQuestion, options.count == 4, let ci = correctIndex {
            questions.append(
                QuizQuestion(
                    question: q,
                    options: options,
                    correctIndex: ci,
                    explanation: explanation ?? ""
                ))
        }

        return questions
    }
}
