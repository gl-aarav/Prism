import SwiftUI

// MARK: - Quiz Data Models

enum QuizQuestionType: String, Codable, CaseIterable {
    case mcq = "MCQ"
    case trueFalse = "True/False"
    case frq = "FRQ"
}

struct QuizQuestion: Identifiable, Codable {
    var id = UUID()
    let question: String
    let questionType: QuizQuestionType
    let options: [String]
    let correctIndex: Int  // For MCQ/T-F: index of correct option; For FRQ: -1
    let correctAnswer: String  // For FRQ: the expected answer text
    let explanation: String

    init(
        id: UUID = UUID(), question: String, questionType: QuizQuestionType = .mcq,
        options: [String], correctIndex: Int, correctAnswer: String = "", explanation: String
    ) {
        self.id = id
        self.question = question
        self.questionType = questionType
        self.options = options
        self.correctIndex = correctIndex
        self.correctAnswer = correctAnswer
        self.explanation = explanation
    }
}

struct QuizSession: Identifiable, Codable {
    let id: UUID
    var topic: String
    var difficulty: String
    var questions: [QuizQuestion]
    var currentIndex: Int
    var score: Int
    var finished: Bool
    var selectedAnswers: [Int: Int]  // questionIndex -> selectedOptionIndex (MCQ/TF)
    var frqAnswers: [Int: String]  // questionIndex -> user's FRQ text
    var frqGrades: [Int: FRQGrade]  // questionIndex -> AI grade result
    var timestamp: Date
}

struct FRQGrade: Codable {
    let score: Int  // 0-100
    let feedback: String
    let isCorrect: Bool
}

// MARK: - Quiz Store

class QuizStore: ObservableObject {
    static let shared = QuizStore()

    @Published var sessions: [QuizSession] = []

    private let saveKey = "QuizStoreSessions"

    init() {
        loadSessions()
    }

    func addSession(_ session: QuizSession) {
        sessions.insert(session, at: 0)
        saveSessions()
    }

    func updateSession(_ session: QuizSession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            saveSessions()
        }
    }

    func deleteSession(_ session: QuizSession) {
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }

    func clearAll() {
        sessions.removeAll()
        saveSessions()
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func loadSessions() {
        // Migrate old single-quiz format
        if let oldData = UserDefaults.standard.data(forKey: "QuizQuestions"),
            let oldQuestions = try? JSONDecoder().decode([QuizQuestion].self, from: oldData),
            !oldQuestions.isEmpty
        {
            let topic = UserDefaults.standard.string(forKey: "QuizTopic") ?? "Unknown"
            let difficulty = UserDefaults.standard.string(forKey: "QuizDifficulty") ?? "medium"
            let score = UserDefaults.standard.integer(forKey: "QuizScore")
            let currentIndex = UserDefaults.standard.integer(forKey: "QuizCurrentIndex")
            let finished = UserDefaults.standard.bool(forKey: "QuizFinished")
            let oldSession = QuizSession(
                id: UUID(), topic: topic, difficulty: difficulty,
                questions: oldQuestions, currentIndex: currentIndex, score: score,
                finished: finished, selectedAnswers: [:], frqAnswers: [:], frqGrades: [:],
                timestamp: Date()
            )
            sessions = [oldSession]
            saveSessions()
            // Clean up old keys
            UserDefaults.standard.removeObject(forKey: "QuizQuestions")
        }

        if let data = UserDefaults.standard.data(forKey: saveKey),
            let loaded = try? JSONDecoder().decode([QuizSession].self, from: data)
        {
            sessions = loaded
        }
    }
}

// MARK: - Quiz Me View

struct QuizMeView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String =
        "llama-3.1-70b-instruct"
    @AppStorage("SelectedCopilotModel") private var selectedCopilotModel: String = "gpt-4o"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("QuizProvider") private var quizProvider: String = "Gemini API"
    @AppStorage("QuizModel") private var quizModel: String = "gemini-2.5-flash"

    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @ObservedObject private var copilotModelManager = GitHubCopilotModelManager.shared
    @StateObject private var store = QuizStore.shared

    @State private var activeSessionId: UUID? = nil
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil
    @State private var generateTask: Task<Void, Never>?
    @State private var isRegenerating: Bool = false
    @State private var quizThinkingLevel: String = "medium"
    @State private var quizWebSearchEnabled: Bool = false
    @State private var hoveredOptionIndex: Int? = nil
    @State private var showExplanation: Bool = false
    @State private var isInputExpanded: Bool = false
    @State private var isPromptFocused: Bool = false
    @State private var showResetConfirmation: Bool = false

    // Setup state for new quiz
    @State private var topic: String = ""
    @State private var difficulty: String = "medium"
    @State private var mcqCount: Int = 5
    @State private var tfCount: Int = 0
    @State private var frqCount: Int = 0

    // FRQ grading
    @State private var frqUserAnswer: String = ""
    @State private var isGradingFRQ: Bool = false

    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()
    private let nvidiaService = NvidiaService()
    private let webSearchService = WebSearchService()

    private var activeSession: QuizSession? {
        guard let id = activeSessionId else { return nil }
        return store.sessions.first { $0.id == id }
    }

    private var quizHasThinkingCapability: Bool {
        let lower = quizModel.lowercased()
        return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
    }

    private func effectiveThinkingLevel(provider: String, model: String, level: String) -> String {
        if provider == "Gemini API" {
            return "none"
        } else if provider == "Ollama" {
            let lower = model.lowercased()
            if lower.contains("gpt-oss") {
                return level
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return level == "high" ? "true" : "false"
            }
            return "false"
        }
        return "none"
    }

    var body: some View {
        ZStack {
            Group {
                if let session = activeSession {
                    if isGenerating {
                        generatingView
                    } else if session.finished {
                        quizResults(session)
                    } else {
                        quizQuestionView(session)
                    }
                } else if isGenerating {
                    generatingView
                } else if store.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .safeAreaInset(edge: .top) {
                quizHeader
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear All Quizzes", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.clearAll()
                activeSessionId = nil
            }
        } message: {
            Text("This will permanently delete all quizzes. This cannot be undone.")
        }
        .onDisappear {
            generateTask?.cancel()
            generateTask = nil
            isGenerating = false
        }
    }

    // MARK: - Header

    private var quizHeader: some View {
        HStack(spacing: 10) {
            Spacer()

            if let session = activeSession, !session.finished {
                // Progress indicator
                HStack(spacing: 4) {
                    Text(
                        "\(min(session.currentIndex + 1, session.questions.count))/\(session.questions.count)"
                    )
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

                // Score
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                    Text("\(session.score)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

                // Back to list
                Button(action: { activeSessionId = nil }) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help("All Quizzes")

                // Difficulty badge
                HStack(spacing: 4) {
                    Image(systemName: difficultyIcon(session.difficulty))
                        .font(.system(size: 10))
                        .foregroundStyle(difficultyColor(session.difficulty))
                    Text(session.difficulty.capitalized)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(difficultyColor(session.difficulty))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(difficultyColor(session.difficulty).opacity(0.1)))
            }

            // Provider pill
            HStack(spacing: 4) {
                Image(providerIcon: quizProvider)
                    .font(.system(size: 10))
                Text(quizModel.count > 20 ? String(quizModel.prefix(18)) + "…" : quizModel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)

            if !store.sessions.isEmpty {
                Button(action: { showResetConfirmation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.clear)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .indigo
        let endColor = colors.last ?? .purple

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [startColor.opacity(0.12), startColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .offset(x: -70, y: -50)
                .blur(radius: 40)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [endColor.opacity(0.1), endColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)
                .offset(x: 80, y: 40)
                .blur(radius: 35)

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 82, height: 82)
                        .glassEffect(.regular, in: .circle)
                        .shadow(color: startColor.opacity(0.12), radius: 16, x: 0, y: 8)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("Test Your Knowledge")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("Enter a topic and AI will generate a quiz for you")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                }

                HStack(spacing: 8) {
                    ForEach(["MCQ", "True/False", "FRQ"], id: \.self) { feature in
                        Text(feature)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.top, 2)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.sessions) { session in
                    sessionCard(session)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func sessionCard(_ session: QuizSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.topic)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.difficulty.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(difficultyColor(session.difficulty))
                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))
                        let mcqs = session.questions.filter { $0.questionType == .mcq }.count
                        let tfs = session.questions.filter { $0.questionType == .trueFalse }
                            .count
                        let frqs = session.questions.filter { $0.questionType == .frq }.count
                        if mcqs > 0 {
                            Text("\(mcqs) MCQ")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        if tfs > 0 {
                            Text("\(tfs) T/F")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        if frqs > 0 {
                            Text("\(frqs) FRQ")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))
                        Text(session.timestamp, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                Spacer()

                VStack(spacing: 2) {
                    Text("\(session.score)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("/ \(session.questions.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geo.size.width
                                * CGFloat(
                                    session.finished
                                        ? session.questions.count : session.currentIndex)
                                / CGFloat(max(session.questions.count, 1)),
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            HStack(spacing: 8) {
                Text(session.finished ? "Completed" : "In Progress")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.finished ? .green : .orange)

                Spacer()

                Button(action: {
                    store.deleteSession(session)
                    if activeSessionId == session.id {
                        activeSessionId = nil
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isInputExpanded = false
                activeSessionId = session.id
                let answered =
                    session.selectedAnswers[session.currentIndex] != nil
                    || session.frqGrades[session.currentIndex] != nil
                showExplanation = answered
                frqUserAnswer = session.frqAnswers[session.currentIndex] ?? ""
            }
        }
    }

    // MARK: - Generating View

    private var generatingView: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .indigo
        let endColor = colors.last ?? .purple

        return VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)
                .tint(startColor)

            Text("Generating quiz on \"\(topic)\"…")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [startColor, endColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text("Using \(quizProvider) — \(quizModel)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary.opacity(0.7))

            Button(action: {
                generateTask?.cancel()
                generateTask = nil
                isGenerating = false
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Question View

    private func quizQuestionView(_ session: QuizSession) -> some View {
        let question = session.questions[session.currentIndex]
        let answered =
            session.selectedAnswers[session.currentIndex] != nil
            || session.frqGrades[session.currentIndex] != nil

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
                                width: geo.size.width * CGFloat(session.currentIndex)
                                    / CGFloat(session.questions.count),
                                height: 6
                            )
                            .animation(.spring(response: 0.4), value: session.currentIndex)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 20)

                // Navigation buttons
                HStack {
                    if session.currentIndex > 0 {
                        Button(action: { goToPreviousQuestion() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Previous")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()

                    // Question type badge
                    Text(question.questionType.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(questionTypeColor(question.questionType))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                questionTypeColor(question.questionType).opacity(0.1)))
                }
                .padding(.horizontal, 20)

                // Question card
                VStack(alignment: .leading, spacing: 16) {
                    Text("Question \(session.currentIndex + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)

                    MarkdownView(blocks: Message.parseMarkdown(question.question))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Answer area based on question type
                switch question.questionType {
                case .mcq, .trueFalse:
                    mcqOptionsView(question: question, session: session)
                case .frq:
                    frqAnswerView(question: question, session: session)
                }

                // Explanation
                if showExplanation && answered {
                    explanationView(question: question, session: session)
                }

                Spacer().frame(height: 80)
            }
        }
    }

    // MARK: - MCQ/TF Options

    private func mcqOptionsView(question: QuizQuestion, session: QuizSession) -> some View {
        let selectedAnswer = session.selectedAnswers[session.currentIndex]

        return VStack(spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button(action: {
                    guard selectedAnswer == nil else { return }
                    selectAnswer(index: index, for: session, question: question)
                }) {
                    HStack(spacing: 12) {
                        // Letter indicator
                        ZStack {
                            Circle()
                                .fill(
                                    optionBackgroundColor(
                                        for: index, selected: selectedAnswer,
                                        correct: question.correctIndex)
                                )
                                .frame(width: 32, height: 32)
                            if question.questionType == .trueFalse {
                                Text(index == 0 ? "T" : "F")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(
                                        optionTextColor(
                                            for: index, selected: selectedAnswer,
                                            correct: question.correctIndex))
                            } else {
                                Text(String(Character(UnicodeScalar(65 + index)!)))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(
                                        optionTextColor(
                                            for: index, selected: selectedAnswer,
                                            correct: question.correctIndex))
                            }
                        }

                        Text(option)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Spacer()

                        if let selected = selectedAnswer {
                            if index == question.correctIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if index == selected {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                optionRowBackground(
                                    for: index, selected: selectedAnswer,
                                    correct: question.correctIndex))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                hoveredOptionIndex == index && selectedAnswer == nil
                                    ? appTheme.colors.first?.opacity(0.5)
                                        ?? Color.blue.opacity(0.5)
                                    : optionBorderColor(
                                        for: index, selected: selectedAnswer,
                                        correct: question.correctIndex),
                                lineWidth: hoveredOptionIndex == index && selectedAnswer == nil
                                    ? 1.5 : 1
                            )
                    )
                    .scaleEffect(
                        hoveredOptionIndex == index && selectedAnswer == nil ? 1.02 : 1.0
                    )
                    .shadow(
                        color: hoveredOptionIndex == index && selectedAnswer == nil
                            ? (appTheme.colors.first ?? .blue).opacity(0.15) : .clear,
                        radius: 8, x: 0, y: 2
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hoveredOptionIndex = hovering ? index : nil
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedAnswer)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - FRQ Answer View

    private func frqAnswerView(question: QuizQuestion, session: QuizSession) -> some View {
        let graded = session.frqGrades[session.currentIndex]

        return VStack(spacing: 12) {
            if graded == nil {
                // Text input for FRQ
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Answer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $frqUserAnswer)
                        .font(.system(size: 14))
                        .frame(minHeight: 100, maxHeight: 200)
                        .padding(8)
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
                        .scrollContentBackground(.hidden)

                    Button(action: { gradeFRQ(session: session, question: question) }) {
                        HStack(spacing: 6) {
                            if isGradingFRQ {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            }
                            Text(isGradingFRQ ? "Grading…" : "Submit Answer")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
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
                    .disabled(
                        frqUserAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isGradingFRQ
                    )
                    .opacity(
                        frqUserAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? 0.5 : 1.0)
                }
                .padding(.horizontal, 20)
            } else {
                // Show graded result
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Answer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(session.frqAnswers[session.currentIndex] ?? "")
                        .font(.system(size: 14))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )

                    // Grade display
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                                .frame(width: 44, height: 44)
                            Circle()
                                .trim(
                                    from: 0,
                                    to: CGFloat(graded!.score) / 100.0
                                )
                                .stroke(
                                    graded!.isCorrect ? Color.green : Color.orange,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .frame(width: 44, height: 44)
                                .rotationEffect(.degrees(-90))
                            Text("\(graded!.score)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(graded!.isCorrect ? .green : .orange)
                        }
                        Text(graded!.isCorrect ? "Correct!" : "Needs Improvement")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(graded!.isCorrect ? .green : .orange)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Explanation View

    private func explanationView(question: QuizQuestion, session: QuizSession) -> some View {
        let selectedAnswer = session.selectedAnswers[session.currentIndex]
        let frqGrade = session.frqGrades[session.currentIndex]
        let isCorrect: Bool
        if question.questionType == .frq {
            isCorrect = frqGrade?.isCorrect ?? false
        } else {
            isCorrect = selectedAnswer == question.correctIndex
        }

        return VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(
                        systemName: isCorrect
                            ? "lightbulb.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(isCorrect ? Color.yellow : Color.orange)
                    Text(isCorrect ? "Correct!" : "Not quite")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isCorrect ? Color.green : Color.red)
                }

                if question.questionType == .frq, let grade = frqGrade {
                    MarkdownView(blocks: Message.parseMarkdown(grade.feedback))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownView(blocks: Message.parseMarkdown(question.explanation))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((isCorrect ? Color.green : Color.orange).opacity(0.06))
            )
            .padding(.horizontal, 20)
            .transition(.opacity.combined(with: .move(edge: .top)))

            // Next button
            Button(action: { nextQuestion(session) }) {
                HStack(spacing: 6) {
                    Text(
                        session.currentIndex < session.questions.count - 1
                            ? "Next Question" : "See Results"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
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
    }

    // MARK: - Results View

    private func quizResults(_ session: QuizSession) -> some View {
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
                        Text("\(session.score)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: appTheme.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("/ \(session.questions.count)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(scoreMessage(session))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Topic: \(session.topic)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // Question type breakdown
                let mcqs = session.questions.filter { $0.questionType == .mcq }.count
                let tfs = session.questions.filter { $0.questionType == .trueFalse }.count
                let frqs = session.questions.filter { $0.questionType == .frq }.count
                if mcqs > 0 || tfs > 0 || frqs > 0 {
                    HStack(spacing: 12) {
                        if mcqs > 0 {
                            Text("\(mcqs) MCQ")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.blue.opacity(0.1)))
                        }
                        if tfs > 0 {
                            Text("\(tfs) True/False")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.purple.opacity(0.1)))
                        }
                        if frqs > 0 {
                            Text("\(frqs) FRQ")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.orange.opacity(0.1)))
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Results may be less accurate when using small or local models.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.7))
                }

                HStack(spacing: 12) {
                    Button(action: {
                        activeSessionId = nil
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                            Text("All Quizzes")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)

                    Button(action: { retryQuiz(session) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.2.squarepath")
                            Text("Retry Same Topic")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
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

    // MARK: - Input Bar (Bottom)

    private var inputBar: some View {
        Group {
            if activeSession == nil {
                VStack(spacing: 0) {
                    if isInputExpanded {
                        expandedInputBar
                    } else {
                        collapsedInputBar
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.clear)
            }
        }
    }

    private var collapsedInputBar: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isInputExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPromptFocused = true
            }
        }) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: appTheme.colors.isEmpty
                            ? [.indigo, .purple] : appTheme.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: appTheme.colors.isEmpty
                                    ? [.indigo.opacity(0.5), .purple.opacity(0.5)]
                                    : appTheme.colors.map { $0.opacity(0.5) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.3) : Color.black.opacity(0.06),
            radius: 16, x: 0, y: 6
        )
    }

    private var expandedInputBar: some View {
        VStack(spacing: 8) {
            // Question type counters
            HStack(spacing: 16) {
                // MCQ counter
                HStack(spacing: 6) {
                    Text("MCQ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                    Stepper(value: $mcqCount, in: 0...20) {
                        Text("\(mcqCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 20, alignment: .center)
                    }
                    .frame(width: 90)
                }

                // T/F counter
                HStack(spacing: 6) {
                    Text("T/F")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                    Stepper(value: $tfCount, in: 0...20) {
                        Text("\(tfCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 20, alignment: .center)
                    }
                    .frame(width: 90)
                }

                // FRQ counter
                HStack(spacing: 6) {
                    Text("FRQ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Stepper(value: $frqCount, in: 0...20) {
                        Text("\(frqCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 20, alignment: .center)
                    }
                    .frame(width: 90)
                }

                Spacer()

                // Difficulty selector
                Menu {
                    Button("Easy") { difficulty = "easy" }
                    Button("Medium") { difficulty = "medium" }
                    Button("Hard") { difficulty = "hard" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: difficultyIcon(difficulty))
                            .font(.system(size: 10))
                        Text(difficulty.capitalized)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(difficultyColor(difficulty))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(difficultyColor(difficulty).opacity(0.1)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            // Main input row
            HStack(spacing: 10) {
                // Provider selector
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
                                Text(geminiManager.displayName(for: model))
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
                    if !nvidiaKey.isEmpty {
                        Menu("NVIDIA API") {
                            ForEach(nvidiaManager.availableModels, id: \.self) { model in
                                Button(action: {
                                    quizProvider = "NVIDIA API"
                                    quizModel = model
                                }) {
                                    Text(nvidiaManager.displayName(for: model))
                                }
                            }
                        }
                    }
                    if copilotService.isAuthenticated {
                        Menu("GitHub Copilot") {
                            ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                Button(action: {
                                    quizProvider = "GitHub Copilot"
                                    quizModel = model
                                }) {
                                    Text(copilotModelManager.displayNameWithUsage(for: model))
                                }
                            }
                        }
                    }
                } label: {
                    Image(providerIcon: quizProvider)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.04))
                        )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .help("\(quizProvider) — \(quizModel)")

                // Topic text input
                ZStack(alignment: .leading) {
                    if topic.isEmpty && !isPromptFocused {
                        Text("Enter a quiz topic...")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.55)
                                    : Color.secondary.opacity(0.6)
                            )
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }

                    NativeTextInput(
                        text: $topic,
                        isFocused: $isPromptFocused,
                        font: .systemFont(ofSize: 15),
                        textColor: colorScheme == .dark ? .white : .labelColor,
                        maxLines: 3,
                        onCommit: {
                            startQuiz()
                        },
                        onEscape: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isInputExpanded = false
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Thinking button (Ollama only, capable models)
                if quizProvider == "Ollama" && quizHasThinkingCapability {
                    Menu {
                        Button(action: { quizThinkingLevel = "low" }) {
                            if quizThinkingLevel == "low" {
                                Label("Low", systemImage: "checkmark")
                            } else {
                                Text("Low")
                            }
                        }
                        Button(action: { quizThinkingLevel = "medium" }) {
                            if quizThinkingLevel == "medium" {
                                Label("Medium", systemImage: "checkmark")
                            } else {
                                Text("Medium")
                            }
                        }
                        Button(action: { quizThinkingLevel = "high" }) {
                            if quizThinkingLevel == "high" {
                                Label("High", systemImage: "checkmark")
                            } else {
                                Text("High")
                            }
                        }
                    } label: {
                        Image(systemName: "brain")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.08)
                                            : Color.black.opacity(0.04))
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                    .help("Thinking: \(quizThinkingLevel.capitalized)")
                }

                // Web Search toggle (Ollama)
                if quizProvider == "Ollama" {
                    Button(action: { quizWebSearchEnabled.toggle() }) {
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(
                                quizWebSearchEnabled ? Color.blue : Color.secondary
                            )
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        quizWebSearchEnabled
                                            ? Color.blue.opacity(
                                                colorScheme == .dark ? 0.2 : 0.1)
                                            : (colorScheme == .dark
                                                ? Color.white.opacity(0.08)
                                                : Color.black.opacity(0.04))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(quizWebSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }

                // Send/Stop button
                Button(action: {
                    if isGenerating {
                        generateTask?.cancel()
                        generateTask = nil
                        isGenerating = false
                    } else {
                        startQuiz()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isGenerating
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : topic.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                            || totalQuestionCount == 0
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

                        Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: isGenerating ? 12 : 14, weight: .bold))
                            .foregroundStyle(
                                isGenerating
                                    ? Color.white
                                    : (colorScheme == .dark ? Color.black : Color.white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    (topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || totalQuestionCount == 0)
                        && !isGenerating)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))

            // Error display
            if let error = generationError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
        }
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.3) : Color.black.opacity(0.06),
            radius: 16, x: 0, y: 6
        )
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
            ))
    }

    // MARK: - Helpers

    private var totalQuestionCount: Int {
        mcqCount + tfCount + frqCount
    }

    private func scoreMessage(_ session: QuizSession) -> String {
        let percentage = Double(session.score) / Double(max(session.questions.count, 1))
        if percentage >= 0.9 { return "Outstanding! 🌟" }
        if percentage >= 0.7 { return "Great job! 👏" }
        if percentage >= 0.5 { return "Not bad! 💪" }
        return "Keep learning! 📚"
    }

    private func difficultyIcon(_ diff: String) -> String {
        switch diff {
        case "easy": return "tortoise"
        case "hard": return "flame"
        default: return "gauge.medium"
        }
    }

    private func difficultyColor(_ diff: String) -> Color {
        switch diff {
        case "easy": return .green
        case "hard": return .red
        default: return .orange
        }
    }

    private func questionTypeColor(_ type: QuizQuestionType) -> Color {
        switch type {
        case .mcq: return .blue
        case .trueFalse: return .purple
        case .frq: return .orange
        }
    }

    private var providerIcon: String {
        switch quizProvider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "chevron.left.forwardslash.chevron.right"
        default: return "cpu"
        }
    }

    private func optionBackgroundColor(for index: Int, selected: Int?, correct: Int) -> Color {
        guard let selected = selected else {
            return Color.secondary.opacity(0.1)
        }
        if index == correct { return Color.green.opacity(0.2) }
        if index == selected { return Color.red.opacity(0.2) }
        return Color.secondary.opacity(0.1)
    }

    private func optionTextColor(for index: Int, selected: Int?, correct: Int) -> Color {
        guard let selected = selected else {
            return .primary
        }
        if index == correct { return .green }
        if index == selected { return .red }
        return .primary
    }

    private func optionRowBackground(for index: Int, selected: Int?, correct: Int) -> Color {
        guard let selected = selected else {
            return colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)
        }
        if index == correct { return Color.green.opacity(0.06) }
        if index == selected { return Color.red.opacity(0.06) }
        return colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)
    }

    private func optionBorderColor(for index: Int, selected: Int?, correct: Int) -> Color {
        guard let selected = selected else {
            return Color.secondary.opacity(0.1)
        }
        if index == correct { return Color.green.opacity(0.4) }
        if index == selected { return Color.red.opacity(0.4) }
        return Color.secondary.opacity(0.1)
    }

    // MARK: - Actions

    private func selectAnswer(index: Int, for session: QuizSession, question: QuizQuestion) {
        var updated = session
        updated.selectedAnswers[session.currentIndex] = index
        if index == question.correctIndex {
            updated.score += 1
        }
        store.updateSession(updated)
        withAnimation {
            showExplanation = true
        }
    }

    private func goToPreviousQuestion() {
        guard var session = activeSession, session.currentIndex > 0 else { return }
        session.currentIndex -= 1
        store.updateSession(session)
        // Restore previous state
        let answered =
            session.selectedAnswers[session.currentIndex] != nil
            || session.frqGrades[session.currentIndex] != nil
        showExplanation = answered
        frqUserAnswer = session.frqAnswers[session.currentIndex] ?? ""
    }

    private func nextQuestion(_ session: QuizSession) {
        var updated = session
        if updated.currentIndex < updated.questions.count - 1 {
            updated.currentIndex += 1
            store.updateSession(updated)
            withAnimation {
                showExplanation = false
                frqUserAnswer = updated.frqAnswers[updated.currentIndex] ?? ""
            }
        } else {
            updated.finished = true
            store.updateSession(updated)
        }
    }

    private func retryQuiz(_ session: QuizSession) {
        topic = session.topic
        difficulty = session.difficulty
        let mcqs = session.questions.filter { $0.questionType == .mcq }.count
        let tfs = session.questions.filter { $0.questionType == .trueFalse }.count
        let frqs = session.questions.filter { $0.questionType == .frq }.count
        mcqCount = mcqs
        tfCount = tfs
        frqCount = frqs
        activeSessionId = nil
        startQuiz()
    }

    // MARK: - FRQ Grading

    private func gradeFRQ(session: QuizSession, question: QuizQuestion) {
        let userAnswer = frqUserAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userAnswer.isEmpty else { return }

        isGradingFRQ = true

        let gradePrompt = """
            Grade the following free response answer. The question is:

            \(question.question)

            The expected/correct answer is:
            \(question.correctAnswer)

            The student's answer is:
            \(userAnswer)

            Respond in EXACTLY this format (no extra text):
            SCORE: [0-100]
            CORRECT: [true/false]
            FEEDBACK: [detailed explanation of why the answer is right or wrong, and what the correct answer should include]
            """

        let userMsg = Message(content: gradePrompt, isUser: true)
        let history = [userMsg]

        generateTask = Task {
            do {
                var fullContent = ""

                switch quizProvider {
                case "Gemini API":
                    guard !geminiKey.isEmpty else {
                        await MainActor.run { isGradingFRQ = false }
                        return
                    }
                    for try await (chunk, _, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: quizModel,
                        systemPrompt: "", thinkingLevel: "none"
                    ) {
                        fullContent += chunk
                    }
                case "Ollama":
                    let thinking = effectiveThinkingLevel(
                        provider: quizProvider, model: quizModel, level: quizThinkingLevel)
                    for try await (chunk, _) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: quizModel,
                        systemPrompt: "", thinkingLevel: thinking
                    ) {
                        fullContent += chunk
                    }
                case "Apple Foundation":
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }
                case "NVIDIA API":
                    guard !nvidiaKey.isEmpty else {
                        await MainActor.run { isGradingFRQ = false }
                        return
                    }
                    for try await (chunk, _) in nvidiaService.sendMessageStream(
                        history: history, apiKey: nvidiaKey, model: quizModel,
                        systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }
                case "GitHub Copilot":
                    for try await (chunk, _) in copilotService.sendMessageStream(
                        history: history, model: quizModel, systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }
                default:
                    await MainActor.run { isGradingFRQ = false }
                    return
                }

                let grade = parseFRQGrade(fullContent)
                await MainActor.run {
                    var updated = session
                    updated.frqAnswers[session.currentIndex] = userAnswer
                    updated.frqGrades[session.currentIndex] = grade
                    if grade.isCorrect {
                        updated.score += 1
                    }
                    store.updateSession(updated)
                    showExplanation = true
                    isGradingFRQ = false
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { isGradingFRQ = false }
                }
            }
        }
    }

    private func parseFRQGrade(_ text: String) -> FRQGrade {
        var score = 50
        var isCorrect = false
        var feedback = text

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("SCORE:") {
                let val = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                if let s = Int(val.filter { $0.isNumber }) {
                    score = min(100, max(0, s))
                }
            } else if trimmed.uppercased().hasPrefix("CORRECT:") {
                let val = trimmed.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                isCorrect = val == "true"
            } else if trimmed.uppercased().hasPrefix("FEEDBACK:") {
                feedback = String(trimmed.dropFirst(9)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
        }

        // Accumulate feedback lines after FEEDBACK:
        var foundFeedback = false
        var feedbackLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("FEEDBACK:") {
                foundFeedback = true
                let rest = String(trimmed.dropFirst(9)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !rest.isEmpty { feedbackLines.append(rest) }
            } else if foundFeedback {
                if !trimmed.isEmpty { feedbackLines.append(trimmed) }
            }
        }
        if !feedbackLines.isEmpty {
            feedback = feedbackLines.joined(separator: " ")
        }

        return FRQGrade(score: score, feedback: feedback, isCorrect: isCorrect)
    }

    // MARK: - Quiz Generation

    private func startQuiz() {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard totalQuestionCount > 0 else { return }

        isGenerating = true
        generationError = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isInputExpanded = false
        }

        let difficultyDesc: String
        switch difficulty {
        case "easy": difficultyDesc = "easy and straightforward"
        case "hard": difficultyDesc = "challenging and advanced"
        default: difficultyDesc = "moderate difficulty"
        }

        var promptParts: [String] = []
        if mcqCount > 0 {
            promptParts.append(
                "\(mcqCount) multiple choice questions (4 options each, labeled A-D)")
        }
        if tfCount > 0 {
            promptParts.append(
                "\(tfCount) true/false questions (options are only True and False)")
        }
        if frqCount > 0 {
            promptParts.append(
                "\(frqCount) free response questions (provide a model answer)")
        }

        let prompt = """
            Generate a quiz about: \(trimmed)

            The questions should be \(difficultyDesc).

            You MUST generate EXACTLY: \(promptParts.joined(separator: ", ")). \
            Do NOT generate more or fewer questions than specified. \
            The total number of questions must be exactly \(totalQuestionCount).

            Format your response EXACTLY as follows, with no extra text before or after:
            \(mcqCount > 0 ? """

            For each of the \(mcqCount) multiple choice question(s):
            TYPE: MCQ
            Q: [question text]
            A) [option A]
            B) [option B]
            C) [option C]
            D) [option D]
            CORRECT: [A, B, C, or D]
            EXPLANATION: [brief explanation]
            """ : "")
            \(tfCount > 0 ? """

            For each of the \(tfCount) true/false question(s):
            TYPE: TF
            Q: [question text]
            A) True
            B) False
            CORRECT: [A or B]
            EXPLANATION: [brief explanation]
            """ : "")
            \(frqCount > 0 ? """

            For each of the \(frqCount) free response question(s):
            TYPE: FRQ
            Q: [question text]
            ANSWER: [model answer]
            EXPLANATION: [brief explanation of what a good answer should include]
            """ : "")
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
                    for try await (chunk, _, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: quizModel,
                        systemPrompt: "", thinkingLevel: "none"
                    ) {
                        fullContent += chunk
                    }

                case "Ollama":
                    let quizThinking = effectiveThinkingLevel(
                        provider: quizProvider, model: quizModel, level: quizThinkingLevel)
                    var quizSystemPrompt = ""
                    if quizWebSearchEnabled {
                        do {
                            let searchResults = try await webSearchService.search(
                                query: trimmed)
                            let searchContext = webSearchService.buildSearchContext(
                                results: searchResults)
                            if !searchContext.isEmpty { quizSystemPrompt = searchContext }
                        } catch {
                            print("Quiz web search failed: \(error.localizedDescription)")
                        }
                    }
                    for try await (chunk, _) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: quizModel,
                        systemPrompt: quizSystemPrompt, thinkingLevel: quizThinking
                    ) {
                        fullContent += chunk
                    }

                case "Apple Foundation":
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }

                case "NVIDIA API":
                    guard !nvidiaKey.isEmpty else {
                        await MainActor.run {
                            generationError = "No NVIDIA API key set. Please configure in Settings."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _) in nvidiaService.sendMessageStream(
                        history: history, apiKey: nvidiaKey, model: quizModel,
                        systemPrompt: ""
                    ) {
                        fullContent += chunk
                    }

                case "GitHub Copilot":
                    guard copilotService.isAuthenticated else {
                        await MainActor.run {
                            generationError = "GitHub Copilot not authenticated. Please sign in."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _) in copilotService.sendMessageStream(
                        history: history, model: quizModel, systemPrompt: ""
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
                let capMCQ = mcqCount
                let capTF = tfCount
                let capFRQ = frqCount
                await MainActor.run {
                    if parsed.isEmpty {
                        generationError =
                            "Failed to parse quiz questions. Try a different topic or model."
                        isGenerating = false
                    } else {
                        // Enforce exact requested counts per type
                        let mcqQuestions = Array(
                            parsed.filter { $0.questionType == .mcq }.prefix(capMCQ))
                        let tfQuestions = Array(
                            parsed.filter { $0.questionType == .trueFalse }.prefix(capTF))
                        let frqQuestions = Array(
                            parsed.filter { $0.questionType == .frq }.prefix(capFRQ))
                        let enforced = mcqQuestions + tfQuestions + frqQuestions

                        if enforced.isEmpty {
                            generationError =
                                "Failed to parse quiz questions. Try a different topic or model."
                            isGenerating = false
                        } else {
                            let session = QuizSession(
                                id: UUID(), topic: trimmed, difficulty: difficulty,
                                questions: enforced, currentIndex: 0, score: 0,
                                finished: false, selectedAnswers: [:], frqAnswers: [:],
                                frqGrades: [:], timestamp: Date()
                            )
                            store.addSession(session)
                            activeSessionId = session.id
                            showExplanation = false
                            frqUserAnswer = ""
                            isGenerating = false
                            topic = ""
                        }
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

        var currentType: QuizQuestionType = .mcq
        var currentQuestion: String?
        var options: [String] = []
        var correctIndex: Int?
        var correctAnswer: String?
        var explanation: String?

        func saveCurrentQuestion() {
            if let q = currentQuestion {
                switch currentType {
                case .mcq:
                    if options.count == 4, let ci = correctIndex {
                        questions.append(
                            QuizQuestion(
                                question: q, questionType: .mcq,
                                options: options, correctIndex: ci,
                                explanation: explanation ?? ""
                            ))
                    }
                case .trueFalse:
                    if options.count == 2, let ci = correctIndex {
                        questions.append(
                            QuizQuestion(
                                question: q, questionType: .trueFalse,
                                options: options, correctIndex: ci,
                                explanation: explanation ?? ""
                            ))
                    }
                case .frq:
                    questions.append(
                        QuizQuestion(
                            question: q, questionType: .frq,
                            options: [], correctIndex: -1,
                            correctAnswer: correctAnswer ?? "",
                            explanation: explanation ?? ""
                        ))
                }
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.uppercased().hasPrefix("TYPE:") {
                // Save previous question first
                saveCurrentQuestion()

                let typeStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                switch typeStr {
                case "MCQ", "MULTIPLE CHOICE":
                    currentType = .mcq
                case "TF", "TRUE/FALSE", "T/F", "TRUEFALSE":
                    currentType = .trueFalse
                case "FRQ", "FREE RESPONSE":
                    currentType = .frq
                default:
                    currentType = .mcq
                }
                currentQuestion = nil
                options = []
                correctIndex = nil
                correctAnswer = nil
                explanation = nil
            } else if trimmed.hasPrefix("Q:") || trimmed.hasPrefix("Q ") {
                // Save previous question if no TYPE was given
                if currentQuestion != nil {
                    saveCurrentQuestion()
                    options = []
                    correctIndex = nil
                    correctAnswer = nil
                    explanation = nil
                    // Default to MCQ if no type marker
                }
                currentQuestion = String(trimmed.dropFirst(2)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
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
            } else if trimmed.uppercased().hasPrefix("ANSWER:") {
                correctAnswer = String(trimmed.dropFirst(7)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            } else if trimmed.uppercased().hasPrefix("EXPLANATION:") {
                explanation = String(trimmed.dropFirst(12)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            } else if currentQuestion != nil && options.isEmpty && correctAnswer == nil {
                currentQuestion = (currentQuestion ?? "") + " " + trimmed
            } else if let existing = explanation {
                explanation = existing + " " + trimmed
            } else if let existing = correctAnswer, currentType == .frq {
                correctAnswer = existing + " " + trimmed
            }
        }

        // Don't forget the last question
        saveCurrentQuestion()

        return questions
    }
}
