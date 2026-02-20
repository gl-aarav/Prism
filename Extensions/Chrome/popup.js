document.addEventListener('DOMContentLoaded', () => {
    const modelSelect = document.getElementById('modelSelect');
    const chatContainer = document.getElementById('chatContainer');
    const promptInput = document.getElementById('promptInput');
    const sendBtn = document.getElementById('sendBtn');
    const Math = document.getElementById('regenerateBtn'); // Alias for syntax checks just in case but we use regenerateBtn
    const regenerateBtn = document.getElementById('regenerateBtn');
    const newChatBtn = document.getElementById('newChatBtn');
    const closeBtn = document.getElementById('closeBtn');

    let isGenerating = false;
    let lastUserMessage = "";

    // Auto-resize textarea
    promptInput.addEventListener('input', () => {
        promptInput.style.height = 'auto';
        promptInput.style.height = (promptInput.scrollHeight < 120 ? promptInput.scrollHeight : 120) + 'px';
        sendBtn.disabled = promptInput.value.trim() === '' || isGenerating;
    });

    // Handle New Chat
    newChatBtn.addEventListener('click', () => {
        if (isGenerating) return;
        chatContainer.innerHTML = '<div class="system-message">Select a model and ask a question about this page.</div>';
        promptInput.value = '';
        promptInput.style.height = 'auto';
        lastUserMessage = "";
        regenerateBtn.style.display = 'none';
        promptInput.focus();
    });

    // Handle Close
    if (closeBtn) {
        closeBtn.addEventListener('click', () => {
            window.close();
        });
    }

    // Fetch models and group them
    async function fetchModels() {
        try {
            const res = await fetch('http://localhost:8080/api/models');
            if (!res.ok) throw new Error('Server not ready');
            const models = await res.json();

            modelSelect.innerHTML = '';

            // Group models by prefix
            const groups = {
                'Apple': [],
                'Gemini': [],
                'Ollama': [],
                'Other': []
            };

            models.forEach(m => {
                let name = m.name;
                let group = 'Other';

                if (name.startsWith('Apple')) {
                    group = 'Apple';
                } else if (name.startsWith('Gemini:')) {
                    group = 'Gemini';
                    name = name.replace('Gemini: ', ''); // Remove prefix for cleaner UI
                } else if (name.startsWith('Ollama:')) {
                    group = 'Ollama';
                    name = name.replace('Ollama: ', '');
                }

                groups[group].push({ id: m.id, name: name });
            });

            // Add optgroups to select
            ['Apple', 'Gemini', 'Ollama', 'Other'].forEach(groupName => {
                if (groups[groupName].length > 0) {
                    const optgroup = document.createElement('optgroup');
                    optgroup.label = groupName;

                    groups[groupName].forEach(m => {
                        const opt = document.createElement('option');
                        opt.value = m.id;
                        opt.textContent = m.name;
                        optgroup.appendChild(opt);
                    });

                    modelSelect.appendChild(optgroup);
                }
            });

            // Try to load last selected model
            chrome.storage.local.get(['lastModelId'], (result) => {
                if (result.lastModelId && Array.from(modelSelect.options).some(o => o.value === result.lastModelId)) {
                    modelSelect.value = result.lastModelId;
                }
            });

        } catch (e) {
            modelSelect.innerHTML = '<option value="">Cannot connect to Prism</option>';
            console.error(e);
        }
    }

    modelSelect.addEventListener('change', () => {
        chrome.storage.local.set({ lastModelId: modelSelect.value });
    });

    fetchModels();

    // Handle sending message
    sendBtn.addEventListener('click', () => { sendMessage(promptInput.value.trim()); });
    regenerateBtn.addEventListener('click', () => {
        if (lastUserMessage) sendMessage(lastUserMessage, true);
    });

    promptInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            if (!sendBtn.disabled) {
                sendMessage(promptInput.value.trim());
            }
        }
    });

    async function sendMessage(text, isRegenerate = false) {
        const modelId = modelSelect.value;
        if (!text || !modelId) return;

        // UI Updates
        promptInput.value = '';
        promptInput.style.height = 'auto';
        promptInput.disabled = true;
        sendBtn.disabled = true;
        regenerateBtn.style.display = 'none';
        isGenerating = true;
        lastUserMessage = text;

        // Remove system message if present
        const sm = document.querySelector('.system-message');
        if (sm) sm.remove();

        // If Regenerate, we remove the last assistant message
        if (isRegenerate) {
            const messages = document.querySelectorAll('.message');
            if (messages.length > 0) {
                const lastMsg = messages[messages.length - 1];
                if (lastMsg.classList.contains('assistant')) {
                    lastMsg.remove();
                }
            }
        } else {
            appendMessage('user', text);
        }

        const assistantMsgDiv = appendMessage('assistant', '<span style="opacity:0.5">Thinking...</span>');

        try {
            // Get page context
            let pageContext = "";
            let [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

            if (tab && tab.url && !tab.url.startsWith('chrome://')) {
                try {
                    const response = await new Promise((resolve, reject) => {
                        chrome.tabs.sendMessage(tab.id, { action: "getPageContext" }, (res) => {
                            if (chrome.runtime.lastError) {
                                // Content script might not be injected, let's inject it programmatically just in case
                                chrome.scripting.executeScript({
                                    target: { tabId: tab.id },
                                    files: ['content.js']
                                }, () => {
                                    chrome.tabs.sendMessage(tab.id, { action: "getPageContext" }, resolve);
                                });
                            } else {
                                resolve(res);
                            }
                        });
                    });
                    if (response && response.content) {
                        pageContext = response.content;
                    }
                } catch (err) {
                    console.warn("Could not get page text", err);
                }
            }

            // Construct prompt with context
            let fullPrompt = text;
            if (pageContext.length > 0) {
                const truncatedContext = pageContext.length > 50000 ? pageContext.substring(0, 50000) + "..." : pageContext;
                fullPrompt = `[Webpage Text for Context]:\n${truncatedContext}\n\n[User Request]:\n${text}`;
            }

            // Stream response
            const res = await fetch('http://localhost:8080/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    model: modelId,
                    messages: [{ role: 'user', content: fullPrompt }]
                })
            });

            if (!res.ok) throw new Error('Failed to fetch response');

            const reader = res.body.getReader();
            const decoder = new TextDecoder("utf-8");

            assistantMsgDiv.innerHTML = "";
            let generatedText = "";

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                const chunk = decoder.decode(value, { stream: true });
                const lines = chunk.split('\n');

                for (const line of lines) {
                    if (line.startsWith('data: ')) {
                        const dataStr = line.substring(6);
                        if (dataStr === '[DONE]') break;
                        try {
                            const data = JSON.parse(dataStr);
                            if (data.error) {
                                generatedText = data.error;
                            } else if (data.text) {
                                generatedText += data.text;
                            }
                            // We need to render markdown and latex
                            // 1. Extract Math before marked to prevent mangling of underscores etc.
                            let mathTokens = [];
                            let processedText = generatedText.replace(/\\\[([\s\S]*?)\\\]|\$\$([\s\S]*?)\$\$|\\\(([\s\S]*?)\\\)|\$((?:[^$\\]|\\.)+)\$/g, (match) => {
                                const id = `@@MATH${mathTokens.length}@@`;
                                mathTokens.push(match);
                                return id;
                            });

                            // 2. Parse Markdown
                            let rawHtml = marked.parse(processedText, { breaks: true, gfm: true });

                            // 3. Restore Math
                            mathTokens.forEach((match, i) => {
                                rawHtml = rawHtml.replace(`@@MATH${i}@@`, match);
                            });

                            // 4. Sanitize
                            const safeHtml = DOMPurify.sanitize(rawHtml);
                            assistantMsgDiv.innerHTML = safeHtml;

                            // 5. Render Math
                            if (window.renderMathInElement) {
                                renderMathInElement(assistantMsgDiv, {
                                    delimiters: [
                                        { left: "$$", right: "$$", display: true },
                                        { left: "\\[", right: "\\]", display: true },
                                        { left: "$", right: "$", display: false },
                                        { left: "\\(", right: "\\)", display: false }
                                    ],
                                    throwOnError: false
                                });
                            }
                            scrollToBottom();
                        } catch (e) {
                            // Incomplete JSON chunk, typically handled implicitly by better SSE parsers but we suffice with this
                        }
                    }
                }
            }
        } catch (e) {
            assistantMsgDiv.innerHTML = "Error: " + e.message;
            assistantMsgDiv.classList.add('error');
        } finally {
            promptInput.disabled = false;
            isGenerating = false;
            sendBtn.disabled = promptInput.value.trim() === '';
            regenerateBtn.style.display = 'flex';
            setTimeout(() => promptInput.focus(), 100);
        }
    }

    function appendMessage(role, htmlContent) {
        const div = document.createElement('div');
        div.className = `message ${role}`;
        div.innerHTML = htmlContent;
        chatContainer.appendChild(div);
        scrollToBottom();
        return div;
    }

    function scrollToBottom() {
        chatContainer.scrollTo({
            top: chatContainer.scrollHeight,
            behavior: 'smooth'
        });
    }

    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
});
