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
    const screenshotBtn = document.getElementById('screenshotBtn');
    const attachBtn = document.getElementById('attachBtn');
    const fileInput = document.getElementById('fileInput');
    const attachmentPreview = document.getElementById('attachmentPreview');

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
    let pendingAttachments = []; // { dataUrl, mimeType, name }

    // ── SLASH COMMANDS ──────────────────────────────────────
    const builtInCommands = [
        { trigger: '/imagine', expansion: 'Create an image of the following:', isImageGen: true },
        { trigger: '/summarize', expansion: 'Summarize the following:' },
        { trigger: '/explain', expansion: 'Explain the following in detail:' },
        { trigger: '/translate', expansion: 'Translate the following to English:' },
        { trigger: '/fix', expansion: 'Fix the grammar and spelling in:' },
        { trigger: '/code', expansion: 'Write code for the following:' },
        { trigger: '/rewrite', expansion: 'Rewrite the following to be clearer and more professional:' },
        { trigger: '/bullets', expansion: 'Convert the following into bullet points:' },
        { trigger: '/eli5', expansion: 'Explain like I\'m 5:' },
        { trigger: '/pros-cons', expansion: 'List the pros and cons of:' },
    ];

    // Create command autocomplete dropdown
    const cmdDropdown = document.createElement('div');
    cmdDropdown.className = 'command-dropdown';
    cmdDropdown.style.display = 'none';
    document.querySelector('.input-bar').appendChild(cmdDropdown);

    let cmdSelectedIndex = 0;
    let cmdFiltered = [];

    function updateCommandDropdown() {
        const text = promptInput.value;
        // Only match if text starts with / and is a single word
        const slashMatch = text.match(/^\/(\S*)$/);
        if (!slashMatch) {
            cmdDropdown.style.display = 'none';
            return;
        }
        const query = slashMatch[1].toLowerCase();
        cmdFiltered = builtInCommands.filter(c => c.trigger.substring(1).startsWith(query));
        if (cmdFiltered.length === 0) {
            cmdDropdown.style.display = 'none';
            return;
        }
        cmdSelectedIndex = 0;
        renderCommandDropdown();
        cmdDropdown.style.display = 'flex';
    }

    function renderCommandDropdown() {
        cmdDropdown.innerHTML = '';
        cmdFiltered.forEach((cmd, i) => {
            const item = document.createElement('div');
            item.className = 'command-item' + (i === cmdSelectedIndex ? ' selected' : '');
            item.innerHTML = '<span class="command-trigger">' + cmd.trigger + '</span><span class="command-desc">' + (cmd.isImageGen ? 'Generate an image with AI' : cmd.expansion) + '</span>';
            item.addEventListener('mousedown', e => {
                e.preventDefault();
                selectCommand(i);
            });
            item.addEventListener('mouseenter', () => {
                cmdSelectedIndex = i;
                renderCommandDropdown();
            });
            cmdDropdown.appendChild(item);
        });
    }

    function selectCommand(index) {
        const cmd = cmdFiltered[index];
        if (cmd) {
            promptInput.value = cmd.expansion + ' ';
            promptInput.style.height = 'auto';
            promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
            updateSendBtn();
            updateStyleStrip();
        }
        cmdDropdown.style.display = 'none';
    }

    // ── @ TAB MENTIONS ──────────────────────────────────────
    const tabDropdown = document.createElement('div');
    tabDropdown.className = 'command-dropdown tab-mention-dropdown';
    tabDropdown.style.display = 'none';
    document.querySelector('.input-bar').appendChild(tabDropdown);

    let tabSelectedIndex = 0;
    let tabFiltered = [];
    let mentionedTabs = []; // {title, url, tabId}

    // ── IMAGE GEN STYLE STRIP ──────────────────────────────
    const styleStrip = document.createElement('div');
    styleStrip.className = 'image-gen-style-strip';
    styleStrip.style.display = 'none';
    document.querySelector('.input-bar').appendChild(styleStrip);

    function updateStyleStrip() {
        const text = promptInput.value;
        if (text.startsWith('/imagine')) {
            renderStyleStrip();
            styleStrip.style.display = 'flex';
        } else {
            styleStrip.style.display = 'none';
        }
    }

    function renderStyleStrip() {
        styleStrip.innerHTML = '<span class="style-strip-label">Style:</span>';
        imageGenStyles.forEach(s => {
            const pill = document.createElement('button');
            pill.className = 'style-pill' + (imageGenStyle === s.value ? ' active' : '');
            pill.textContent = s.label;
            pill.addEventListener('mousedown', e => {
                e.preventDefault();
                imageGenStyle = s.value;
                renderStyleStrip();
                promptInput.focus();
            });
            styleStrip.appendChild(pill);
        });
    }

    async function updateTabDropdown() {
        const text = promptInput.value;
        const cursorPos = promptInput.selectionStart;
        const textBeforeCursor = text.substring(0, cursorPos);
        // Match @query at cursor position (no space before @ or start of line)
        const atMatch = textBeforeCursor.match(/(^|[\s])@([^\s]*)$/);
        if (!atMatch) {
            tabDropdown.style.display = 'none';
            return;
        }
        const query = atMatch[2].toLowerCase();
        try {
            const tabs = await chrome.tabs.query({});
            tabFiltered = tabs.filter(t =>
                t.title.toLowerCase().includes(query) ||
                (t.url && t.url.toLowerCase().includes(query))
            ).slice(0, 8);
        } catch (e) {
            tabFiltered = [];
        }
        if (tabFiltered.length === 0) {
            tabDropdown.style.display = 'none';
            return;
        }
        tabSelectedIndex = 0;
        renderTabDropdown();
        tabDropdown.style.display = 'flex';
    }

    function renderTabDropdown() {
        tabDropdown.innerHTML = '';
        tabFiltered.forEach((tab, i) => {
            const item = document.createElement('div');
            item.className = 'command-item' + (i === tabSelectedIndex ? ' selected' : '');
            const favicon = tab.favIconUrl ? '<img src="' + tab.favIconUrl + '" width="14" height="14" style="border-radius:3px;margin-right:6px;vertical-align:middle;" onerror="this.style.display=\'none\'">' : '';
            const title = (tab.title || '').substring(0, 50);
            item.innerHTML = favicon + '<span class="command-trigger" style="color:var(--text-primary);font-weight:500;">' + title + '</span>';
            item.addEventListener('mousedown', e => {
                e.preventDefault();
                selectTab(i);
            });
            item.addEventListener('mouseenter', () => {
                tabSelectedIndex = i;
                renderTabDropdown();
            });
            tabDropdown.appendChild(item);
        });
    }

    function selectTab(index) {
        const tab = tabFiltered[index];
        if (!tab) return;
        const cursorPos = promptInput.selectionStart;
        const text = promptInput.value;
        const textBeforeCursor = text.substring(0, cursorPos);
        const atMatch = textBeforeCursor.match(/(^|[\s])@([^\s]*)$/);
        if (atMatch) {
            const matchStart = textBeforeCursor.lastIndexOf('@');
            const before = text.substring(0, matchStart);
            const after = text.substring(cursorPos);
            const mention = '@[' + tab.title + '] ';
            promptInput.value = before + mention + after;
            promptInput.selectionStart = promptInput.selectionEnd = before.length + mention.length;
            mentionedTabs.push({ title: tab.title, url: tab.url, tabId: tab.id });
        }
        tabDropdown.style.display = 'none';
        promptInput.style.height = 'auto';
        promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
        updateSendBtn();
    }

    // Auto-resize textarea
    promptInput.addEventListener('input', () => {
        promptInput.style.height = 'auto';
        promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
        updateSendBtn();
        updateCommandDropdown();
        updateTabDropdown();
        updateStyleStrip();
    });

    function updateSendBtn() {
        sendBtn.disabled = isGenerating ? false : (promptInput.value.trim() === '' && pendingAttachments.length === 0);
    }

    // ── ATTACHMENT HANDLING ──────────────────────────────────
    attachBtn.addEventListener('click', () => fileInput.click());

    fileInput.addEventListener('change', () => {
        for (const file of fileInput.files) addAttachment(file);
        fileInput.value = '';
    });

    // Paste images
    promptInput.addEventListener('paste', (e) => {
        const items = e.clipboardData?.items;
        if (!items) return;
        for (const item of items) {
            if (item.type.startsWith('image/')) {
                e.preventDefault();
                addAttachment(item.getAsFile());
            }
        }
    });

    // Drag-and-drop on input area
    const inputArea = document.querySelector('.input-area');
    inputArea.addEventListener('dragover', e => { e.preventDefault(); inputArea.classList.add('drag-over'); });
    inputArea.addEventListener('dragleave', () => inputArea.classList.remove('drag-over'));
    inputArea.addEventListener('drop', e => {
        e.preventDefault();
        inputArea.classList.remove('drag-over');
        for (const file of e.dataTransfer.files) {
            if (file.type.startsWith('image/')) addAttachment(file);
        }
    });

    function addAttachment(file) {
        if (!file.type.startsWith('image/')) return;
        if (pendingAttachments.length >= 5) return; // max 5 images
        const reader = new FileReader();
        reader.onload = () => {
            pendingAttachments.push({ dataUrl: reader.result, mimeType: file.type, name: file.name });
            renderAttachmentPreviews();
            updateSendBtn();
        };
        reader.readAsDataURL(file);
    }

    function removeAttachment(index) {
        pendingAttachments.splice(index, 1);
        renderAttachmentPreviews();
        updateSendBtn();
    }

    function renderAttachmentPreviews() {
        if (pendingAttachments.length === 0) {
            attachmentPreview.style.display = 'none';
            attachmentPreview.innerHTML = '';
            return;
        }
        attachmentPreview.style.display = 'flex';
        attachmentPreview.innerHTML = '';
        pendingAttachments.forEach((att, i) => {
            const thumb = document.createElement('div');
            thumb.className = 'attachment-thumb';
            thumb.innerHTML =
                '<img src="' + att.dataUrl + '" alt="' + escapeHtml(att.name) + '">' +
                '<button class="attachment-remove" title="Remove">' +
                '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>' +
                '</button>';
            thumb.querySelector('.attachment-remove').addEventListener('click', () => removeAttachment(i));
            attachmentPreview.appendChild(thumb);
        });
    }

    // ── MODEL SELECTOR ──────────────────────────────────────
    async function fetchModels() {
        let models = [];
        try {
            const res = await fetch('http://localhost:8080/api/models');
            if (res.ok) {
                models = await res.json();
            }
        } catch (e) {
            console.warn('Could not fetch external models:', e);
        }

        // Check for Gemini Nano
        let nanoAvailable = false;
        try {
            const lm = typeof window.ai !== 'undefined' && window.ai.languageModel
                ? window.ai.languageModel
                : (typeof LanguageModel !== 'undefined' ? LanguageModel : null);
            if (lm && lm.availability) {
                const status = await lm.availability({ expectedLanguage: 'en' });
                if (status === 'available') {
                    nanoAvailable = true;
                }
            }
        } catch (e) {
            console.warn('Gemini Nano check failed:', e);
        }

        if (nanoAvailable) {
            models.unshift({ id: 'nano:gemini-nano', name: 'Gemini Nano (Local Browser)' });
        }

        if (models.length === 0) {
            modelSelect.innerHTML = '<option value="">Cannot connect to Prism</option>';
            modelName.textContent = 'Cannot connect';
            return;
        }

        modelSelect.innerHTML = '';
        const groups = { 'Apple': [], 'Gemini': [], 'Ollama': [], 'Copilot': [], 'Other': [] };
        models.forEach(m => {
            let name = m.name;
            let group = 'Other';
            if (m.id === 'nano:gemini-nano') { group = 'Gemini'; }
            else if (name.startsWith('Apple')) { group = 'Apple'; }
            else if (m.id.startsWith('gemini:')) { group = 'Gemini'; name = name.replace(/^Gemini:\s*/, ''); }
            else if (m.id.startsWith('ollama:')) { group = 'Ollama'; name = name.replace(/^Ollama:\s*/, ''); }
            else if (m.id.startsWith('copilot:')) {
                group = 'Copilot';
                // Remove the default "Copilot: " prefix but keep the username if it exists.
                // For example "Copilot: Model Name" -> "Model Name"
                // "Copilot (username): Model Name" -> "(username): Model Name"
                // To make it look nice, we can just replace "Copilot: " or "Copilot "
                if (name.startsWith('Copilot: ')) {
                    name = name.substring(9);
                } else if (name.startsWith('Copilot (')) {
                    name = name.substring(8); // leaves "(username): Model Name"
                }
            }
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
            updateModelCapabilities();
        });
    }

    function getProviderIcon(modelId) {
        if (modelId.startsWith('apple:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83"/><path d="M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11"/></svg>';
        if (modelId.startsWith('gemini:') || modelId.startsWith('nano:'))
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

    function updateModelCapabilities() {
        // Only show web search button if it's an Ollama model
        webSearchBtn.style.display = modelSelect.value.startsWith('ollama:') ? 'flex' : 'none';
        if (!modelSelect.value.startsWith('ollama:') && includeWebSearch) {
            setWebSearchState(false);
        }

        // Dynamic thinking options based on model
        const modelId = modelSelect.value.toLowerCase();
        const thinkingDropdown = document.getElementById('thinkingDropdown');
        if (!thinkingDropdown) return;

        if (modelId.startsWith('copilot:') || modelId.startsWith('apple:') || modelId.startsWith('nano:')) {
            // Hide thinking for Copilot, Apple, and Nano models
            thinkingBtn.style.display = 'none';
            thinkingDropdownOpen = false;
            thinkingDropdown.style.display = 'none';
        } else {
            thinkingBtn.style.display = 'flex';

            // Determine thinking levels based on model
            let levels = [];
            if (modelId.startsWith('gemini:')) {
                const model = modelId.replace('gemini:', '');
                if (model.startsWith('gemini-3-pro')) {
                    levels = [{ value: 'low', label: 'Low' }, { value: 'high', label: 'High' }];
                } else if (model.startsWith('gemini-3') || model.startsWith('gemini-2.5')) {
                    levels = [
                        { value: 'off', label: 'Off' },
                        { value: 'low', label: 'Low' },
                        { value: 'medium', label: 'Medium' },
                        { value: 'high', label: 'High' }
                    ];
                } else {
                    // Older Gemini models - no thinking
                    thinkingBtn.style.display = 'none';
                    thinkingDropdownOpen = false;
                    thinkingDropdown.style.display = 'none';
                    return;
                }
            } else if (modelId.startsWith('ollama:')) {
                const model = modelId.replace('ollama:', '');
                if (model.includes('gpt-oss')) {
                    levels = [
                        { value: 'low', label: 'Low' },
                        { value: 'medium', label: 'Medium' },
                        { value: 'high', label: 'High' }
                    ];
                } else if (model.includes('deepseek')) {
                    levels = [{ value: 'off', label: 'Off' }, { value: 'high', label: 'On' }];
                } else {
                    // Other Ollama models - no thinking
                    thinkingBtn.style.display = 'none';
                    thinkingDropdownOpen = false;
                    thinkingDropdown.style.display = 'none';
                    return;
                }
            } else {
                // Default fallback levels
                levels = [
                    { value: 'low', label: 'Low' },
                    { value: 'medium', label: 'Medium' },
                    { value: 'high', label: 'High' }
                ];
            }

            // Rebuild dropdown options
            thinkingDropdown.innerHTML = '';
            let foundActive = false;
            levels.forEach(l => {
                const btn = document.createElement('button');
                btn.className = 'thinking-level-option';
                btn.dataset.level = l.value;
                btn.textContent = l.label;
                if (l.value === thinkingLevel) {
                    btn.classList.add('active');
                    foundActive = true;
                }
                btn.addEventListener('click', () => {
                    thinkingLevel = btn.dataset.level;
                    thinkingDropdownOpen = false;
                    thinkingDropdown.style.display = 'none';
                    thinkingDropdown.querySelectorAll('.thinking-level-option').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                });
                thinkingDropdown.appendChild(btn);
            });
            // If current thinking level isn't in the new options, select the first one
            if (!foundActive && levels.length > 0) {
                thinkingLevel = levels[0].value;
                thinkingDropdown.querySelector('.thinking-level-option').classList.add('active');
            }
        }
    }

    modelSelect.addEventListener('change', () => {
        chrome.storage.local.set({ lastModelId: modelSelect.value });
        updateModelDisplay();
        updateModelCapabilities();
    });

    fetchModels();

    // ── NEW CHAT ────────────────────────────────────────────
    newChatBtn.addEventListener('click', () => {
        if (isGenerating) stopGeneration();
        chatHistory = [];
        hasInjectedContextThisSession = false;
        agentStepCount = 0;
        agentActions = [];
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
            '    <button class="suggestion-chip" data-text="Extract all the links from this page">Extract Links</button>' +
            '    <button class="suggestion-chip" data-text="Search the web for the latest news today">Web Search</button>' +
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
        if (!cmdDropdown.contains(e.target) && e.target !== promptInput) {
            cmdDropdown.style.display = 'none';
        }
        if (!tabDropdown.contains(e.target) && e.target !== promptInput) {
            tabDropdown.style.display = 'none';
        }
    });

    // ── AGENT BROWSER TOGGLE ────────────────────────────────
    agentBrowserBtn.addEventListener('click', () => {
        agentBrowserEnabled = !agentBrowserEnabled;
        agentBrowserBtn.classList.toggle('active', agentBrowserEnabled);
        agentBrowserBtn.title = agentBrowserEnabled ? 'Agent Browser: ON — AI can interact with pages' : 'Agent Browser Control';
        if (agentBrowserEnabled) {
            promptInput.placeholder = 'Tell the agent what to do (e.g. "Fill out the form", "Find the price")...';
            agentStepCount = 0;
        } else {
            promptInput.placeholder = 'Ask about this page...';
        }
    });

    // ── SCREENSHOT ──────────────────────────────────────────
    screenshotBtn.addEventListener('click', async () => {
        screenshotBtn.style.color = 'var(--accent)';
        try {
            const result = await new Promise(resolve => {
                chrome.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve);
            });
            if (result && result.ok && result.image) {
                pendingAttachments.push({ name: 'screenshot.png', dataUrl: result.image });
                renderAttachmentPreviews();
                promptInput.focus();
            }
        } catch (e) {
            console.warn('Screenshot failed:', e);
        }
        setTimeout(() => { screenshotBtn.style.color = ''; }, 300);
    });

    // ── SEND / STOP ─────────────────────────────────────────
    sendBtn.addEventListener('click', () => {
        if (isGenerating) { stopGeneration(); }
        else {
            const text = promptInput.value.trim() || (pendingAttachments.length > 0 ? 'Describe this image.' : '');
            if (text) sendMessage(text);
        }
    });
    // Use capture phase on document to intercept keys before Chrome side-panel handling
    document.addEventListener('keydown', e => {
        if (document.activeElement !== promptInput) return;
        const cmdVisible = cmdDropdown.style.display !== 'none' && cmdFiltered.length > 0;
        const tabVisible = tabDropdown.style.display !== 'none' && tabFiltered.length > 0;
        // Command dropdown navigation
        if (cmdVisible) {
            if (e.key === 'ArrowDown') {
                e.preventDefault(); e.stopPropagation();
                cmdSelectedIndex = Math.min(cmdSelectedIndex + 1, cmdFiltered.length - 1);
                renderCommandDropdown();
                return;
            }
            if (e.key === 'ArrowUp') {
                e.preventDefault(); e.stopPropagation();
                cmdSelectedIndex = Math.max(cmdSelectedIndex - 1, 0);
                renderCommandDropdown();
                return;
            }
            if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) {
                e.preventDefault(); e.stopPropagation();
                selectCommand(cmdSelectedIndex);
                return;
            }
            if (e.key === 'Escape') {
                e.preventDefault(); e.stopPropagation();
                cmdDropdown.style.display = 'none';
                return;
            }
        }
        // Tab mention dropdown navigation
        if (tabVisible) {
            if (e.key === 'ArrowDown') {
                e.preventDefault(); e.stopPropagation();
                tabSelectedIndex = Math.min(tabSelectedIndex + 1, tabFiltered.length - 1);
                renderTabDropdown();
                return;
            }
            if (e.key === 'ArrowUp') {
                e.preventDefault(); e.stopPropagation();
                tabSelectedIndex = Math.max(tabSelectedIndex - 1, 0);
                renderTabDropdown();
                return;
            }
            if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) {
                e.preventDefault(); e.stopPropagation();
                selectTab(tabSelectedIndex);
                return;
            }
            if (e.key === 'Escape') {
                e.preventDefault(); e.stopPropagation();
                tabDropdown.style.display = 'none';
                return;
            }
        }
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            if (isGenerating) return;
            const text = promptInput.value.trim() || (pendingAttachments.length > 0 ? 'Describe this image.' : '');
            if (text) sendMessage(text);
        }
    }, true);

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

    // ── IMAGE GENERATION ──────────────────────────────────
    const imageGenStyles = [
        { label: 'Animation', value: 'Animation' },
        { label: 'Illustration', value: 'Illustration' },
        { label: 'Sketch', value: 'Sketch' },
        { label: 'ChatGPT', value: 'ChatGPT' },
        { label: 'Oil Painting', value: 'Oil Painting (ChatGPT)' },
        { label: 'Watercolor', value: 'Watercolor (ChatGPT)' },
    ];
    let imageGenStyle = 'Animation';

    async function generateImage(prompt) {
        const es = document.getElementById('emptyState');
        if (es) es.style.display = 'none';

        chatHistory.push({ role: 'user', content: '/imagine ' + prompt });
        appendUserMessage('/imagine ' + prompt, []);
        setGeneratingState(true);

        const assistant = createAssistantMessage();
        renderContent(assistant.contentDiv, '🎨 Generating image (' + imageGenStyle + ')...', true);

        try {
            const res = await fetch('http://localhost:8080/api/generate-image', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ prompt: prompt, style: imageGenStyle })
            });
            const result = await res.json();
            if (result.status === 'ok' && result.image) {
                const msgText = result.text ? result.text : '';
                renderContent(assistant.contentDiv, msgText || '🎨 Image generated successfully.', false);
                // Add image to the message
                const img = document.createElement('img');
                img.src = result.image;
                img.alt = prompt;
                img.className = 'generated-image';
                img.addEventListener('click', () => {
                    window.open(result.image, '_blank');
                });
                assistant.contentDiv.appendChild(img);
                assistant.actionsDiv.style.display = 'flex';
                chatHistory.push({ role: 'assistant', content: msgText || '[Generated Image]', attachments: [{ dataUrl: result.image, mimeType: 'image/png', name: 'generated.png' }] });
            } else {
                renderContent(assistant.contentDiv, '⚠️ ' + (result.error || 'Image generation failed.'), false);
                assistant.actionsDiv.style.display = 'flex';
                chatHistory.push({ role: 'assistant', content: result.error || 'Image generation failed.' });
            }
        } catch (e) {
            renderContent(assistant.contentDiv, '⚠️ Could not connect to Prism app for image generation.', false);
            assistant.actionsDiv.style.display = 'flex';
            chatHistory.push({ role: 'assistant', content: 'Image generation connection failed.' });
        }
        setGeneratingState(false);
        scrollToBottom();
    }

    // ── SEND MESSAGE (with full history context) ────────────
    async function sendMessage(text, isRegenerate) {
        const modelId = modelSelect.value;
        if ((!text && pendingAttachments.length === 0) || !modelId) return;

        // Handle /imagine command
        const imagineMatch = text.match(/^\/imagine\s+(.+)/s);
        if (imagineMatch && !isRegenerate) {
            pendingAttachments = [];
            renderAttachmentPreviews();
            promptInput.value = '';
            promptInput.style.height = 'auto';
            await generateImage(imagineMatch[1].trim());
            return;
        }

        // Capture attachments before clearing
        const attachments = [...pendingAttachments];
        pendingAttachments = [];
        renderAttachmentPreviews();

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
            chatHistory.push({ role: 'user', content: text, attachments: attachments.length > 0 ? attachments : undefined });
            appendUserMessage(text, attachments);
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
        let messagesForApi = chatHistory.map(m => {
            const msg = { role: m.role, content: m.content };
            if (m.attachments && m.attachments.length > 0) {
                msg.images = m.attachments.map(a => a.dataUrl);
            }
            return msg;
        });

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

        // Fetch and inject @mentioned tab content
        if (mentionedTabs.length > 0) {
            let tabContexts = [];
            for (const mt of mentionedTabs) {
                try {
                    const tabContent = await new Promise(resolve => {
                        chrome.tabs.sendMessage(mt.tabId, { action: 'getPageContext' }, res => {
                            if (chrome.runtime.lastError) {
                                chrome.scripting.executeScript(
                                    { target: { tabId: mt.tabId }, files: ['content.js'] },
                                    () => chrome.tabs.sendMessage(mt.tabId, { action: 'getPageContext' }, r => resolve(r))
                                );
                            } else { resolve(res); }
                        });
                    });
                    if (tabContent && tabContent.content) {
                        const truncContent = tabContent.content.length > 20000 ? tabContent.content.substring(0, 20000) + '...' : tabContent.content;
                        tabContexts.push('[Tab: ' + mt.title + ' (' + mt.url + ')]:\n' + truncContent);
                    }
                } catch (e) {
                    console.warn('Could not get tab content for:', mt.title, e);
                }
            }
            if (tabContexts.length > 0) {
                const lastIdx = messagesForApi.length - 1;
                if (lastIdx >= 0 && messagesForApi[lastIdx].role === 'user') {
                    messagesForApi[lastIdx].content = tabContexts.join('\n\n') + '\n\n' + messagesForApi[lastIdx].content;
                }
            }
            mentionedTabs = [];
        }

        // Inject agent browser system prompt when agent mode is enabled
        if (agentBrowserEnabled) {
            messagesForApi.unshift({
                role: 'system',
                content: 'You are a powerful browser automation agent. You control the browser by outputting JSON action blocks wrapped in ```agent-action markers. After actions execute, you receive results and can take more actions.\n\n' +
                    '## Page Interaction:\n' +
                    '- {"type":"click","selector":"CSS or text"} - Click element\n' +
                    '- {"type":"type","selector":"CSS or text","text":"..."} - Type into input\n' +
                    '- {"type":"select","selector":"CSS","value":"..."} - Choose dropdown option\n' +
                    '- {"type":"scroll","direction":"up|down","amount":300} - Scroll page\n' +
                    '- {"type":"hover","selector":"CSS or text"} - Hover over element\n' +
                    '- {"type":"drag","selector":"CSS","dx":100,"dy":0} - Drag element\n' +
                    '- {"type":"toggleCheckbox","selector":"CSS"} - Toggle checkbox/radio\n' +
                    '- {"type":"fillForm","fields":[{"selector":"#id","value":"..."}]} - Fill multiple form fields\n' +
                    '- {"type":"getElements"} - List interactive elements on page\n' +
                    '- {"type":"extractText","selector":"CSS"} - Get text from elements\n' +
                    '- {"type":"extractLinks"} - Get all page links\n' +
                    '- {"type":"extractTable","selector":"table"} - Extract table as JSON\n' +
                    '- {"type":"highlight","selector":"CSS","color":"yellow"} - Highlight elements\n' +
                    '- {"type":"waitFor","selector":"CSS","timeout":5000} - Wait for element\n' +
                    '- {"type":"getAttribute","selector":"CSS","attribute":"href"} - Get attribute\n' +
                    '- {"type":"readSelection"} - Get user-selected text\n' +
                    '- {"type":"readPageMeta"} - Get page metadata (title, description, etc.)\n' +
                    '- {"type":"scan"} - Take a screenshot of the page + get page dimensions. The screenshot will be sent to you as an image for visual analysis.\n\n' +
                    '## Browser Control:\n' +
                    '- {"type":"navigate","url":"https://..."} - Go to URL\n' +
                    '- {"type":"openTab","url":"https://...","active":true} - Open new tab\n' +
                    '- {"type":"closeTab","tabId":123} - Close tab\n' +
                    '- {"type":"switchTab","tabId":123} - Switch to tab\n' +
                    '- {"type":"getTabs"} - List all tabs\n' +
                    '- {"type":"goBack"} - Browser back\n' +
                    '- {"type":"goForward"} - Browser forward\n' +
                    '- {"type":"reloadTab"} - Reload current tab\n' +
                    '- {"type":"duplicateTab"} - Duplicate tab\n' +
                    '- {"type":"pinTab"} - Pin/unpin tab\n' +
                    '- {"type":"groupTabs","tabIds":[1,2],"title":"Name"} - Group tabs\n' +
                    '- {"type":"captureTab"} - Screenshot visible tab (image sent to you for visual analysis)\n' +
                    '- {"type":"createBookmark","title":"...","url":"..."} - Add bookmark\n' +
                    '- {"type":"searchBookmarks","query":"..."} - Search bookmarks\n\n' +
                    '## Web & Information:\n' +
                    '- {"type":"webSearch","query":"..."} - Search DuckDuckGo\n' +
                    '- {"type":"fetchUrl","url":"https://..."} - Read any webpage content\n' +
                    '- {"type":"wikipedia","title":"..."} - Wikipedia article summary\n' +
                    '- {"type":"weather","location":"City"} - Current weather\n' +
                    '- {"type":"translate","text":"...","from":"en","to":"es"} - Translate text\n' +
                    '- {"type":"dictionary","word":"..."} - Word definition\n\n' +
                    'Output: ```agent-action\n{"type":"..."}\n```\n' +
                    'CRITICAL: You MUST wrap every action JSON in ```agent-action fences. Never output bare JSON outside fences. Actions without ```agent-action will NOT execute.\n' +
                    'You may output multiple action blocks. Explain each step briefly. When done, give final summary without action blocks.'
            });
        }

        console.log("SENDING TO API:", JSON.stringify(messagesForApi, null, 2));

        abortController = new AbortController();
        let fullContent = '';
        let fullThinking = '';
        let cursorInterval = null;

        try {
            if (modelId === 'nano:gemini-nano') {
                const lm = typeof window.ai !== 'undefined' && window.ai.languageModel
                    ? window.ai.languageModel
                    : (typeof LanguageModel !== 'undefined' ? LanguageModel : null);

                if (!lm) throw new Error("Gemini Nano is not available in this browser.");

                let promptText = messagesForApi.map(m => {
                    if (m.role === 'system') return 'System: ' + m.content;
                    if (m.role === 'user') return 'User: ' + m.content;
                    if (m.role === 'assistant') return 'Assistant: ' + m.content;
                    return m.content;
                }).join('\n\n') + '\n\nAssistant:';

                cursorInterval = setInterval(() => {
                    const cursor = assistant.contentDiv.querySelector('.cursor');
                    if (cursor) cursor.classList.toggle('blink-off');
                }, 500);

                const session = await lm.create({ expectedLanguage: 'en' });

                let stream;
                try {
                    stream = session.promptStreaming(promptText, { signal: abortController.signal });
                } catch (e) {
                    stream = session.promptStreaming(promptText);
                }

                let previousChunk = "";
                for await (const chunk of stream) {
                    if (abortController.signal.aborted) break;

                    // Depending on the Chrome version, `chunk` might be the full accumulated string
                    // or just the newly generated tokens. We handle both cases to prevent clearing.
                    const newText = chunk.startsWith(previousChunk) ? chunk.slice(previousChunk.length) : chunk;
                    fullContent += newText;
                    previousChunk = chunk;

                    renderContent(assistant.contentDiv, fullContent, true);
                    scrollToBottom();
                }
            } else {
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

            // Agentic loop: execute actions, send results back to AI, continue
            if (agentBrowserEnabled && fullContent) {
                let loopContent = fullContent;
                const MAX_AGENT_LOOPS = 10;
                agentStepCount = 0; // reset step counter for new agent session

                // Show agent progress banner
                const agentBanner = document.createElement('div');
                agentBanner.className = 'agent-progress-banner';
                agentBanner.innerHTML = '<div class="agent-progress-dot"></div><span>Agent is working\u2026</span>';
                chatContainer.appendChild(agentBanner);
                scrollToBottom();

                for (let loop = 0; loop < MAX_AGENT_LOOPS; loop++) {
                    if (!abortController || abortController.signal.aborted) break;

                    // Update banner with loop count
                    agentBanner.querySelector('span').textContent = 'Agent is working\u2026 (loop ' + (loop + 1) + '/' + MAX_AGENT_LOOPS + ')';

                    // Parse agent actions from current response (fenced + bare JSON fallback)
                    let actions = [];
                    // Primary: fenced ```agent-action blocks
                    const actionRegex = /```agent-action\s*\n([\s\S]*?)```/g;
                    let match;
                    while ((match = actionRegex.exec(loopContent)) !== null) {
                        try { actions.push(JSON.parse(match[1].trim())); } catch (e) { }
                    }
                    // Fallback: bare JSON blocks with {"type":"..."} pattern (only if no fenced found)
                    if (actions.length === 0) {
                        const bareRegex = /(?:^|\n)\s*(\{"type"\s*:\s*"[^"]+?"[^}]*\})/g;
                        while ((match = bareRegex.exec(loopContent)) !== null) {
                            try {
                                const parsed = JSON.parse(match[1].trim());
                                if (parsed.type) actions.push(parsed);
                            } catch (e) { }
                        }
                    }

                    if (actions.length === 0) break; // No actions = agent is done

                    // Execute all actions and collect results
                    let results = [];
                    for (const action of actions) {
                        appendAgentAction(null, action);
                        const result = await executeAgentAction(action);
                        results.push({ type: action.type, result: result || {} });

                        // Show screenshot inline if the action captured one
                        if ((action.type === 'captureTab' || action.type === 'scan') && result?.ok && result?.image) {
                            appendAgentScreenshot(result.image);
                        }
                    }

                    // Build results summary for AI
                    let screenshotImages = [];
                    const resultText = results.map(r => {
                        const res = r.result;
                        // Collect screenshot images for vision
                        if ((r.type === 'captureTab' || r.type === 'scan') && res.ok && res.image) {
                            screenshotImages.push(res.image);
                        }
                        let info = res.summary || res.error || '';
                        for (const key of ['elements', 'tabs', 'data', 'text', 'links', 'pageInfo', 'meta', 'content', 'definition', 'weather', 'translation', 'bookmarks', 'value']) {
                            if (res[key]) {
                                const val = typeof res[key] === 'string' ? res[key] : JSON.stringify(res[key]);
                                info += '\n' + val.substring(0, 3000);
                            }
                        }
                        return `[${r.type}] ${res.ok ? 'OK' : 'FAILED'}: ${info}`;
                    }).join('\n\n');

                    // Feed results back to AI
                    messagesForApi.push({ role: 'assistant', content: loopContent });
                    const resultMsg = {
                        role: 'user',
                        content: '[Agent Action Results]:\n' + resultText + '\n\nContinue with the task. If done, provide a final summary without any agent-action blocks.'
                    };
                    if (screenshotImages.length > 0) {
                        resultMsg.images = screenshotImages;
                    }
                    messagesForApi.push(resultMsg);

                    // Create new assistant message for next iteration
                    const nextAssistant = createAssistantMessage();
                    loopContent = '';
                    let nextThinking = '';

                    abortController = new AbortController();
                    let nextCursorInterval = setInterval(() => {
                        const cursor = nextAssistant.contentDiv.querySelector('.cursor');
                        if (cursor) cursor.classList.toggle('blink-off');
                    }, 500);

                    try {
                        const loopRes = await fetch('http://localhost:8080/api/chat', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({
                                model: modelId,
                                messages: messagesForApi,
                                thinkingLevel: thinkingLevel
                            }),
                            signal: abortController.signal
                        });
                        if (!loopRes.ok) throw new Error('Agent loop: failed to fetch');

                        const loopReader = loopRes.body.getReader();
                        const loopDecoder = new TextDecoder('utf-8');

                        while (true) {
                            const { done, value } = await loopReader.read();
                            if (done) break;
                            const chunk = loopDecoder.decode(value, { stream: true });
                            for (const line of chunk.split('\n')) {
                                if (!line.startsWith('data: ')) continue;
                                const dataStr = line.substring(6);
                                if (dataStr === '[DONE]') break;
                                try {
                                    const d = JSON.parse(dataStr);
                                    if (d.thinking) {
                                        nextThinking += d.thinking;
                                        nextAssistant.thinkingToggle.style.display = 'flex';
                                        nextAssistant.thinkingDiv.style.display = 'block';
                                        nextAssistant.thinkingDiv.querySelector('.thinking-text').textContent = nextThinking;
                                    }
                                    if (d.text) loopContent += d.text;
                                    if (d.error) loopContent = d.error;
                                    renderContent(nextAssistant.contentDiv, loopContent, true);
                                    scrollToBottom();
                                } catch (e) { }
                            }
                        }

                        clearInterval(nextCursorInterval);
                        renderContent(nextAssistant.contentDiv, loopContent, false);
                        renderMath(nextAssistant.contentDiv);

                        chatHistory.push({ role: 'assistant', content: loopContent, thinking: nextThinking || undefined });
                        nextAssistant.actionsDiv.style.display = 'flex';
                        const dn = modelSelect.options[modelSelect.selectedIndex]
                            ? modelSelect.options[modelSelect.selectedIndex].textContent : modelId;
                        nextAssistant.modelBadge.textContent = 'Model used: ' + dn;
                        nextAssistant.modelBadge.style.display = 'block';

                    } catch (e) {
                        clearInterval(nextCursorInterval);
                        if (e.name === 'AbortError') {
                            renderContent(nextAssistant.contentDiv, loopContent || 'Agent stopped.', false);
                            if (loopContent) chatHistory.push({ role: 'assistant', content: loopContent });
                        } else {
                            nextAssistant.contentDiv.innerHTML = '<span class="error-text">Agent error: ' + escapeHtml(e.message) + '</span>';
                        }
                        break;
                    }
                }

                // Remove agent progress banner
                agentBanner.remove();

                // Add completion summary
                if (agentStepCount > 0) {
                    const summary = document.createElement('div');
                    summary.className = 'agent-complete-banner';
                    summary.innerHTML = '<span class="agent-complete-icon">\u2705</span><span>Agent completed ' + agentStepCount + ' action' + (agentStepCount > 1 ? 's' : '') + '</span>';
                    chatContainer.appendChild(summary);
                    scrollToBottom();
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
    function appendUserMessage(text, attachments) {
        const wrapper = document.createElement('div');
        wrapper.className = 'message-wrapper user-wrapper';

        // Show image thumbnails if present
        if (attachments && attachments.length > 0) {
            const imgRow = document.createElement('div');
            imgRow.className = 'user-images-row';
            attachments.forEach(att => {
                const img = document.createElement('img');
                img.src = att.dataUrl;
                img.className = 'user-image-thumb';
                img.alt = att.name;
                imgRow.appendChild(img);
            });
            wrapper.appendChild(imgRow);
        }

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
            if (showCursor) element.innerHTML = '<div class="thinking-indicator"><span class="working-orb"></span><span class="working-text">Working\u2026</span></div>';
            return;
        }
        // Strip agent-action code blocks and replace with friendly action pills
        let cleaned = text;
        if (agentBrowserEnabled) {
            cleaned = cleaned.replace(/```agent-action\s*\n([\s\S]*?)```/g, (match, jsonStr) => {
                try {
                    const action = JSON.parse(jsonStr.trim());
                    return '\n' + formatAgentActionInline(action) + '\n';
                } catch (e) {
                    return '';
                }
            });
            // Also strip bare JSON action blocks
            cleaned = cleaned.replace(/(?:^|\n)\s*(\{"type"\s*:\s*"[^"]+?"[^}]*\})/g, (match, jsonStr) => {
                try {
                    const action = JSON.parse(jsonStr.trim());
                    if (action.type) return '\n' + formatAgentActionInline(action) + '\n';
                } catch (e) { }
                return match;
            });
        }
        // Protect math tokens
        let mathTokens = [];
        let processed = cleaned.replace(
            /\\\[([\s\S]*?)\\\]|\$\$([\s\S]*?)\$\$|\\\(([\s\S]*?)\\\)|\$((?:[^$\\]|\\.)+)\$/g,
            (match) => { const id = '@@MATH' + mathTokens.length + '@@'; mathTokens.push(match); return id; }
        );
        let rawHtml = marked.parse(processed, { breaks: true, gfm: true });
        mathTokens.forEach((match, i) => { rawHtml = rawHtml.replace('@@MATH' + i + '@@', match); });
        const safeHtml = DOMPurify.sanitize(rawHtml, { ADD_ATTR: ['class'] });
        element.innerHTML = safeHtml + (showCursor ? '<span class="cursor">\u258B</span>' : '');
    }

    function formatAgentActionInline(action) {
        const desc = getAgentActionDescription(action);
        return '<span class="agent-inline-action">' + desc.icon + ' ' + escapeHtml(desc.label) + '</span>';
    }

    function getAgentActionDescription(action) {
        const sel = action.selector ? ('"' + (action.selector.length > 30 ? action.selector.substring(0, 30) + '...' : action.selector) + '"') : '';
        function safeHost(url) { try { return new URL(url).hostname; } catch (e) { return url ? url.substring(0, 30) : 'page'; } }
        switch (action.type) {
            case 'click': return { icon: '👆', label: 'Clicked ' + sel };
            case 'type': return { icon: '⌨️', label: 'Typed "' + (action.text || '').substring(0, 40) + '"' + (sel ? ' into ' + sel : '') };
            case 'select': return { icon: '📋', label: 'Selected "' + (action.value || '') + '"' + (sel ? ' in ' + sel : '') };
            case 'scroll': return { icon: '📜', label: 'Scrolled ' + (action.direction || 'down') + ' ' + (action.amount || 300) + 'px' };
            case 'hover': return { icon: '🎯', label: 'Hovered over ' + sel };
            case 'drag': return { icon: '✋', label: 'Dragged ' + sel + ' by (' + (action.dx || 0) + ', ' + (action.dy || 0) + ')' };
            case 'toggleCheckbox': return { icon: '☑️', label: 'Toggled checkbox ' + sel };
            case 'fillForm': return { icon: '📝', label: 'Filled form with ' + (action.fields ? action.fields.length : 0) + ' fields' };
            case 'getElements': return { icon: '🔍', label: 'Scanned page elements' };
            case 'extractText': return { icon: '📄', label: 'Extracted text from ' + sel };
            case 'extractLinks': return { icon: '🔗', label: 'Extracted all links' };
            case 'extractTable': return { icon: '📊', label: 'Extracted table data' };
            case 'highlight': return { icon: '🖍️', label: 'Highlighted ' + sel };
            case 'waitFor': return { icon: '⏳', label: 'Waiting for ' + sel };
            case 'getAttribute': return { icon: '🏷️', label: 'Read attribute "' + (action.attribute || '') + '" from ' + sel };
            case 'readSelection': return { icon: '✂️', label: 'Read selected text' };
            case 'readPageMeta': return { icon: '📑', label: 'Read page metadata' };
            case 'scan': return { icon: '�', label: 'Took screenshot & scanned page' };
            case 'navigate': return { icon: '🌐', label: 'Navigated to ' + safeHost(action.url) };
            case 'openTab': return { icon: '➕', label: 'Opened new tab' + (action.url ? ': ' + safeHost(action.url) : '') };
            case 'closeTab': return { icon: '✖️', label: 'Closed tab' };
            case 'switchTab': return { icon: '🔀', label: 'Switched to tab ' + (action.tabId || '') };
            case 'getTabs': return { icon: '📑', label: 'Listed all tabs' };
            case 'goBack': return { icon: '⬅️', label: 'Went back' };
            case 'goForward': return { icon: '➡️', label: 'Went forward' };
            case 'reloadTab': return { icon: '🔄', label: 'Reloaded page' };
            case 'duplicateTab': return { icon: '📋', label: 'Duplicated tab' };
            case 'pinTab': return { icon: '📌', label: 'Pinned tab' };
            case 'groupTabs': return { icon: '📁', label: 'Grouped ' + (action.tabIds ? action.tabIds.length : '') + ' tabs' };
            case 'captureTab': return { icon: '📸', label: 'Took screenshot' };
            case 'createBookmark': return { icon: '🔖', label: 'Bookmarked "' + (action.title || '') + '"' };
            case 'searchBookmarks': return { icon: '🔍', label: 'Searched bookmarks for "' + (action.query || '') + '"' };
            case 'webSearch': return { icon: '🌍', label: 'Searched web for "' + (action.query || '').substring(0, 40) + '"' };
            case 'fetchUrl': return { icon: '📥', label: 'Fetched ' + safeHost(action.url) };
            case 'wikipedia': return { icon: '📚', label: 'Looked up "' + (action.title || '') + '" on Wikipedia' };
            case 'weather': return { icon: '🌤️', label: 'Checked weather in ' + (action.location || '') };
            case 'translate': return { icon: '🌐', label: 'Translated text' + (action.to ? ' to ' + action.to : '') };
            case 'dictionary': return { icon: '📖', label: 'Looked up "' + (action.word || '') + '"' };
            default: return { icon: '⚡', label: action.type };
        }
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
    let agentStepCount = 0; // step counter for agent actions

    async function executeAgentAction(action) {
        let result;
        try {
            const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

            // Content script (DOM) actions
            switch (action.type) {
                case 'click':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentClick', selector: action.selector });
                    break;
                case 'type':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentType', selector: action.selector, text: action.text });
                    break;
                case 'select':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentSelect', selector: action.selector, value: action.value });
                    break;
                case 'scroll':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentScroll', direction: action.direction, amount: action.amount });
                    break;
                case 'hover':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentHover', selector: action.selector });
                    break;
                case 'drag':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentDrag', selector: action.selector, dx: action.dx, dy: action.dy });
                    break;
                case 'toggleCheckbox':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentToggleCheckbox', selector: action.selector });
                    break;
                case 'fillForm':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentFillForm', fields: action.fields });
                    break;
                case 'getElements':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentGetElements' });
                    break;
                case 'extractText':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentExtractText', selector: action.selector });
                    break;
                case 'extractLinks':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentExtractLinks' });
                    break;
                case 'extractTable':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentExtractTable', selector: action.selector });
                    break;
                case 'highlight':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentHighlight', selector: action.selector, color: action.color });
                    break;
                case 'waitFor':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentWaitFor', selector: action.selector, timeout: action.timeout });
                    break;
                case 'getAttribute':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentGetAttribute', selector: action.selector, attribute: action.attribute });
                    break;
                case 'readSelection':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentReadSelection' });
                    break;
                case 'readPageMeta':
                    result = await chrome.tabs.sendMessage(tab.id, { action: 'agentReadPageMeta' });
                    break;
                case 'scan': {
                    // Capture real screenshot via background + get page info from content
                    const [scanScreenshot, scanPageInfo] = await Promise.all([
                        new Promise(resolve => chrome.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve)),
                        chrome.tabs.sendMessage(tab.id, { action: 'agentScreenshot' }).catch(() => ({}))
                    ]);
                    result = {
                        ok: scanScreenshot?.ok || false,
                        image: scanScreenshot?.image || null,
                        summary: 'Scanned page with screenshot',
                        pageInfo: scanPageInfo?.pageInfo || null
                    };
                    break;
                }

                // Background (browser-level) actions
                case 'openTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentOpenTab', url: action.url, active: action.active }, resolve);
                    });
                    break;
                case 'closeTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentCloseTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'switchTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentSwitchTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'getTabs':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentGetTabs' }, resolve);
                    });
                    break;
                case 'navigate':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentNavigate', url: action.url }, resolve);
                    });
                    break;
                case 'goBack':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentGoBack' }, resolve);
                    });
                    break;
                case 'goForward':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentGoForward' }, resolve);
                    });
                    break;
                case 'reloadTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentReloadTab' }, resolve);
                    });
                    break;
                case 'duplicateTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentDuplicateTab' }, resolve);
                    });
                    break;
                case 'pinTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentPinTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'groupTabs':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentGroupTabs', tabIds: action.tabIds, title: action.title, color: action.color }, resolve);
                    });
                    break;
                case 'captureTab':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve);
                    });
                    break;
                case 'createBookmark':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentCreateBookmark', title: action.title, url: action.url }, resolve);
                    });
                    break;
                case 'searchBookmarks':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentSearchBookmarks', query: action.query }, resolve);
                    });
                    break;

                // External API actions (via background)
                case 'webSearch':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentWebSearch', query: action.query }, resolve);
                    });
                    break;
                case 'fetchUrl':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentFetchUrl', url: action.url }, resolve);
                    });
                    break;
                case 'wikipedia':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentWikipedia', title: action.title }, resolve);
                    });
                    break;
                case 'weather':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentWeather', location: action.location }, resolve);
                    });
                    break;
                case 'translate':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentTranslate', text: action.text, from: action.from, to: action.to }, resolve);
                    });
                    break;
                case 'dictionary':
                    result = await new Promise(resolve => {
                        chrome.runtime.sendMessage({ action: 'agentDictionary', word: action.word }, resolve);
                    });
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

    function appendAgentAction(summary, action) {
        agentStepCount++;
        const desc = action ? getAgentActionDescription(action) : { icon: '⚡', label: summary };
        const wrapper = document.createElement('div');
        wrapper.className = 'agent-action-item';
        wrapper.innerHTML = '<span class="agent-step-num">' + agentStepCount + '</span>' +
            '<span class="agent-action-icon">' + desc.icon + '</span>' +
            '<span class="agent-action-text">' + escapeHtml(desc.label) + '</span>' +
            '<span class="agent-action-status">✓</span>';
        chatContainer.appendChild(wrapper);
        scrollToBottom();
    }

    function appendAgentScreenshot(dataUrl) {
        const wrapper = document.createElement('div');
        wrapper.className = 'agent-screenshot-wrapper';
        const img = document.createElement('img');
        img.src = dataUrl;
        img.className = 'agent-screenshot';
        img.alt = 'Page screenshot';
        img.addEventListener('click', () => window.open(dataUrl, '_blank'));
        wrapper.appendChild(img);
        chatContainer.appendChild(wrapper);
        scrollToBottom();

        // Store screenshot in chat history for forwarding
        chatHistory.push({
            role: 'user',
            content: '[Agent Screenshot]',
            attachments: [{ dataUrl: dataUrl, mimeType: 'image/png', name: 'agent-screenshot.png' }]
        });
    }

    // ── FORWARD TO PRISM APP ────────────────────────────────
    async function forwardChatToApp() {
        if (chatHistory.length === 0) return;

        // Filter out internal context from messages
        const cleanMessages = chatHistory.map(m => {
            let content = m.content;
            // Remove injected webpage context
            content = content.replace(/\[Webpage Context\]:[\s\S]*?\[User Message\]:\n/g, '');
            const msg = { role: m.role, content: content.trim() };
            if (m.attachments && m.attachments.length > 0) {
                msg.images = m.attachments.map(a => a.dataUrl);
            }
            return msg;
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