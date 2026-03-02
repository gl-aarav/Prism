document.addEventListener('DOMContentLoaded', () => {
    // Safari/Chrome API compatibility
    const api = typeof browser !== 'undefined' ? browser : chrome;

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
    let pendingAttachments = [];

    // ── SLASH COMMANDS ──────────────────────────────────────
    let slashCommands = [
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

    const cmdDropdown = document.createElement('div');
    cmdDropdown.className = 'command-dropdown';
    cmdDropdown.style.display = 'none';
    document.querySelector('.input-bar').appendChild(cmdDropdown);

    let cmdSelectedIndex = 0;
    let cmdFiltered = [];

    function updateCommandDropdown() {
        const text = promptInput.value;
        const slashMatch = text.match(/^\/(\S*)$/);
        if (!slashMatch) {
            cmdDropdown.style.display = 'none';
            return;
        }
        const query = slashMatch[1].toLowerCase();
        cmdFiltered = slashCommands.filter(c => c.trigger.substring(1).startsWith(query));
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
            item.innerHTML = '<span class="command-trigger">' + cmd.trigger + '</span><span class="command-desc">' + cmd.expansion + '</span>';
            item.addEventListener('mousedown', e => {
                e.preventDefault();
                e.stopPropagation();
            });
            item.addEventListener('click', e => {
                e.preventDefault();
                e.stopPropagation();
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
    let mentionedTabs = [];

    async function updateTabDropdown() {
        const text = promptInput.value;
        const cursorPos = promptInput.selectionStart;
        const textBeforeCursor = text.substring(0, cursorPos);
        const atMatch = textBeforeCursor.match(/(^|[\s])@([^\s]*)$/);
        if (!atMatch) {
            tabDropdown.style.display = 'none';
            return;
        }
        const query = atMatch[2].toLowerCase();
        try {
            const tabs = await api.tabs.query({});
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
                e.stopPropagation();
            });
            item.addEventListener('click', e => {
                e.preventDefault();
                e.stopPropagation();
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
            promptInput.value = before + after;
            promptInput.selectionStart = promptInput.selectionEnd = before.length;
            mentionedTabs.push({ title: tab.title, url: tab.url, tabId: tab.id, favIconUrl: tab.favIconUrl || '' });
        }
        tabDropdown.style.display = 'none';
        promptInput.style.height = 'auto';
        promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
        renderMentionPills();
        updateSendBtn();
        promptInput.focus();
    }

    const mentionPreview = document.getElementById('mentionPreview');

    function renderMentionPills() {
        mentionPreview.innerHTML = '';
        if (mentionedTabs.length === 0) {
            mentionPreview.style.display = 'none';
            return;
        }
        mentionPreview.style.display = 'flex';
        mentionedTabs.forEach((mt, i) => {
            const pill = document.createElement('span');
            pill.className = 'mention-pill';
            const faviconHtml = mt.favIconUrl ? '<img class="mention-pill-favicon" src="' + mt.favIconUrl + '" onerror="this.style.display=\'none\'">' : '';
            const titleText = (mt.title || '').substring(0, 40);
            pill.innerHTML = faviconHtml +
                '<span class="mention-pill-title">' + titleText + '</span>' +
                '<button class="mention-pill-remove" title="Remove">&times;</button>';
            pill.querySelector('.mention-pill-remove').addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                mentionedTabs.splice(i, 1);
                renderMentionPills();
                updateSendBtn();
            });
            mentionPreview.appendChild(pill);
        });
    }

    // Auto-resize textarea
    promptInput.addEventListener('input', () => {
        promptInput.style.height = 'auto';
        promptInput.style.height = Math.min(promptInput.scrollHeight, 140) + 'px';
        updateSendBtn();
        updateCommandDropdown();
        updateTabDropdown();
    });

    function updateSendBtn() {
        sendBtn.disabled = isGenerating ? false : (promptInput.value.trim() === '' && pendingAttachments.length === 0 && mentionedTabs.length === 0);
    }

    // ── ATTACHMENT HANDLING ──────────────────────────────────
    attachBtn.addEventListener('click', () => fileInput.click());

    fileInput.addEventListener('change', () => {
        for (const file of fileInput.files) addAttachment(file);
        fileInput.value = '';
    });

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
        if (pendingAttachments.length >= 5) return;
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

        if (models.length === 0) {
            modelSelect.innerHTML = '<option value="">Cannot connect to Prism</option>';
            modelName.textContent = 'Cannot connect';
            return;
        }

        modelSelect.innerHTML = '';
        const groups = { 'Apple': [], 'Gemini': [], 'Ollama': [], 'Copilot': [], 'NVIDIA': [], 'Other': [] };
        models.forEach(m => {
            let name = m.name;
            let group = 'Other';
            if (name.startsWith('Apple')) { group = 'Apple'; }
            else if (m.id.startsWith('gemini:')) { group = 'Gemini'; name = name.replace(/^Gemini:\s*/, ''); }
            else if (m.id.startsWith('ollama:')) { group = 'Ollama'; name = name.replace(/^Ollama:\s*/, ''); }
            else if (m.id.startsWith('copilot:')) {
                group = 'Copilot';
                if (name.startsWith('Copilot: ')) {
                    name = name.substring(9);
                } else if (name.startsWith('Copilot (')) {
                    name = name.substring(8);
                }
            }
            else if (m.id.startsWith('nvidia:')) {
                group = 'NVIDIA';
                name = name.replace(/^NVIDIA:\s*/, '');
            }
            groups[group].push({ id: m.id, name });
        });

        ['Apple', 'Copilot', 'Gemini', 'NVIDIA', 'Ollama', 'Other'].forEach(groupName => {
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

        // Safari supports both browser.storage and chrome.storage
        const storage = api.storage && api.storage.local ? api.storage.local : null;
        if (storage) {
            storage.get(['lastModelId'], result => {
                if (result && result.lastModelId && Array.from(modelSelect.options).some(o => o.value === result.lastModelId)) {
                    modelSelect.value = result.lastModelId;
                }
                updateModelDisplay();
                updateModelCapabilities();
            });
        } else {
            // Fallback: use localStorage
            const lastModel = localStorage.getItem('lastModelId');
            if (lastModel && Array.from(modelSelect.options).some(o => o.value === lastModel)) {
                modelSelect.value = lastModel;
            }
            updateModelDisplay();
            updateModelCapabilities();
        }
    }

    async function fetchCommands() {
        try {
            const res = await fetch('http://localhost:8080/api/commands');
            if (res.ok) {
                const cmds = await res.json();
                if (Array.isArray(cmds) && cmds.length > 0) {
                    slashCommands = cmds.map(c => ({
                        trigger: c.trigger,
                        expansion: c.expansion,
                    }));
                }
            }
        } catch (e) {
            console.warn('Could not fetch commands from Prism, using defaults.');
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
        if (modelId.startsWith('nvidia:'))
            return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="url(#headerGrad)" stroke-width="2"><path d="M13 3v7h7M3 11v10h18V11H3zM7 14h2v4H7zM11 14h2v4h-2zM15 14h2v4h-2z"/></svg>';
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
        webSearchBtn.style.display = modelSelect.value.startsWith('ollama:') ? 'flex' : 'none';
        if (!modelSelect.value.startsWith('ollama:') && includeWebSearch) {
            setWebSearchState(false);
        }

        const modelId = modelSelect.value.toLowerCase();
        const thinkingDropdown = document.getElementById('thinkingDropdown');
        if (!thinkingDropdown) return;

        if (modelId.startsWith('copilot:') || modelId.startsWith('apple:') || modelId.startsWith('nvidia:')) {
            thinkingBtn.style.display = 'none';
            thinkingDropdownOpen = false;
            thinkingDropdown.style.display = 'none';
        } else {
            thinkingBtn.style.display = 'flex';

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
                    thinkingBtn.style.display = 'none';
                    thinkingDropdownOpen = false;
                    thinkingDropdown.style.display = 'none';
                    return;
                }
            } else {
                levels = [
                    { value: 'low', label: 'Low' },
                    { value: 'medium', label: 'Medium' },
                    { value: 'high', label: 'High' }
                ];
            }

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
            if (!foundActive && levels.length > 0) {
                thinkingLevel = levels[0].value;
                thinkingDropdown.querySelector('.thinking-level-option').classList.add('active');
            }
        }
    }

    modelSelect.addEventListener('change', () => {
        const storage = api.storage && api.storage.local ? api.storage.local : null;
        if (storage) {
            storage.set({ lastModelId: modelSelect.value });
        } else {
            localStorage.setItem('lastModelId', modelSelect.value);
        }
        updateModelDisplay();
        updateModelCapabilities();
    });

    fetchModels();
    fetchCommands();
    updateContextLabel();

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
    const contextToggle = document.getElementById('contextToggle');

    function setContextState(enabled) {
        includeContext = enabled;
        if (enabled) {
            contextToggle.style.display = 'flex';
            contextToggle.classList.remove('disabled');
            updateContextLabel();
        } else {
            contextToggle.style.display = 'none';
        }
        updatePromptPlaceholder();
    }

    async function updateContextLabel() {
        try {
            const tabs = await api.tabs.query({ active: true, currentWindow: true });
            const tab = tabs[0];
            if (tab && tab.title) {
                const name = tab.title.length > 30 ? tab.title.substring(0, 30) + '\u2026' : tab.title;
                contextToggleText.textContent = name;
            } else {
                contextToggleText.textContent = 'Include website';
            }
        } catch (e) {
            contextToggleText.textContent = 'Include website';
        }
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

    contextCloseBtn.addEventListener('click', e => { e.stopPropagation(); setContextState(false); });
    contextToggle.addEventListener('click', () => { });
    webSearchBtn.addEventListener('click', () => setWebSearchState(!includeWebSearch));

    // ── THINKING LEVEL ──────────────────────────────────────
    const thinkingDropdown = document.getElementById('thinkingDropdown');

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
        agentBrowserBtn.title = agentBrowserEnabled ? 'Agent Browser: ON \u2014 AI can interact with pages' : 'Agent Browser Control';
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
                api.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve);
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

    document.addEventListener('keydown', e => {
        if (document.activeElement !== promptInput) return;
        const cmdVisible = cmdDropdown.style.display !== 'none' && cmdFiltered.length > 0;
        const tabVisible = tabDropdown.style.display !== 'none' && tabFiltered.length > 0;

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

    // ── SEND MESSAGE (with full history context) ────────────
    async function sendMessage(text, isRegenerate) {
        const modelId = modelSelect.value;
        if ((!text && pendingAttachments.length === 0) || !modelId) return;

        const attachments = [...pendingAttachments];
        pendingAttachments = [];
        renderAttachmentPreviews();

        promptInput.value = '';
        promptInput.style.height = 'auto';
        setGeneratingState(true);

        const es = document.getElementById('emptyState');
        if (es) es.style.display = 'none';

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
                const tabs = await api.tabs.query({ active: true, currentWindow: true });
                const tab = tabs[0];
                if (tab && tab.url && !tab.url.startsWith('safari-web-extension://') && !tab.url.startsWith('about:')) {
                    const response = await new Promise(resolve => {
                        api.tabs.sendMessage(tab.id, { action: 'getPageContext' }, res => {
                            if (api.runtime.lastError) {
                                api.scripting.executeScript(
                                    { target: { tabId: tab.id }, files: ['content.js'] },
                                    () => api.tabs.sendMessage(tab.id, { action: 'getPageContext' }, resolve)
                                );
                            } else { resolve(res); }
                        });
                    });
                    if (response && response.content) pageContext = response.content;
                }
            } catch (err) { console.warn('Could not get page text', err); }
        }

        // Build messages array
        let messagesForApi = chatHistory.map(m => {
            const msg = { role: m.role, content: m.content };
            if (m.attachments && m.attachments.length > 0) {
                msg.images = m.attachments.map(a => a.dataUrl);
            }
            return msg;
        });

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

        // Fetch @mentioned tab content
        if (mentionedTabs.length > 0) {
            let tabContexts = [];
            for (const mt of mentionedTabs) {
                try {
                    const tabContent = await new Promise(resolve => {
                        api.tabs.sendMessage(mt.tabId, { action: 'getPageContext' }, res => {
                            if (api.runtime.lastError) {
                                api.scripting.executeScript(
                                    { target: { tabId: mt.tabId }, files: ['content.js'] },
                                    () => api.tabs.sendMessage(mt.tabId, { action: 'getPageContext' }, r => resolve(r))
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
            renderMentionPills();
        }

        // Inject agent browser system prompt
        if (agentBrowserEnabled) {
            messagesForApi.unshift({
                role: 'system',
                content: 'You are a powerful autonomous browser agent. You control the browser by outputting JSON action blocks wrapped in ```agent-action markers. After actions execute, you receive results and can take more actions. You can plan, execute multi-step workflows, recover from errors, and make intelligent decisions.\n\n' +
                    '## PLANNING RULES:\n' +
                    '1. Before acting, briefly plan your approach (2-3 sentences max)\n' +
                    '2. Break complex goals into small, verifiable steps\n' +
                    '3. After each action, check the result before proceeding\n' +
                    '4. If an action fails, try alternative selectors or approaches — do NOT repeat the same failed action\n' +
                    '5. Use getElements or scan to discover page layout when unsure what to click\n' +
                    '6. Use getPageState to check for blockers (CAPTCHAs, overlays, login walls) before interacting\n' +
                    '7. Use dismissPopups to remove cookie banners and overlays blocking the page\n' +
                    '8. When looping through items (e.g. search results), track progress to avoid repeating work\n\n' +
                    '## Page Interaction:\n' +
                    '- {"type":"click","selector":"CSS or text"} - Click element\n' +
                    '- {"type":"doubleClick","selector":"CSS or text"} - Double-click element\n' +
                    '- {"type":"rightClick","selector":"CSS or text"} - Right-click (context menu)\n' +
                    '- {"type":"clickAtPosition","x":100,"y":200} - Click at viewport coordinates (for dynamic UIs where selectors fail)\n' +
                    '- {"type":"type","selector":"CSS or text","text":"...","clear":true} - Type into input/editor. Works with Google Docs, Notion, contentEditable, and standard inputs. Set clear:false to append.\n' +
                    '- {"type":"pressKey","key":"Enter","selector":"optional","ctrlKey":false,"shiftKey":false,"altKey":false,"metaKey":false} - Press keyboard key with optional modifiers. Use metaKey for Cmd on Mac.\n' +
                    '- {"type":"clearInput","selector":"CSS or text"} - Clear an input field or rich editor\n' +
                    '- {"type":"paste","selector":"CSS or text","text":"..."} - Paste text (triggers paste event for framework compatibility)\n' +
                    '- {"type":"setValue","selector":"CSS","value":"..."} - Set input value directly (React-compatible native setter)\n' +
                    '- {"type":"select","selector":"CSS","value":"..."} - Choose dropdown option\n' +
                    '- {"type":"getSelectOptions","selector":"CSS"} - List all options in a dropdown\n' +
                    '- {"type":"scroll","direction":"up|down","amount":300} - Scroll page\n' +
                    '- {"type":"scrollTo","selector":"CSS or text"} - Scroll element into view\n' +
                    '- {"type":"scrollToPosition","position":"top|bottom|50"} - Scroll to top, bottom, or percentage\n' +
                    '- {"type":"hover","selector":"CSS or text"} - Hover over element\n' +
                    '- {"type":"focus","selector":"CSS or text"} - Focus element\n' +
                    '- {"type":"drag","selector":"CSS","dx":100,"dy":0} - Drag element\n' +
                    '- {"type":"toggleCheckbox","selector":"CSS"} - Toggle checkbox/radio\n' +
                    '- {"type":"fillForm","fields":[{"selector":"#id","value":"..."}]} - Fill multiple form fields\n' +
                    '- {"type":"selectText","selector":"CSS"} - Select all text inside an element\n' +
                    '- {"type":"removeElement","selector":"CSS"} - Remove an element from the page (e.g. ad, overlay)\n\n' +
                    '## Page Analysis:\n' +
                    '- {"type":"getElements"} - List interactive elements on page\n' +
                    '- {"type":"getElementInfo","selector":"CSS or text"} - Detailed info about one element (tag, rect, attributes, visibility)\n' +
                    '- {"type":"extractText","selector":"CSS"} - Get text from elements\n' +
                    '- {"type":"extractLinks"} - Get all page links\n' +
                    '- {"type":"extractTable","selector":"table"} - Extract table as JSON\n' +
                    '- {"type":"extractImages"} - Get all images (src, alt, dimensions)\n' +
                    '- {"type":"getFormValues","selector":"form"} - Read all form field values\n' +
                    '- {"type":"getStyles","selector":"CSS","properties":["display","color"]} - Get computed CSS styles\n' +
                    '- {"type":"getAttribute","selector":"CSS","attribute":"href"} - Get attribute\n' +
                    '- {"type":"readSelection"} - Get user-selected text\n' +
                    '- {"type":"readPageMeta"} - Get page metadata (title, description, etc.)\n' +
                    '- {"type":"getStructuredData"} - Extract JSON-LD, OpenGraph, Twitter Cards, microdata\n' +
                    '- {"type":"getPageState"} - Check page state: loading, forms, CAPTCHAs, overlays, errors\n' +
                    '- {"type":"summarizePage"} - Get structured page summary (headings, content, nav, counts)\n' +
                    '- {"type":"findByContent","query":"search text"} - Find elements by text content with positions\n' +
                    '- {"type":"highlight","selector":"CSS","color":"yellow"} - Highlight elements\n' +
                    '- {"type":"scan"} - Take a screenshot of the page + get page dimensions.\n\n' +
                    '## Timing & Synchronization:\n' +
                    '- {"type":"wait","seconds":2} - Wait/pause for N seconds (max 30)\n' +
                    '- {"type":"waitFor","selector":"CSS","timeout":5000} - Wait for element to appear\n' +
                    '- {"type":"waitForNavigation","timeout":10000} - Wait for page to finish loading after navigation\n' +
                    '- {"type":"dismissPopups"} - Auto-dismiss cookie banners, modals, and overlays blocking the page\n\n' +
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
                    '- {"type":"moveTab","tabId":1,"index":0} - Move tab to position\n' +
                    '- {"type":"captureTab"} - Screenshot visible tab\n' +
                    '- {"type":"createBookmark","title":"...","url":"..."} - Add bookmark\n' +
                    '- {"type":"searchBookmarks","query":"..."} - Search bookmarks\n' +
                    '- {"type":"zoomTab","direction":"in|out"} or {"type":"zoomTab","zoom":1.5} - Zoom in/out\n' +
                    '- {"type":"muteTab"} - Mute/unmute current tab\n\n' +
                    '## Windows:\n' +
                    '- {"type":"createWindow","url":"https://...","incognito":false} - Open new window\n' +
                    '- {"type":"getWindows"} - List all windows\n' +
                    '- {"type":"closeWindow","windowId":1} - Close a window\n\n' +
                    '## File & Download Management:\n' +
                    '- {"type":"downloadFile","url":"https://...","filename":"optional.pdf"} - Download a file\n' +
                    '- {"type":"getDownloads"} - List recent downloads\n\n' +
                    '## Cookies & Sessions:\n' +
                    '- {"type":"getCookies","url":"https://..."} - List cookies for a URL\n' +
                    '- {"type":"setCookie","url":"...","name":"...","value":"..."} - Set a cookie\n' +
                    '- {"type":"deleteCookies","url":"...","name":"..."} - Delete a specific cookie\n\n' +
                    '## History:\n' +
                    '- {"type":"getHistory","query":"optional search","maxResults":20} - Search browser history\n\n' +
                    '## Web & Information:\n' +
                    '- {"type":"webSearch","query":"..."} - Search DuckDuckGo\n' +
                    '- {"type":"fetchUrl","url":"https://..."} - Read any webpage content\n' +
                    '- {"type":"wikipedia","title":"..."} - Wikipedia article summary\n' +
                    '- {"type":"weather","location":"City"} - Current weather\n' +
                    '- {"type":"translate","text":"...","from":"en","to":"es"} - Translate text\n' +
                    '- {"type":"dictionary","word":"..."} - Word definition\n\n' +
                    '## SELF-HEALING SELECTORS:\n' +
                    'The agent automatically tries multiple strategies to find elements:\n' +
                    '1. CSS selector → 2. XPath → 3. aria-label → 4. Text content match\n' +
                    'You can use any of these as the "selector" value:\n' +
                    '- CSS: "#myId", ".myClass", "button[type=submit]"\n' +
                    '- Text: "Submit", "Sign In", "Add to Cart" (matches element text)\n' +
                    '- text= prefix: "text=Continue" (explicit text search)\n' +
                    '- XPath: "//button[contains(text(),\'Submit\')]"\n' +
                    'If a selector fails, try text content instead. Use getElements or findByContent to discover actual selectors.\n\n' +
                    '## Tips for Rich Text Editors (Google Docs, Notion, etc.):\n' +
                    '- For Google Docs: click the editing area first (e.g. ".kix-appview-editor"), then use type with that selector\n' +
                    '- Use focus to ensure the editor is active before typing\n' +
                    '- Use pressKey for keyboard shortcuts (Enter, Tab, Backspace, Escape, arrow keys, Cmd+A, etc.)\n' +
                    '- The type action uses document.execCommand("insertText") for contentEditable elements, which works with most rich editors\n\n' +
                    '## MULTI-STEP WORKFLOW TIPS:\n' +
                    '- For multi-page workflows (login → navigate → action), use waitForNavigation after clicking links\n' +
                    '- For cross-site data transfer, extract data from one tab, switchTab, then paste/type into another\n' +
                    '- For bulk operations, use getElements to find all targets, then loop through them\n' +
                    '- If the page has dynamic content (React, single-page apps), use waitFor to ensure elements load\n' +
                    '- Use getPageState to detect CAPTCHAs, login walls, and errors before interacting\n' +
                    '- Use dismissPopups early to clear cookie banners and modal overlays\n\n' +
                    'Output: ```agent-action\n{"type":"..."}\n```\n' +
                    'CRITICAL: You MUST wrap every action JSON in ```agent-action fences. Never output bare JSON outside fences. Actions without ```agent-action will NOT execute.\n' +
                    'You may output multiple action blocks. Explain each step briefly. When done, give final summary without action blocks.'
            });
        }

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
                    } catch (e) { }
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

            // Agentic loop
            if (agentBrowserEnabled && fullContent) {
                let loopContent = fullContent;
                const MAX_AGENT_LOOPS = 10;
                agentStepCount = 0;

                const agentBanner = document.createElement('div');
                agentBanner.className = 'agent-progress-banner';
                agentBanner.innerHTML = '<div class="agent-progress-dot"></div><span>Agent is working\u2026</span>';
                chatContainer.appendChild(agentBanner);
                scrollToBottom();

                for (let loop = 0; loop < MAX_AGENT_LOOPS; loop++) {
                    if (!abortController || abortController.signal.aborted) break;

                    agentBanner.querySelector('span').textContent = 'Agent is working\u2026 (loop ' + (loop + 1) + '/' + MAX_AGENT_LOOPS + ')';

                    let actions = [];
                    const actionRegex = /```agent-action\s*\n([\s\S]*?)```/g;
                    let match;
                    while ((match = actionRegex.exec(loopContent)) !== null) {
                        try { actions.push(JSON.parse(match[1].trim())); } catch (e) { }
                    }
                    if (actions.length === 0) {
                        const bareRegex = /(?:^|\n)\s*(\{"type"\s*:\s*"[^"]+?"[^}]*\})/g;
                        while ((match = bareRegex.exec(loopContent)) !== null) {
                            try {
                                const parsed = JSON.parse(match[1].trim());
                                if (parsed.type) actions.push(parsed);
                            } catch (e) { }
                        }
                    }

                    if (actions.length === 0) break;

                    let results = [];
                    for (const action of actions) {
                        appendAgentAction(null, action);
                        const result = await executeAgentAction(action);
                        results.push({ type: action.type, result: result || {} });

                        if ((action.type === 'captureTab' || action.type === 'scan') && result?.ok && result?.image) {
                            appendAgentScreenshot(result.image);
                        }
                    }

                    let screenshotImages = [];
                    const resultText = results.map(r => {
                        const res = r.result;
                        if ((r.type === 'captureTab' || r.type === 'scan') && res.ok && res.image) {
                            screenshotImages.push(res.image);
                        }
                        let info = res.summary || res.error || '';
                        for (const key of ['elements', 'tabs', 'data', 'text', 'links', 'pageInfo', 'meta', 'content', 'definition', 'weather', 'translation', 'bookmarks', 'value', 'state', 'info', 'images', 'matches', 'styles', 'options', 'history', 'downloads', 'cookies', 'windows']) {
                            if (res[key]) {
                                const val = typeof res[key] === 'string' ? res[key] : JSON.stringify(res[key]);
                                info += '\n' + val.substring(0, 3000);
                            }
                        }
                        return `[${r.type}] ${res.ok ? 'OK' : 'FAILED'}: ${info}`;
                    }).join('\n\n');

                    messagesForApi.push({ role: 'assistant', content: loopContent });
                    const resultMsg = {
                        role: 'user',
                        content: '[Agent Action Results]:\n' + resultText + '\n\nContinue with the task. If done, provide a final summary without any agent-action blocks.'
                    };
                    if (screenshotImages.length > 0) {
                        resultMsg.images = screenshotImages;
                    }
                    messagesForApi.push(resultMsg);

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

                agentBanner.remove();

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

        const contentDiv = document.createElement('div');
        contentDiv.className = 'assistant-message';
        contentDiv.innerHTML = '<div class="thinking-indicator"><span class="working-orb"></span><span class="working-text">Working\u2026</span></div>';

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
            cleaned = cleaned.replace(/(?:^|\n)\s*(\{"type"\s*:\s*"[^"]+?"[^}]*\})/g, (match, jsonStr) => {
                try {
                    const action = JSON.parse(jsonStr.trim());
                    if (action.type) return '\n' + formatAgentActionInline(action) + '\n';
                } catch (e) { }
                return match;
            });
        }
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
            case 'click': return { icon: '\uD83D\uDC46', label: 'Clicked ' + sel };
            case 'type': return { icon: '\u2328\uFE0F', label: 'Typed "' + (action.text || '').substring(0, 40) + '"' + (sel ? ' into ' + sel : '') };
            case 'select': return { icon: '\uD83D\uDCCB', label: 'Selected "' + (action.value || '') + '"' + (sel ? ' in ' + sel : '') };
            case 'scroll': return { icon: '\uD83D\uDCDC', label: 'Scrolled ' + (action.direction || 'down') + ' ' + (action.amount || 300) + 'px' };
            case 'hover': return { icon: '\uD83C\uDFAF', label: 'Hovered over ' + sel };
            case 'drag': return { icon: '\u270B', label: 'Dragged ' + sel + ' by (' + (action.dx || 0) + ', ' + (action.dy || 0) + ')' };
            case 'toggleCheckbox': return { icon: '\u2611\uFE0F', label: 'Toggled checkbox ' + sel };
            case 'fillForm': return { icon: '\uD83D\uDCDD', label: 'Filled form with ' + (action.fields ? action.fields.length : 0) + ' fields' };
            case 'getElements': return { icon: '\uD83D\uDD0D', label: 'Scanned page elements' };
            case 'extractText': return { icon: '\uD83D\uDCC4', label: 'Extracted text from ' + sel };
            case 'extractLinks': return { icon: '\uD83D\uDD17', label: 'Extracted all links' };
            case 'extractTable': return { icon: '\uD83D\uDCCA', label: 'Extracted table data' };
            case 'highlight': return { icon: '\uD83D\uDD8D\uFE0F', label: 'Highlighted ' + sel };
            case 'wait': return { icon: '\u23F1\uFE0F', label: 'Waited ' + (action.seconds || 0) + ' second' + ((action.seconds || 0) !== 1 ? 's' : '') };
            case 'waitFor': return { icon: '\u23F3', label: 'Waiting for ' + sel };
            case 'getAttribute': return { icon: '\uD83C\uDFF7\uFE0F', label: 'Read attribute "' + (action.attribute || '') + '" from ' + sel };
            case 'readSelection': return { icon: '\u2702\uFE0F', label: 'Read selected text' };
            case 'readPageMeta': return { icon: '\uD83D\uDCD1', label: 'Read page metadata' };
            case 'scan': return { icon: '\uD83D\uDCF7', label: 'Took screenshot & scanned page' };
            case 'navigate': return { icon: '\uD83C\uDF10', label: 'Navigated to ' + safeHost(action.url) };
            case 'openTab': return { icon: '\u2795', label: 'Opened new tab' + (action.url ? ': ' + safeHost(action.url) : '') };
            case 'closeTab': return { icon: '\u2716\uFE0F', label: 'Closed tab' };
            case 'switchTab': return { icon: '\uD83D\uDD00', label: 'Switched to tab ' + (action.tabId || '') };
            case 'getTabs': return { icon: '\uD83D\uDCD1', label: 'Listed all tabs' };
            case 'goBack': return { icon: '\u2B05\uFE0F', label: 'Went back' };
            case 'goForward': return { icon: '\u27A1\uFE0F', label: 'Went forward' };
            case 'reloadTab': return { icon: '\uD83D\uDD04', label: 'Reloaded page' };
            case 'duplicateTab': return { icon: '\uD83D\uDCCB', label: 'Duplicated tab' };
            case 'pinTab': return { icon: '\uD83D\uDCCC', label: 'Pinned tab' };
            case 'captureTab': return { icon: '\uD83D\uDCF8', label: 'Took screenshot' };
            case 'createBookmark': return { icon: '\uD83D\uDD16', label: 'Bookmarked "' + (action.title || '') + '"' };
            case 'searchBookmarks': return { icon: '\uD83D\uDD0D', label: 'Searched bookmarks for "' + (action.query || '') + '"' };
            case 'webSearch': return { icon: '\uD83C\uDF0D', label: 'Searched web for "' + (action.query || '').substring(0, 40) + '"' };
            case 'fetchUrl': return { icon: '\uD83D\uDCE5', label: 'Fetched ' + safeHost(action.url) };
            case 'wikipedia': return { icon: '\uD83D\uDCDA', label: 'Looked up "' + (action.title || '') + '" on Wikipedia' };
            case 'weather': return { icon: '\uD83C\uDF24\uFE0F', label: 'Checked weather in ' + (action.location || '') };
            case 'translate': return { icon: '\uD83C\uDF10', label: 'Translated text' + (action.to ? ' to ' + action.to : '') };
            case 'dictionary': return { icon: '\uD83D\uDCD6', label: 'Looked up "' + (action.word || '') + '"' };
            case 'doubleClick': return { icon: '\uD83D\uDC46', label: 'Double-clicked ' + sel };
            case 'rightClick': return { icon: '\uD83D\uDC46', label: 'Right-clicked ' + sel };
            case 'pressKey': return { icon: '\u2328\uFE0F', label: 'Pressed ' + (action.key || '') + (action.metaKey ? ' (⌘)' : '') + (action.ctrlKey ? ' (Ctrl)' : '') };
            case 'clearInput': return { icon: '\uD83E\uDDF9', label: 'Cleared input ' + sel };
            case 'scrollTo': return { icon: '\uD83D\uDCDC', label: 'Scrolled to ' + sel };
            case 'focus': return { icon: '\uD83C\uDFAF', label: 'Focused ' + sel };
            case 'selectText': return { icon: '\u2702\uFE0F', label: 'Selected text in ' + sel };
            case 'getFormValues': return { icon: '\uD83D\uDCCB', label: 'Read form values' };
            case 'getStyles': return { icon: '\uD83C\uDFA8', label: 'Read styles from ' + sel };
            case 'clickAtPosition': return { icon: '\uD83D\uDC46', label: 'Clicked at (' + (action.x || 0) + ', ' + (action.y || 0) + ')' };
            case 'paste': return { icon: '\uD83D\uDCCB', label: 'Pasted text into ' + sel };
            case 'setValue': return { icon: '\u270F\uFE0F', label: 'Set value of ' + sel };
            case 'getSelectOptions': return { icon: '\uD83D\uDCCB', label: 'Listed options in ' + sel };
            case 'scrollToPosition': return { icon: '\uD83D\uDCDC', label: 'Scrolled to ' + (action.position || 'position') };
            case 'removeElement': return { icon: '\uD83D\uDDD1\uFE0F', label: 'Removed element ' + sel };
            case 'getElementInfo': return { icon: '\uD83D\uDD0D', label: 'Inspected element ' + sel };
            case 'extractImages': return { icon: '\uD83D\uDDBC\uFE0F', label: 'Extracted all images' };
            case 'getStructuredData': return { icon: '\uD83D\uDCCA', label: 'Extracted structured data' };
            case 'getPageState': return { icon: '\uD83D\uDCCB', label: 'Checked page state' };
            case 'summarizePage': return { icon: '\uD83D\uDCC4', label: 'Summarized page' };
            case 'findByContent': return { icon: '\uD83D\uDD0D', label: 'Found elements matching "' + (action.query || '').substring(0, 30) + '"' };
            case 'dismissPopups': return { icon: '\u274C', label: 'Dismissed popups/overlays' };
            case 'waitForNavigation': return { icon: '\u23F3', label: 'Waited for page load' };
            case 'moveTab': return { icon: '\u21C4', label: 'Moved tab to index ' + (action.index || 0) };
            case 'zoomTab': return { icon: '\uD83D\uDD0D', label: 'Zoomed ' + (action.direction || action.zoom || '') };
            case 'muteTab': return { icon: '\uD83D\uDD07', label: 'Toggled tab mute' };
            case 'createWindow': return { icon: '\uD83D\uDDA5\uFE0F', label: 'Opened new window' + (action.incognito ? ' (incognito)' : '') };
            case 'getWindows': return { icon: '\uD83D\uDDA5\uFE0F', label: 'Listed all windows' };
            case 'closeWindow': return { icon: '\u2716\uFE0F', label: 'Closed window ' + (action.windowId || '') };
            case 'downloadFile': return { icon: '\u2B07\uFE0F', label: 'Downloaded ' + (action.filename || action.url || '').substring(0, 30) };
            case 'getDownloads': return { icon: '\uD83D\uDCC2', label: 'Listed recent downloads' };
            case 'getCookies': return { icon: '\uD83C\uDF6A', label: 'Listed cookies for ' + (action.url ? safeHost(action.url) : 'page') };
            case 'setCookie': return { icon: '\uD83C\uDF6A', label: 'Set cookie "' + (action.name || '') + '"' };
            case 'deleteCookies': return { icon: '\uD83C\uDF6A', label: 'Deleted cookie "' + (action.name || '') + '"' };
            case 'getHistory': return { icon: '\uD83D\uDCDC', label: 'Searched history' + (action.query ? ' for "' + action.query.substring(0, 20) + '"' : '') };
            default: return { icon: '\u26A1', label: action.type };
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
    let agentActions = [];
    let agentStepCount = 0;

    async function executeAgentAction(action) {
        let result;
        try {
            const tabs = await api.tabs.query({ active: true, currentWindow: true });
            const tab = tabs[0];

            switch (action.type) {
                case 'click':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentClick', selector: action.selector });
                    break;
                case 'type':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentType', selector: action.selector, text: action.text, clear: action.clear });
                    break;
                case 'pressKey':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentPressKey', selector: action.selector, key: action.key, ctrlKey: action.ctrlKey, shiftKey: action.shiftKey, altKey: action.altKey, metaKey: action.metaKey });
                    break;
                case 'clearInput':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentClearInput', selector: action.selector });
                    break;
                case 'doubleClick':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentDoubleClick', selector: action.selector });
                    break;
                case 'rightClick':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentRightClick', selector: action.selector });
                    break;
                case 'focus':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentFocusElement', selector: action.selector });
                    break;
                case 'selectText':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentSelectText', selector: action.selector });
                    break;
                case 'scrollTo':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentScrollTo', selector: action.selector });
                    break;
                case 'getFormValues':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetFormValues', selector: action.selector });
                    break;
                case 'getStyles':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetStyles', selector: action.selector, properties: action.properties });
                    break;
                case 'select':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentSelect', selector: action.selector, value: action.value });
                    break;
                case 'scroll':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentScroll', direction: action.direction, amount: action.amount });
                    break;
                case 'hover':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentHover', selector: action.selector });
                    break;
                case 'drag':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentDrag', selector: action.selector, dx: action.dx, dy: action.dy });
                    break;
                case 'toggleCheckbox':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentToggleCheckbox', selector: action.selector });
                    break;
                case 'fillForm':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentFillForm', fields: action.fields });
                    break;
                case 'getElements':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetElements' });
                    break;
                case 'extractText':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentExtractText', selector: action.selector });
                    break;
                case 'extractLinks':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentExtractLinks' });
                    break;
                case 'extractTable':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentExtractTable', selector: action.selector });
                    break;
                case 'highlight':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentHighlight', selector: action.selector, color: action.color });
                    break;
                case 'wait': {
                    const secs = Math.min(Math.max(Number(action.seconds) || 1, 0.1), 30);
                    await new Promise(resolve => setTimeout(resolve, secs * 1000));
                    result = { ok: true, summary: `Waited ${secs} second${secs !== 1 ? 's' : ''}` };
                    break;
                }
                case 'waitFor':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentWaitFor', selector: action.selector, timeout: action.timeout });
                    break;
                case 'getAttribute':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetAttribute', selector: action.selector, attribute: action.attribute });
                    break;
                case 'readSelection':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentReadSelection' });
                    break;
                case 'readPageMeta':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentReadPageMeta' });
                    break;
                case 'scan': {
                    const [scanScreenshot, scanPageInfo] = await Promise.all([
                        new Promise(resolve => api.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve)),
                        api.tabs.sendMessage(tab.id, { action: 'agentScreenshot' }).catch(() => ({}))
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
                        api.runtime.sendMessage({ action: 'agentOpenTab', url: action.url, active: action.active }, resolve);
                    });
                    break;
                case 'closeTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentCloseTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'switchTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentSwitchTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'getTabs':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGetTabs' }, resolve);
                    });
                    break;
                case 'navigate':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentNavigate', url: action.url }, resolve);
                    });
                    break;
                case 'goBack':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGoBack' }, resolve);
                    });
                    break;
                case 'goForward':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGoForward' }, resolve);
                    });
                    break;
                case 'reloadTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentReloadTab' }, resolve);
                    });
                    break;
                case 'duplicateTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentDuplicateTab' }, resolve);
                    });
                    break;
                case 'pinTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentPinTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'captureTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentCaptureTab' }, resolve);
                    });
                    break;
                case 'createBookmark':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentCreateBookmark', title: action.title, url: action.url }, resolve);
                    });
                    break;
                case 'searchBookmarks':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentSearchBookmarks', query: action.query }, resolve);
                    });
                    break;

                // External API actions (via background)
                case 'webSearch':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentWebSearch', query: action.query }, resolve);
                    });
                    break;
                case 'fetchUrl':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentFetchUrl', url: action.url }, resolve);
                    });
                    break;
                case 'wikipedia':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentWikipedia', title: action.title }, resolve);
                    });
                    break;
                case 'weather':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentWeather', location: action.location }, resolve);
                    });
                    break;
                case 'translate':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentTranslate', text: action.text, from: action.from, to: action.to }, resolve);
                    });
                    break;
                case 'dictionary':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentDictionary', word: action.word }, resolve);
                    });
                    break;

                // New DOM-level actions
                case 'clickAtPosition':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentClickAtPosition', x: action.x, y: action.y });
                    break;
                case 'paste':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentPaste', selector: action.selector, text: action.text });
                    break;
                case 'setValue':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentSetValue', selector: action.selector, value: action.value });
                    break;
                case 'getSelectOptions':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetSelectOptions', selector: action.selector });
                    break;
                case 'scrollToPosition':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentScrollToPosition', position: action.position });
                    break;
                case 'removeElement':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentRemoveElement', selector: action.selector });
                    break;
                case 'getElementInfo':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetElementInfo', selector: action.selector });
                    break;
                case 'extractImages':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentExtractImages' });
                    break;
                case 'getStructuredData':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetStructuredData' });
                    break;
                case 'getPageState':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentGetPageState' });
                    break;
                case 'summarizePage':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentSummarizePage' });
                    break;
                case 'findByContent':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentFindByContent', query: action.query });
                    break;
                case 'dismissPopups':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentDismissPopups' });
                    break;
                case 'waitForNavigation':
                    result = await api.tabs.sendMessage(tab.id, { action: 'agentWaitForNavigation', timeout: action.timeout });
                    break;

                // New browser-level actions
                case 'moveTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentMoveTab', tabId: action.tabId, index: action.index, windowId: action.windowId }, resolve);
                    });
                    break;
                case 'zoomTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentZoomTab', direction: action.direction, zoom: action.zoom }, resolve);
                    });
                    break;
                case 'muteTab':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentMuteTab', tabId: action.tabId }, resolve);
                    });
                    break;
                case 'createWindow':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentCreateWindow', url: action.url, incognito: action.incognito }, resolve);
                    });
                    break;
                case 'getWindows':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGetWindows' }, resolve);
                    });
                    break;
                case 'closeWindow':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentCloseWindow', windowId: action.windowId }, resolve);
                    });
                    break;
                case 'downloadFile':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentDownloadFile', url: action.url, filename: action.filename }, resolve);
                    });
                    break;
                case 'getDownloads':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGetDownloads' }, resolve);
                    });
                    break;
                case 'getCookies':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGetCookies', url: action.url }, resolve);
                    });
                    break;
                case 'setCookie':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentSetCookie', url: action.url, name: action.name, value: action.value, domain: action.domain, path: action.path, secure: action.secure, httpOnly: action.httpOnly, expirationDate: action.expirationDate }, resolve);
                    });
                    break;
                case 'deleteCookies':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentDeleteCookies', url: action.url, name: action.name }, resolve);
                    });
                    break;
                case 'getHistory':
                    result = await new Promise(resolve => {
                        api.runtime.sendMessage({ action: 'agentGetHistory', query: action.query, maxResults: action.maxResults }, resolve);
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
        const desc = action ? getAgentActionDescription(action) : { icon: '\u26A1', label: summary };
        const wrapper = document.createElement('div');
        wrapper.className = 'agent-action-item';
        wrapper.innerHTML = '<span class="agent-step-num">' + agentStepCount + '</span>' +
            '<span class="agent-action-icon">' + desc.icon + '</span>' +
            '<span class="agent-action-text">' + escapeHtml(desc.label) + '</span>' +
            '<span class="agent-action-status">\u2713</span>';
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

        chatHistory.push({
            role: 'user',
            content: '[Agent Screenshot]',
            attachments: [{ dataUrl: dataUrl, mimeType: 'image/png', name: 'agent-screenshot.png' }]
        });
    }

    // ── FORWARD TO PRISM APP ────────────────────────────────
    async function forwardChatToApp() {
        if (chatHistory.length === 0) return;

        const cleanMessages = chatHistory.map(m => {
            let content = m.content;
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
