# Prism - Your Ultimate Native AI Companion for macOS

![Prism App Icon](AppIcon.png)

**Prism** is a powerful, native macOS application that brings modern AI directly to your desktop. Built with SwiftUI and designed with a stunning "Liquid Glass" and macOS Tahoe aesthetic, Prism integrates seamlessly into your Mac workflow. It offers a unified interface for Google Gemini, local Ollama models, Apple Foundation Models, and comprehensive system-wide AI writing assistance.

---

## 🚀 Key Features

### 🧠 Multi-Model Intelligence
*   **Google Gemini**: Harness the power of Google's latest cloud models (Gemini 1.5 Pro/Flash) for complex reasoning, coding, and multimodal analysis.
*   **GitHub Copilot Integration**: Seamlessly connect your GitHub Copilot subscription to access a wide range of top-tier models from OpenAI, Anthropic, and more directly within Prism.
*   **NVIDIA NIM**: Access ultra-fast, high-performance models (Llama 3, Mistral) through NVIDIA's optimized infrastructure.
*   **Ollama Integration**: Run privacy-focused local models (like Llama 3, DeepSeek, Mistral) directly on your machine. Zero data leaves your device.
*   **Apple Foundation Models**: Access Apple's on-device foundation models (Apple Intelligence) for private, lightning-fast AI responses.
*   **Apple Shortcuts**: Integrated system-wide triggers to invoke AI actions via the Shortcuts app.

### ✍️ System-Wide AI Writing Layer
Transform any text field on your Mac into an AI-powered workspace using macOS Accessibility APIs:
*   **Inline AI Autocomplete**: Get intelligent, contextual text predictions and continuations directly at your cursor as you type in any application.
*   **Global Command Bar (IntelliBar)**: Instantly summon a floating command bar to perform quick actions on selected text anywhere on your system.
*   **Personalized Writing Style (Memory)**: Prism learns your unique writing style over time, adapting its suggestions to match your tone and vocabulary for truly personalized assistance.
*   **Refinement Panel**: A dedicated interface for powerful text manipulations:
    *   Rewrite and improve clarity
    *   Summarize long content
    *   Fix grammar and spelling
    *   Translate between languages
    *   Match specific writing styles
    *   Generate new content or edit code

### 🌐 Prism Browser Automation (Agentic Control)
Navigate and control the web using AI agents. Prism includes a powerful browser automation engine (Playwright/Puppeteer) that allows you to:
*   **Task-Based Browsing**: Give the AI a goal (e.g., "Find the cheapest flights to NYC") and watch it navigate, search, and extract information for you.
*   **Real-time Interaction**: See exactly what the agent sees with live screenshots and a synchronized DOM tree view.
*   **Multi-Tab Support**: The AI can manage multiple tabs and complex workflows across different websites.

**How to run it:**
1. Ensure the main **Prism app** is running (it powers the local AI API).
2. Open your terminal and navigate to the `BrowserAutomation` directory within the project folder.
3. Run `npm install` to install the required dependencies (Playwright, Puppeteer, etc.).
4. Run `npm start` to launch the automation server.
5. Open your web browser and navigate to `http://localhost:9090` to access the Browser Automation UI.

### 🖥️ Versatile Interfaces
Prism adapts to how you work with multiple entry points, all **synchronized** in real-time:
1.  **Main Window**: A full-featured chat interface for deep work and long conversations.
2.  **Menu Bar App**: Always one click away for quick questions and status checks.
3.  **Quick AI Panel** (`Ctrl + Space`): A Spotlight-like floating search bar. Summon it instantly from anywhere to ask a question, then dismiss it just as fast.
4.  **Interactive Web Overlay**: A dedicated, floating web view panel for quick internet access and searches alongside your AI.
5.  **Browser Extensions (Chrome & Safari)**: Bring Prism's intelligence directly into your browser. Enhance web pages, extract content, and enable seamless agentic browser control.

### 🔀 Model Comparison Mode
*   **Side-by-Side Comparison**: Send the same prompt to multiple AI models simultaneously and compare their responses.
*   **Add Unlimited Slots**: Compare as many models as you want from any provider.
*   **AI Synthesis**: Use the "Synthesize" feature to combine all responses into a single, unified best answer using AI.
*   **Performance Tracking**: View elapsed time and generation speed for each model response.

### 🎭 Rich Chat Experience
*   **Multimodal Input**: Drag and drop or paste **multiple images** simultaneously to analyze them. Attach PDFs and have AI process their contents.
*   **Professional PDF Export**: Convert any chat or markdown text into a professionally formatted PDF document with customizable page sizes (Letter, A4, Legal) and high-quality math rendering.
*   **Advanced Math Rendering**: Beautiful LaTeX rendering for complex block equations (`$$...$$`) and seamless inline math support (`$...$`) with automatic symbol conversion.
*   **Code Highlighting**: Syntax highlighting for all major programming languages with one-click copy.
*   **Thinking Process**: View the internal "thought process" of reasoning models (like DeepSeek R1) in a beautifully animated, collapsible section.
*   **Global Sync**: Start a chat in the Quick Panel, continue it in the Menu Bar, and finish it in the Main Window.

### 🎨 Image & Video Generation
*   **AI Image Creation**: Generate stunning visuals using AI. Includes support for custom aspect ratios and ultra-high resolution **4K generation**.
*   **Local Image Generation**: Run image generation securely and privately on your machine using Ollama integration.
*   **Video Generation (Veo)**: Create dynamic AI videos directly within Prism with a premium integrated video player UI.
*   **Multiple Styles**: Choose from various styles including Animation, Illustration, Sketch (Apple Intelligence) and Watercolor, Vector, Anime, Print (ChatGPT).
*   **Persistent Gallery**: All generated images and videos are saved and accessible in a gallery view.

### ❓ Quiz Me Mode
*   **AI-Generated Quizzes**: Enter any topic and have AI generate a customized multiple-choice quiz.
*   **Configurable Difficulty & Length**: Choose from Easy, Medium, or Hard difficulty levels, and set your desired question count.
*   **Instant Feedback**: Get immediate scoring and detailed explanations for your answers.

### ⚡ Slash Commands & Prompt Templates
*   **Built-in Commands**: Quick access to common actions like `/summarize`, `/explain`, `/translate`, `/fix`, `/code`, and `/rewrite`.
*   **Custom Prompt Templates**: Create your own reusable prompt templates and slash commands with custom icons and expansions. Type `/` anywhere to see available commands with real-time filtering.

### 🔍 Search & Reasoning
*   **Integrated Web Search**: Enable web search to let AI access real-time information from the internet.
*   **Configurable Thinking Levels**: Adjust AI thinking depth (Low, Medium, High) for reasoning models.

### ⚡️ Performance & Design
*   **Native macOS**: Built with SwiftUI for blazing fast performance and low memory footprint.
*   **Streaming**: Character-by-character streaming responses for immediate feedback.
*   **Liquid Glass Aesthetic**: Sleek, modern UI with glassmorphism effects and macOS Tahoe design cues.
*   **Highly Customizable**: Personalize your experience with custom themes, adjustable opacity, default models, and system prompts.
*   **Background Mode**: Prism runs silently in the background without cluttering your Dock, available instantly via hotkey.
*   **Automatic Updates**: Built-in over-the-air update system keeps your app on the latest version seamlessly.

---

## 📥 Installation

### Option 1: Download Release
1.  Go to the **[Releases](../../releases)** page.
2.  Download the latest `Prism_Installer.dmg`.
3.  Open the disk image and drag **Prism** to your **Applications** folder.
4.  Launch Prism!

> **Note**: On first launch, you may need to right-click the app and select "Open" if Gatekeeper prompts you. You will also need to grant Accessibility permissions for the system-wide AI Writing Layer features to function.

### Option 2: Clone & Build from Source
If you prefer to build the project yourself or contribute to development, you can clone the repository:
* **HTTPS**: `git clone https://github.com/gl-aarav/PrismApp.git`
* **SSH**: `git clone git@github.com:gl-aarav/PrismApp.git`
* **GitHub CLI**: `gh repo clone gl-aarav/PrismApp`

Once cloned, open `Package.swift` or the project directory in Xcode, wait for Swift Package dependencies to resolve, and build (`Cmd + R`).

---

## ⚙️ Configuration

Click the **Gear Icon** in the main window to access Settings:

### 1. Model Providers
*   **Google Gemini**: Get your API key from [Google AI Studio](https://aistudio.google.com/), or authenticate securely using the integrated Gemini CLI.
*   **GitHub Copilot**: Sign in with your GitHub account to enable Copilot-powered models.
*   **NVIDIA NIM**: Enter your NVIDIA API key for high-performance Llama models.
*   **Ollama**: Install [Ollama](https://ollama.com/) and run `ollama serve`. Use `ollama run llama3` to pull models.
*   **Apple Intelligence**: Select Apple Foundation Models for on-device processing (requires compatible Mac).

### 2. System Prompt & Hotkeys
*   Customize the system prompt to set the AI's personality and behavior.
*   Change the default **Quick AI Hotkey** (default: `Control + Space`).

---

## 📝 Usage Tips

### System-Wide Writing Assistance
Highlight any text in any app and invoke the Quick AI Hotkey to bring up the Refinement Panel or IntelliBar to instantly rewrite, summarize, or fix your text. Enable AI Autocomplete in settings to get inline suggestions as you type.

### Math & LaTeX
Prism supports extensive LaTeX formatting:
*   **Fractions**: `\frac{a}{b}` converts to `(a)/(b)` inline.
*   **Greek**: `\alpha`, `\beta`, `\Delta` convert to α, β, Δ.
*   **Roots**: `\sqrt{x}` converts to `√(x)`.
*   **Boxed**: `\boxed{answer}` highlights the result.


---

## 🔒 Privacy

*   **Local Storage**: All chat history is stored locally on your Mac in JSON format.
*   **Ollama & Apple Intelligence**: When using local models, your data never leaves your computer.
*   **Direct Connections**: Prism connects directly to the APIs you configure. No middleman servers intercept your prompts.

---

## 📄 License

Prism is open-source software!

---

## ℹ️ Disclaimer

**Prism is an independent, personal project. It is not affiliated with, endorsed by, or belonging to any company or organization.**

---

**Developed by Aarav Goyal**
