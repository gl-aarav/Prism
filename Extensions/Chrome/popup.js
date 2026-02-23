document.addEventListener('DOMContentLoaded', () => {
    // Elements
    const modelSelect = document.getElementById('modelSelect');
    const modelName = document.getElementById('modelName');
    const modelIcon = document.getElementById('modelIcon');
    const chatContainer = document.getElementById('chatContainer');
    const emptyState = document.getElementById('emptyState');
    const promptInput = document.getElementById('promptInput');
    const sendBtn = document.getElementById('sendBtn');
    const sendIcon = document.getElementById('sendIcon');
    const stopIcon = document.getElementById('stopIcon');
    const newChatBtn = document.getElementById('newChatBtn');
    const thinkingBtn = document.getElementById('thinkingBtn');
    const contextCloseBtn = document.getElementById('contextCloseBtn');
    const contextToggleText = document.getElementById('contextToggleText');
    const webSearchBtn = document.getElementById('webSearchBtn');
    const agentBrowserBtn = document.getElementById('agentBrowserBtn');

    // State
    let chatHistory = [];
    let isGenerating = false;
    let abortController = null;
    let includeContext = true;
    let includeWebSearch = false;
    let agentBrowserEnabled = false;
    let thinkingLevel = 'medium';
    let thinkingDropdownOpen = false;
    let hasInjectedContextThisSession = false;

    // Auto-resize textarea
    promptInput.addEventListener('input', () => {
        promptInput.style.height = 'auto';
        promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
        updateSendBtn();
    });

    function updateSendBtn() {
        sendBtn.disabled = isGenerating ? false : promptInput.value.trim() === '';
    }

    // ── MODEL SELECTOR ──────────────────────────────────────
    async function fetchModels() {
        try {
            const res = await fetch('http://localhost:8080/api/models');
            if (!res.ok) throw new Error('Server not ready');
            const models = await res.json();
            modelSelect.innerHTML = '';

            const groups = { 'Apple': [], 'Gemini': [], 'Ollama': [], 'Copilot': [], 'Other': [] };
            models.forEach(m => {
                let name = m.name;
                let group = 'Other';
                if (name.startsWith('Apple')) { group = 'Apple'; }
                else if (m.id.startsWith('gemini:')) { group = 'Gemini'; name = name.replace(/^Gemini:\s*/, ''); }
                else if (m.id.startsWith('ollama:')) { group = 'Ollama'; name = name.replace(/^Ollama:\s*/, ''); }
                else if (m.id.startsWith('copilot:')) { group = 'Copilot'; name = name.replace(/^Copilot[^:]*:\s*/, ''); }
                else if (name.startsWith('Copilot:')) { group = 'Copilot'; name = name.replace('Copilot: ', ''); }
                groups[group].push({ id: m.id, name });
            });

            ['Apple', 'Copilot', 'Gemini', 'Ollama', 'Other'].forEach(groupName => {
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

            chrome.storage.local.get(['lastModelId'], result => {
                if (result.lastModelId && Array.from(modelSelect.options).some(o => o.value === result.lastModelId)) {
                    modelSelect.value = result.lastModelId;
                }
                updateModelDisplay();
                updateWebSearchBtn();
            });
        } catch (e) {
            modelSelect.innerHTML = '<option value="">Cannot connect to Prism</option>';
            modelName.textContent = 'Cannot connect';
        }
    }

    function getProviderIcon(modelId) {
        if (modelId.startsWith('apple:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83"/><path d="M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11"/></svg>';
        if (modelId.startsWith('gemini:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><path d="M12 2L13.09 8.26L18 6L14.74 10.91L21 12L14.74 13.09L18 18L13.09 15.74L12 22L10.91 15.74L6 18L9.26 13.09L3 12L9.26 10.91L6 6L10.91 8.26L12 2Z"/></svg>';
        if (modelId.startsWith('ollama:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>';
        if (modelId.startsWith('copilot:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><path d="M12 2L3 7l9 5 9-5-9-5zM3 17l9 5 9-5M3 12l9 5 9-5"/></svg>';
        return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>';
    }

    function updateModelDisplay() {
        const selected = modelSelect.options[modelSelect.selectedIndex];
        if (selected && selected.value) {
            modelName.textContent = selected.textContent;
            modelIcon.innerHTML = getProviderIcon(modelSelect.value);
        } else {
            modelName.textContent = 'Select Model';
        }
    }

    function updateWebSearchBtn() {
        // Only show web search button if it's an Ollama model
        webSearchBtn.style.display = modelSelect.value.startsWith('ollama:') ? 'flex' : 'none';
        if (!modelSelect.value.startsWith('ollama:') && includeWebSearch) {
            setWebSearchState(false);
        }
    }

    modelSelect.addEventListener('change', () => {
        chrome.storage.local.set({ lastModelId: modelSelect.value });
        updateModelDisplay();
        updateWebSearchBtn();
    });

    fetchModels();

    // ── NEW CHAT ────────────────────────────────────────────
    newChatBtn.addEventListener('click', () => {
        if (isGenerating) stopGeneration();
        chatHistory = [];
        hasInjectedContextThisSession = false;
        chatContainer.innerHTML = '';
        chatContainer.appendChild(createEmptyState());
        promptInput.value = '';
        promptInput.style.height = 'auto';
        updateSendBtn();
        promptInput.focus();
    });

    function createEmptyState() {
        const el = document.createElement('div');
        el.id = 'emptyState';
        el.className = 'empty-state';
        el.innerHTML =
            '<div class="empty-orb orb-1"></div>' +
            '<div class="empty-orb orb-2"></div>' +
            '<div class="empty-orb orb-3"></div>' +
            '<div class="empty-state-content">' +
            '  <div class="empty-icon-ring">' +
            '    <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke-width="1.5">' +
            '      <path stroke="url(#sparkleGrad)" d="M12 2L13.09 8.26L18 6L14.74 10.91L21 12L14.74 13.09L18 18L13.09 15.74L12 22L10.91 15.74L6 18L9.26 13.09L3 12L9.26 10.91L6 6L10.91 8.26L12 2Z"/>' +
            '    </svg>' +
            '  </div>' +
            '  <h2 class="empty-title">Hello</h2>' +
            '  <p class="empty-subtitle">How can I help you today?</p>' +
            '  <div class="suggestion-chips">' +
            '    <button class="suggestion-chip" data-text="Summarize this page">Summarize</button>' +
            '    <button class="suggestion-chip" data-text="Explain this page in simple terms">Explain</button>' +
            '    <button class="suggestion-chip" data-text="What are the key points of this page?">Key Points</button>' +
            '    <button class="suggestion-chip" data-text="Help me write about this topic">Write</button>' +
            '  </div>' +
            '</div>';
        el.querySelectorAll('.suggestion-chip').forEach(chip => {
            chip.addEventListener('click', () => {
                promptInput.value = chip.dataset.text;
                sendMessage(chip.dataset.text);
            });
        });
        return el;
    }

    // ── CONTEXT TOGGLE ──────────────────────────────────────
    function setContextState(enabled) {
        includeContext = enabled;
        contextToggle.classList.toggle('disabled', !enabled);
        contextToggleText.textContent = enabled ? 'Include website' : 'No context';
        updatePromptPlaceholder();
    }

    function setWebSearchState(enabled) {
        includeWebSearch = enabled;
        if (enabled) {
            webSearchBtn.style.color = 'var(--accent)';
        } else {
            webSearchBtn.style.color = 'var(--text-secondary)';
        }
        updatePromptPlaceholder();
    }

    function updatePromptPlaceholder() {
        if (includeContext && !includeWebSearch) promptInput.placeholder = 'Ask about this page...';
        else if (!includeContext && includeWebSearch) promptInput.placeholder = 'Search the web...';
        else if (includeContext && includeWebSearch) promptInput.placeholder = 'Search web & page...';
        else promptInput.placeholder = 'Ask AI anything...';
    }

    contextCloseBtn.addEventListener('click', e => { e.stopPropagation(); setContextState(!includeContext); });
    contextToggle.addEventListener('click', () => setContextState(!includeContext));
    webSearchBtn.addEventListener('click', () => setWebSearchState(!includeWebSearch));

    // ── THINKING LEVEL ──────────────────────────────────────
    thinkingBtn.addEventListener('click', e => {
        e.stopPropagation();
        thinkingDropdownOpen = !thinkingDropdownOpen;
        thinkingDropdown.style.display = thinkingDropdownOpen ? 'flex' : 'none';
    });
    document.querySelectorAll('.thinking-level-option').forEach(btn => {
        btn.addEventListener('click', () => {
            thinkingLevel = btn.dataset.level;
            thinkingDropdownOpen = false;
            thinkingDropdown.style.display = 'none';
            document.querySelectorAll('.thinking-level-option').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
        });
    });
    document.addEventListener('click', e => {
        if (!thinkingBtn.contains(e.target) && !thinkingDropdown.contains(e.target)) {
            thinkingDropdownOpen = false;
            thinkingDropdown.style.display = 'none';
        }
    });

    // ── AGENT BROWSER TOGGLE ────────────────────────────────
    agentBrowserBtn.addEventListener('click', () => {
        agentBrowserEnabled = !agentBrowserEnabled;
        agentBrowserBtn.classList.toggle('active', agentBrowserEnabled);
        agentBrowserBtn.title = agentBrowserEnabled ? 'Agent Browser: ON' : 'Agent Browser Control';
        if (agentBrowserEnabled) {
            promptInput.placeholder = 'Describe what you want the agent to do on this page...';
        } else {
            promptInput.placeholder = 'Ask about this page...';
        }
    });

    // ── SEND / STOP ─────────────────────────────────────────
    sendBtn.addEventListener('click', () => {
        if (isGenerating) { stopGeneration(); }
        else {
            const text = promptInput.value.trim();
            if (text) sendMessage(text);
        }
    });
    promptInput.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            if (isGenerating) return;
            const text = promptInput.value.trim();
            if (text) sendMessage(text);
        }
    });

    // Suggestion chips (initial)
    document.querySelectorAll('.suggestion-chip').forEach(chip => {
        chip.addEventListener('click', () => {
            promptInput.value = chip.dataset.text;
            sendMessage(chip.dataset.text);
        });
    });

    function stopGeneration() {
        if (abortController) { abortController.abort(); abortController = null; }
        setGeneratingState(false);
    }

    function setGeneratingState(generating) {
        isGenerating = generating;
        promptInput.disabled = generating;
        if (generating) {
            sendIcon.style.display = 'none';
            stopIcon.style.display = 'block';
            sendBtn.disabled = false;
            sendBtn.classList.add('stop-mode');
        } else {
            sendIcon.style.display = 'block';
            stopIcon.style.display = 'none';
            sendBtn.classList.remove('stop-mode');
            updateSendBtn();
        }
    }

    // ── SEND MESSAGE (with full history context) ────────────
    async function sendMessage(text, isRegenerate) {
        const modelId = modelSelect.value;
        if (!text || !modelId) return;

        promptInput.value = '';
        promptInput.style.height = 'auto';
        setGeneratingState(true);

        // Hide empty state
        const es = document.getElementById('emptyState');
        if (es) es.style.display = 'none';

        // Regenerate: pop last assistant from history + DOM
        if (isRegenerate) {
            if (chatHistory.length > 0 && chatHistory[chatHistory.length - 1].role === 'assistant') {
                chatHistory.pop();
            }
            const wrappers = chatContainer.querySelectorAll('.message-wrapper');
            if (wrappers.length > 0) {
                const last = wrappers[wrappers.length - 1];
                if (last.classList.contains('assistant-wrapper')) last.remove();
            }
        } else {
            chatHistory.push({ role: 'user', content: text });
            appendUserMessage(text);
        }

        const assistant = createAssistantMessage();

        // Get page context
        let pageContext = '';
        if (includeContext) {
            try {
                let [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
                if (tab && tab.url && !tab.url.startsWith('chrome://')) {
                    const response = await new Promise(resolve => {
                        chrome.tabs.sendMessage(tab.id, { action: 'getPageContext' }, res => {
                            if (chrome.runtime.lastError) {
                                chrome.scripting.executeScript(
                                    { target: { tabId: tab.id }, files: ['content.js'] },
                                    () => chrome.tabs.sendMessage(tab.id, { action: 'getPageContext' }, resolve)
                                );
                            } else { resolve(res); }
                        });
                    });
                    if (response && response.content) pageContext = response.content;
                }
            } catch (err) { console.warn('Could not get page text', err); }
        }

        // Build messages array with full chat history
        let messagesForApi = chatHistory.map(m => ({ role: m.role, content: m.content }));

        // Inject page context only into the latest user message if not already present
        if (pageContext.length > 0 && !hasInjectedContextThisSession) {
            const truncated = pageContext.length > 50000 ? pageContext.substring(0, 50000) + '...' : pageContext;
            const lastIdx = messagesForApi.length - 1;
            if (lastIdx >= 0 && messagesForApi[lastIdx].role === 'user') {
                messagesForApi[lastIdx] = {
                    role: 'user',
                    content: '[Webpage Context]:\n' + truncated + '\n\n[User Message]:\n' + messagesForApi[lastIdx].content
                };
                hasInjectedContextThisSession = true;
            }
        }

        // Inject agent browser system prompt when agent mode is enabled
        if (agentBrowserEnabled) {
            messagesForApi.unshift({
                role: 'system',
                content: 'You are a browser automation agent. You can control the browser by outputting JSON action blocks wrapped in ```agent-action markers. Available actions:\n' +
                    '- {"type":"click","selector":"CSS selector"} - Click an element\n' +
                    '- {"type":"type","selector":"CSS selector","text":"text to type"} - Type text into an input\n' +
                    '- {"type":"scroll","direction":"up|down","amount":300} - Scroll the page\n' +
                    '- {"type":"navigate","url":"https://..."} - Navigate to a URL\n' +
                    '- {"type":"getElements"} - Get interactive elements on the page\n' +
                    '- {"type":"scan"} - Take a screenshot of the current page\n' +
                    'Output actions as: ```agent-action\n{"type":"...","selector":"..."}\n```\n' +
                    'You can output multiple actions. Explain what you are doing before each action.'
            });
        }

        console.log("SENDING TO API:", JSON.stringify(messagesForApi, null, 2));

        abortController = new AbortController();
        let fullContent = '';
        let fullThinking = '';
        let cursorInterval = null;

        try {
            const res = await fetch('http://localhost:8080/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    model: modelId,
                    messages: messagesForApi,
                    thinkingLevel: thinkingLevel,
                    webSearch: includeWebSearch
                }),
                signal: abortController.signal
            });
            if (!res.ok) throw new Error('Failed to fetch response');

            const reader = res.body.getReader();
            const decoder = new TextDecoder('utf-8');

            cursorInterval = setInterval(() => {
                const cursor = assistant.contentDiv.querySelector('.cursor');
                if (cursor) cursor.classList.toggle('blink-off');
            }, 500);

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                const chunk = decoder.decode(value, { stream: true });
                const lines = chunk.split('\n');
                for (const line of lines) {
                    if (!line.startsWith('data: ')) continue;
                    const dataStr = line.substring(6);
                    if (dataStr === '[DONE]') break;
                    try {
                        const data = JSON.parse(dataStr);
                        if (data.error) {
                            fullContent = data.error;
                            assistant.contentDiv.innerHTML = '<span class="error-text">' + escapeHtml(data.error) + '</span>';
                        } else {
                            if (data.thinking) {
                                fullThinking += data.thinking;
                                assistant.thinkingToggle.style.display = 'flex';
                                assistant.thinkingDiv.style.display = 'block';
                                assistant.thinkingDiv.querySelector('.thinking-text').textContent = fullThinking;
                                if (!fullContent) {
                                    assistant.thinkingDiv.classList.add('expanded');
                                    assistant.thinkingToggle.classList.add('expanded');
                                }
                            }
                            if (data.text) {
                                fullContent += data.text;
                                if (fullThinking) {
                                    assistant.thinkingDiv.classList.remove('expanded');
                                    assistant.thinkingToggle.classList.remove('expanded');
                                }
                            }
                            renderContent(assistant.contentDiv, fullContent, true);
                        }
                        scrollToBottom();
                    } catch (e) {
                        // Some SSE streams split the JSON string over multiple lines or chunks.
                        // But we append data string by line, so incomplete lines are ignored until the buffer fills.
                    }
                }
            }

            if (cursorInterval) clearInterval(cursorInterval);
            renderContent(assistant.contentDiv, fullContent, false);
            renderMath(assistant.contentDiv);

            chatHistory.push({ role: 'assistant', content: fullContent, thinking: fullThinking || undefined });
            assistant.actionsDiv.style.display = 'flex';
            const displayName = modelSelect.options[modelSelect.selectedIndex]
                ? modelSelect.options[modelSelect.selectedIndex].textContent : modelId;
            assistant.modelBadge.textContent = 'Model used: ' + displayName;
            assistant.modelBadge.style.display = 'block';

            // Parse and execute agent actions if agent mode is enabled
            if (agentBrowserEnabled && fullContent) {
                const actionRegex = /```agent-action\s*\n([\s\S]*?)```/g;
                let match;
                while ((match = actionRegex.exec(fullContent)) !== null) {
                    try {
                        const action = JSON.parse(match[1].trim());
                        appendAgentAction(action.type + ': ' + (action.selector || action.url || action.direction || 'executing...'));
                        await executeAgentAction(action);
                    } catch (parseErr) {
                        console.warn('Failed to parse agent action:', parseErr);
                    }
                }
            }

        } catch (e) {
            if (cursorInterval) clearInterval(cursorInterval);
            if (e.name === 'AbortError') {
                renderContent(assistant.contentDiv, fullContent || 'Generation stopped.', false);
                if (fullContent) chatHistory.push({ role: 'assistant', content: fullContent });
            } else {
                assistant.contentDiv.innerHTML = '<span class="error-text">Error: ' + escapeHtml(e.message) + '</span>';
            }
        } finally {
            setGeneratingState(false);
            abortController = null;
            scrollToBottom();
            setTimeout(() => promptInput.focus(), 100);
        }
    }

    // ── MESSAGE RENDERING ───────────────────────────────────
    function appendUserMessage(text) {
        const wrapper = document.createElement('div');
        wrapper.className = 'message-wrapper user-wrapper';
        const bubble = document.createElement('div');
        bubble.className = 'user-message';
        bubble.textContent = text;
        const actions = document.createElement('div');
        actions.className = 'message-actions user-actions';
        actions.appendChild(createActionButton('Copy', 'copy', () => {
            navigator.clipboard.writeText(text);
            const label = actions.querySelector('.action-label');
            label.textContent = 'Copied!';
            setTimeout(() => { label.textContent = 'Copy'; }, 2000);
        }));
        wrapper.appendChild(bubble);
        wrapper.appendChild(actions);
        chatContainer.appendChild(wrapper);
        scrollToBottom();
    }

    function createAssistantMessage() {
        const wrapper = document.createElement('div');
        wrapper.className = 'message-wrapper assistant-wrapper';

        // Thinking toggle (DisclosureGroup)
        const thinkingToggle = document.createElement('button');
        thinkingToggle.className = 'thinking-toggle';
        thinkingToggle.style.display = 'none';
        thinkingToggle.innerHTML =
            '<svg class="thinking-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M12 2C8.13 2 5 5.13 5 9c0 2.38 1.19 4.47 3 5.74V17a2 2 0 002 2h4a2 2 0 002-2v-2.26c1.81-1.27 3-3.36 3-5.74 0-3.87-3.13-7-7-7z"/></svg>' +
            '<span>Reasoning Process</span>' +
            '<svg class="thinking-chevron" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="9 18 15 12 9 6"/></svg>';

        const thinkingDiv = document.createElement('div');
        thinkingDiv.className = 'thinking-content';
        thinkingDiv.style.display = 'none';
        thinkingDiv.innerHTML = '<pre class="thinking-text"></pre>';

        thinkingToggle.addEventListener('click', () => {
            thinkingDiv.classList.toggle('expanded');
            thinkingToggle.classList.toggle('expanded');
        });

        // Content
        const contentDiv = document.createElement('div');
        contentDiv.className = 'assistant-message';
        contentDiv.innerHTML = '<div class="thinking-indicator"><span></span><span></span><span></span></div>';

        // Actions (ExpandingActionButton style)
        const actionsDiv = document.createElement('div');
        actionsDiv.className = 'message-actions';
        actionsDiv.style.display = 'none';

        actionsDiv.appendChild(createActionButton('Copy', 'copy', () => {
            const last = chatHistory.filter(m => m.role === 'assistant').pop();
            if (last) {
                navigator.clipboard.writeText(last.content);
                const label = actionsDiv.querySelector('.copy .action-label');
                if (label) { label.textContent = 'Copied!'; setTimeout(() => { label.textContent = 'Copy'; }, 2000); }
            }
        }));
        actionsDiv.appendChild(createActionButton('Regenerate', 'regenerate', () => {
            const lastUser = [...chatHistory].reverse().find(m => m.role === 'user');
            if (lastUser) sendMessage(lastUser.content, true);
        }));

        // Model badge
        const modelBadge = document.createElement('div');
        modelBadge.className = 'model-badge';
        modelBadge.style.display = 'none';

        wrapper.appendChild(thinkingToggle);
        wrapper.appendChild(thinkingDiv);
        wrapper.appendChild(contentDiv);
        wrapper.appendChild(actionsDiv);
        wrapper.appendChild(modelBadge);
        chatContainer.appendChild(wrapper);

        return { wrapper, contentDiv, thinkingDiv, thinkingToggle, actionsDiv, modelBadge };
    }

    function createActionButton(label, type, onClick) {
        const btn = document.createElement('button');
        btn.className = 'action-btn-expanding ' + type;
        const iconSvg = type === 'copy'
            ? '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>'
            : '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12a9 9 0 109-9 9.75 9.75 0 00-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>';
        btn.innerHTML = '<span class="action-icon">' + iconSvg + '</span><span class="action-label">' + label + '</span>';
        btn.addEventListener('click', onClick);
        return btn;
    }

    // ── MARKDOWN + MATH ─────────────────────────────────────
    function renderContent(element, text, showCursor) {
        if (!text) {
            if (showCursor) element.innerHTML = '<div class="thinking-indicator"><span></span><span></span><span></span></div>';
            return;
        }
        // Protect math tokens
        let mathTokens = [];
        let processed = text.replace(
            /\\\[([\s\S]*?)\\\]|\$\$([\s\S]*?)\$\$|\\\(([\s\S]*?)\\\)|\$((?:[^$\\]|\\.)+)\$/g,
            (match) => { const id = '@@MATH' + mathTokens.length + '@@'; mathTokens.push(match); return id; }
        );
        let rawHtml = marked.parse(processed, { breaks: true, gfm: true });
        mathTokens.forEach((match, i) => { rawHtml = rawHtml.replace('@@MATH' + i + '@@', match); });
        const safeHtml = DOMPurify.sanitize(rawHtml);
        element.innerHTML = safeHtml + (showCursor ? '<span class="cursor">\u258B</span>' : '');
    }

    function renderMath(element) {
        if (window.renderMathInElement) {
            renderMathInElement(element, {
                delimiters: [
                    { left: '$$', right: '$$', display: true },
                    { left: '\\[', right: '\\]', display: true },
                    { left: '$', right: '$', display: false },
                    { left: '\\(', right: '\\)', display: false }
                ],
                throwOnError: false
            });
        }
    }

    // ── UTILITIES ────────────────────────────────────────────
    function scrollToBottom() {
        chatContainer.scrollTo({ top: chatContainer.scrollHeight, behavior: 'smooth' });
    }

    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ── AGENT MODE ──────────────────────────────────────────
    let agentActions = []; // track agent actions for forwarding

    async function executeAgentAction(action) {
        let result;
        try {
            const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

            switch (action.type) {
                case 'click':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentClick', selector: action.selector });
                    break;
                case 'type':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentType', selector: action.selector, text: action.text });
                    break;
                case 'scroll':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentScroll', direction: action.direction, amount: action.amount });
                    break;
                case 'drag':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentDrag', selector: action.selector, dx: action.dx, dy: action.dy });
                    break;
                case 'openTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentOpenTab', url: action.url, active: action.active }, resolve);
                    });
                    break;
                case 'navigate':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentNavigate', url: action.url }, resolve);
                    });
                    break;
                case 'getElements':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentGetElements' });
                    break;
                case 'scan':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentScreenshot' });
                    break;
                default:
                    result = { ok: false, error: 'Unknown action: ' + action.type };
            }
        } catch (e) {
            result = { ok: false, error: e.message };
        }

        if (result && result.summary) {
            agentActions.push({ type: action.type, summary: result.summary });
        }
        return result;
    }

    function appendAgentAction(summary) {
        const wrapper = document.createElement('div');
        wrapper.className = 'agent-action-item';
        wrapper.innerHTML = '<span class="agent-action-icon">⚡</span><span class="agent-action-text">' + escapeHtml(summary) + '</span>';
        chatContainer.appendChild(wrapper);
        scrollToBottom();
    }

    // ── FORWARD TO PRISM APP ────────────────────────────────
    async function forwardChatToApp() {
        if (chatHistory.length === 0) return;

        // Filter out internal context from messages
        const cleanMessages = chatHistory.map(m => {
            let content = m.content;
            // Remove injected webpage context
            content = content.replace(/\[Webpage Context\]:[\s\S]*?\[User Message\]:\n/g, '');
            return { role: m.role, content: content.trim() };
        }).filter(m => m.content.length > 0);

        const modelName = modelSelect.options[modelSelect.selectedIndex]
            ? modelSelect.options[modelSelect.selectedIndex].textContent : modelSelect.value;

        try {
            const res = await fetch('http://localhost:8080/api/forward-chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    messages: cleanMessages,
                    model: modelName,
                    agentActions: agentActions
                })
            });
            if (res.ok) {
                showForwardSuccess();
            }
        } catch (e) {
            console.error('Failed to forward chat:', e);
        }
    }

    function showForwardSuccess() {
        const toast = document.createElement('div');
        toast.className = 'forward-toast';
        toast.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6L9 17l-5-5"/></svg> Sent to Prism';
        document.body.appendChild(toast);
        setTimeout(() => { toast.classList.add('visible'); }, 10);
        setTimeout(() => { toast.classList.remove('visible'); setTimeout(() => toast.remove(), 300); }, 2500);
    }

    // Add forward button to header
    const forwardBtn = document.createElement('button');
    forwardBtn.className = 'header-icon-btn';
    forwardBtn.title = 'Send chat to Prism App';
    forwardBtn.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17l9.2-9.2M17 17V7H7"/></svg>';
    forwardBtn.addEventListener('click', forwardChatToApp);
    document.querySelector('.header-right').insertBefore(forwardBtn, newChatBtn);
});