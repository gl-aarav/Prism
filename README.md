# Prism - Your Ultimate Native AI Companion for macOS

![Prism App Icon](AppIcon.png)

**Prism** is a powerful, native macOS application that brings modern AI directly to your desktop. Built with SwiftUI and designed with a stunning "Liquid Glass" and macOS Tahoe aesthetic, Prism integrates seamlessly into your Mac workflow. It offers a unified interface for Google Gemini, local Ollama models, Apple Foundation Models, and comprehensive system-wide AI writing assistance.

---

## 🚀 Key Features

### 🧠 Multi-Model Intelligence
*   **Google Gemini**: Harness the power of Google's latest cloud models (Gemini 1.5 Pro/Flash) for complex reasoning, coding, and multimodal analysis.
*   **Ollama Integration**: Run privacy-focused local models (like Llama 3, DeepSeek, Mistral) directly on your machine. Zero data leaves your device.
*   **Apple Foundation Models**: Access Apple's on-device foundation models (Apple Intelligence) for private, lightning-fast AI responses.
*   **Apple Shortcuts**: Trigger system automations, control your smart home, or chain complex workflows directly from the chat.

### ✍️ System-Wide AI Writing Layer
Transform any text field on your Mac into an AI-powered workspace using macOS Accessibility APIs:
*   **Inline AI Autocomplete**: Get intelligent, contextual text predictions and continuations directly at your cursor as you type in any application.
*   **Global Command Bar (IntelliBar)**: Instantly summon a floating command bar to perform quick actions on selected text anywhere on your system.
*   **Refinement Panel**: A dedicated interface for powerful text manipulations:
    *   Rewrite and improve clarity
    *   Summarize long content
    *   Fix grammar and spelling
    *   Translate between languages
    *   Match specific writing styles
    *   Generate new content or edit code

### 🖥️ Versatile Interfaces
Prism adapts to how you work with three distinct modes, all **synchronized** in real-time:
1.  **Main Window**: A full-featured chat interface for deep work and long conversations.
2.  **Menu Bar App**: Always one click away for quick questions and status checks.
3.  **Quick AI Panel** (`Ctrl + Space`): A Spotlight-like floating search bar. Summon it instantly from anywhere to ask a question, then dismiss it just as fast.

### 🔀 Model Comparison Mode
*   **Side-by-Side Comparison**: Send the same prompt to multiple AI models simultaneously and compare their responses.
*   **Add Unlimited Slots**: Compare as many models as you want from any provider.
*   **AI Synthesis**: Use the "Synthesize" feature to combine all responses into a single, unified best answer using AI.
*   **Performance Tracking**: View elapsed time and generation speed for each model response.

### 🎭 Rich Chat Experience
*   **Multimodal Input**: Drag and drop or paste **multiple images** simultaneously to analyze them. Attach PDFs and have AI process their contents.
*   **Advanced Math Rendering**: Beautiful LaTeX rendering for complex block equations (`$$...$$`) and seamless inline math support (`$...$`) with automatic symbol conversion.
*   **Code Highlighting**: Syntax highlighting for all major programming languages with one-click copy.
*   **Thinking Process**: View the internal "thought process" of reasoning models (like DeepSeek R1) in a beautifully animated, collapsible section.
*   **Global Sync**: Start a chat in the Quick Panel, continue it in the Menu Bar, and finish it in the Main Window.

### 🎨 Image & Video Generation
*   **AI Image Creation**: Generate stunning visuals using AI. Includes support for custom aspect ratios and ultra-high resolution **4K generation**.
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

---

## 📥 Installation

1.  Go to the **[Releases](../../releases)** page.
2.  Download the latest `Prism_Installer.dmg`.
3.  Open the disk image and drag **Prism** to your **Applications** folder.
4.  Launch Prism!

> **Note**: On first launch, you may need to right-click the app and select "Open" if Gatekeeper prompts you. You will also need to grant Accessibility permissions for the system-wide AI Writing Layer features to function.

---

## ⚙️ Configuration

Click the **Gear Icon** in the main window to access Settings:

### 1. Google Gemini
*   Get your API key from [Google AI Studio](https://aistudio.google.com/).
*   Paste it into the **API Key** field to enable Gemini 1.5, image generation, and Veo video generation.
*   Set your default model.

### 2. Ollama (Local Models)
*   Install [Ollama](https://ollama.com/) and run `ollama serve`.
*   Pull a model (e.g., `ollama run llama3`).
*   Enter the model name and URL in Prism settings.

### 3. Apple Intelligence
*   Select Apple Foundation Models in your settings for on-device processing. (Requires compatible Mac).

### 4. System Prompt & Hotkeys
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
*   **Direct Connections**: Prism connects directly to the APIs you configure (Google, Ollama). No middleman servers intercept your prompts.

---

## 📄 License

Prism is open-source software!

---

**Developed by Aarav Goyal**
