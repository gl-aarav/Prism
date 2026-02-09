# Prism - Your Ultimate Native AI Companion for macOS

![Prism App Icon](AppIcon.png)

**Prism** is a powerful, native macOS application that brings the power of modern AI directly to your desktop. Built with SwiftUI and designed with a stunning "Liquid Glass" aesthetic, Prism integrates seamlessly into your Mac workflow, offering a unified interface for Google Gemini, local Ollama models, and Apple Shortcuts.

---

## 🚀 Key Features

### 🧠 Multi-Model Intelligence
*   **Google Gemini**: Harness the power of Google's latest cloud models (Gemini 1.5 Pro/Flash) for complex reasoning, coding, and multimodal analysis.
*   **Ollama Integration**: Run privacy-focused local models (like Llama 3, DeepSeek, Mistral) directly on your machine. Zero data leaves your device.
*   **Apple Foundation Models**: Access Apple's on-device foundation models for private, fast AI responses.
*   **Apple Shortcuts**: Trigger system automations, control your smart home, or chain complex workflows directly from the chat.

### 🖥️ Versatile Interfaces
Prism adapts to how you work with three distinct modes, all **synchronized** in real-time:
1.  **Main Window**: A full-featured chat interface for deep work and long conversations.
2.  **Menu Bar App**: Always one click away for quick questions and status checks.
3.  **Quick AI Panel** (`Ctrl + Space`): A Spotlight-like floating search bar. Summon it instantly from anywhere to ask a question, then dismiss it just as fast.

### 🔀 Model Comparison Mode
*   **Side-by-Side Comparison**: Send the same prompt to multiple AI models simultaneously and compare their responses.
*   **Add Unlimited Slots**: Compare as many models as you want from any provider.
*   **AI Synthesis**: Use the "Synthesize" feature to combine all responses into a single, unified answer using AI.
*   **Performance Tracking**: View elapsed time for each model response.

### ✍️ Rich Chat Experience
*   **Advanced Math Rendering**: 
    *   **Block Math**: Beautiful LaTeX rendering for complex equations using `$$...$$`.
    *   **Inline Math**: Seamless text-based math support (`$...$`) with automatic conversion of Greek letters (`\alpha` → α), fractions (`\frac` → `/`), and operators.
*   **Code Highlighting**: Syntax highlighting for all major programming languages with one-click copy.
*   **Thinking Process**: View the internal "thought process" of reasoning models (like DeepSeek R1) in a collapsible section.
*   **Image Analysis**: Drag and drop images to analyze them with multimodal models.
*   **PDF Support**: Attach PDFs and have AI analyze their contents.
*   **Global Sync**: Start a chat in the Quick Panel, continue it in the Menu Bar, and finish it in the Main Window.

### 🎨 Image Generation
*   **AI Image Creation**: Generate images using AI through Apple Shortcuts integration.
*   **Multiple Styles**: Choose from various styles including Animation, Illustration, Sketch (Apple Intelligence) and Watercolor, Vector, Anime, Print (ChatGPT).
*   **Persistent Gallery**: All generated images are saved and accessible in a gallery view.
*   **Full-Size Preview**: Click any image to view it in a full-size overlay with copy and save options.

### ❓ Quiz Me Mode
*   **AI-Generated Quizzes**: Enter any topic and have AI generate a customized quiz.
*   **Configurable Difficulty**: Choose from Easy, Medium, or Hard difficulty levels.
*   **Question Count**: Select how many questions you want in your quiz.
*   **Instant Feedback**: Get immediate feedback on answers with detailed explanations.
*   **Progress Tracking**: Track your score and progress through the quiz.

### ⚡ Slash Commands
*   **Built-in Commands**: Quick access to common actions:
    *   `/summarize` – Summarize conversations
    *   `/explain` – Get simple explanations
    *   `/translate` – Translate text to English
    *   `/fix` – Fix grammar and spelling
    *   `/code` – Write code
    *   `/rewrite` – Improve text clarity
    *   `/bullets` – Convert to bullet points
    *   `/eli5` – Explain like I'm 5
    *   `/pros-cons` – List pros and cons
    *   `/clear` – Clear chat history
    *   `/new` – Start new chat session
    *   `/quit` – Quit Prism
*   **Custom Commands**: Create your own slash commands with custom expansions.
*   **Custom Icons**: Choose from 40+ icons for your custom commands.
*   **Autocomplete**: Type `/` to see available commands with real-time filtering.

### 🔍 Web Search
*   **Integrated Search**: Enable web search to let AI access real-time information.
*   **Toggle On/Off**: Easily enable or disable web search per conversation.

### 🎯 AI Thinking Levels
*   **Configurable Thinking**: Adjust AI thinking depth with Low, Medium, and High levels.
*   **Reasoning Models Support**: Full support for thinking/reasoning models like DeepSeek R1.

### ⚡️ Performance & Design
*   **Native macOS**: Built with SwiftUI for blazing fast performance and low memory usage.
*   **Streaming**: Character-by-character streaming responses for immediate feedback.
*   **Liquid Glass Aesthetic**: Sleek, modern UI with glassmorphism effects.
*   **Multiple Themes**: Choose from various color themes to personalize your experience.
*   **Adjustable Opacity**: Control the panel opacity to match your preference.
*   **Customizable**: Choose your preferred model, system prompt, and background aesthetics.

---

## 📥 Installation

1.  Go to the **[Releases](../../releases)** page.
2.  Download the latest `Prism_Installer.dmg`.
3.  Open the disk image and drag **Prism** to your **Applications** folder.
4.  Launch Prism!

> **Note**: On first launch, you may need to right-click the app and select "Open" if Gatekeeper prompts you.

---

## ⚙️ Configuration

Click the **Gear Icon** in the main window to access Settings:

### 1. Google Gemini
*   Get your API key from [Google AI Studio](https://aistudio.google.com/).
*   Paste it into the **API Key** field.
*   Set your model (default: `gemini-1.5-flash`).

### 2. Ollama (Local Models)
*   Install [Ollama](https://ollama.com/) and run `ollama serve`.
*   Pull a model (e.g., `ollama run llama3`).
*   Enter the model name and URL in Prism settings.
*   Optionally add an API key if using a remote Ollama instance.

### 3. System Prompt
*   Customize the system prompt to set the AI's personality and behavior.

### 4. Quick AI Hotkey
*   The default hotkey is **Control + Space**.
*   Toggle the panel to ask quick questions without leaving your current app.

---

## 📝 Usage Tips

### Math & LaTeX
Prism supports extensive LaTeX formatting:
*   **Fractions**: `\frac{a}{b}` converts to `(a)/(b)` inline.
*   **Greek**: `\alpha`, `\beta`, `\Delta` convert to α, β, Δ.
*   **Roots**: `\sqrt{x}` converts to `√(x)`.
*   **Boxed**: `\boxed{answer}` highlights the result.

### Shortcuts
You can map specific phrases to Apple Shortcuts. For example, map "Generate Image" to a shortcut that uses DALL-E or Stable Diffusion, and trigger it directly from Prism.

### Slash Commands
Type `/` followed by a command name for quick access to common actions. Press Tab or Enter to autocomplete.

### Model Comparison
Switch to Model Comparison view to test the same prompt across multiple AI providers. Great for evaluating which model works best for specific tasks.

### Quiz Me
Use Quiz Me mode to study any topic. AI generates multiple-choice questions based on your specified topic and difficulty level.

---

## 🔒 Privacy

*   **Local Storage**: All chat history is stored locally on your Mac in JSON format.
*   **Ollama**: When using Ollama, your data never leaves your computer.
*   **Apple Foundation**: Apple Foundation models run entirely on-device.
*   **Direct Connections**: Prism connects directly to the APIs you configure (Google, Ollama). No middleman servers.

---

## 📄 License

Prism is open-source software!

---

**Developed by Aarav Goyal**
