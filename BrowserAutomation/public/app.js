// Prism Browser Automation — Client App
(() => {
    'use strict';

    // State
    let ws = null;
    let selectedEngine = 'puppeteer';
    let currentTab = 'agent'; // 'agent' | 'chat'
    let currentAssistantMsg = null;
    let isStreaming = false;
    let autoRefreshTimer = null;
    let browserOpen = false;
    const AUTO_REFRESH_MS = 1500;

    // DOM refs
    const $ = (sel) => document.querySelector(sel);
    const connStatus = $('#connStatus');
    const modelSelect = $('#modelSelect');
    const urlInput = $('#urlInput');
    const selectorInput = $('#selectorInput');
    const typeInput = $('#typeInput');
    const keyInput = $('#keyInput');
    const chatInput = $('#chatInput');
    const chatMessages = $('#chatMessages');
    const logEntries = $('#logEntries');
    const screenshotImg = $('#screenshotImg');
    const screenshotView = $('#screenshotView');
    const pageTitle = $('#pageTitle');
    const pageUrl = $('#pageUrl');
    const btnAgentStop = $('#btnAgentStop');

    // ── WebSocket ──
    function connect() {
        const proto = location.protocol === 'https:' ? 'wss' : 'ws';
        ws = new WebSocket(`${proto}://${location.host}`);

        ws.onopen = () => {
            setConnected(true);
            log('Connected to server', 'info');
            loadModels();
        };

        ws.onclose = () => {
            setConnected(false);
            log('Disconnected', 'error');
            setTimeout(connect, 2000);
        };

        ws.onerror = () => setConnected(false);

        ws.onmessage = (evt) => {
            const msg = JSON.parse(evt.data);
            handleServerMsg(msg);
        };
    }

    function send(action, payload = {}) {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ action, payload }));
        }
    }

    function setConnected(connected) {
        const dot = connStatus.querySelector('.status-dot');
        const text = connStatus.querySelector('.status-text');
        dot.className = `status-dot ${connected ? 'connected' : 'disconnected'}`;
        text.textContent = connected ? 'Connected' : 'Disconnected';
    }

    // ── Server message handler ──
    function handleServerMsg(msg) {
        switch (msg.type) {
            case 'screenshot':
                screenshotImg.src = `data:image/png;base64,${msg.data}`;
                screenshotImg.style.display = 'block';
                screenshotView.querySelector('.placeholder-text')?.remove();
                break;

            case 'result':
                log(`${msg.action}: ${JSON.stringify(msg.data)}`, 'success');
                if (msg.data?.title !== undefined) pageTitle.textContent = msg.data.title || 'Untitled';
                if (msg.data?.url !== undefined) pageUrl.textContent = msg.data.url;
                if (msg.action === 'domTree') showDomTree(msg.data);
                if (msg.action === 'getTabs') showTabs(msg.data);
                if (msg.action === 'launch' && msg.data?.status === 'launched') {
                    startAutoRefresh();
                    // Auto-navigate to URL bar value so browser doesn't start blank
                    const startUrl = urlInput.value.trim();
                    if (startUrl) send('navigate', { url: startUrl });
                }
                if (msg.action === 'close') stopAutoRefresh();
                break;

            case 'chatChunk':
                appendAssistantChunk(msg.text);
                break;

            case 'chatThinking':
                appendThinking(msg.text);
                break;

            case 'chatDone':
                finishAssistantMsg();
                break;

            case 'agentStep':
                addChatMsg('system', msg.text);
                log(`Step ${msg.step}: ${msg.text}`, 'action');
                break;

            case 'agentChunk':
                appendAssistantChunk(msg.text);
                break;

            case 'agentAction':
                finishAssistantMsg();
                const actionText = JSON.stringify(msg.action);
                addChatMsg('system', `Step ${msg.step} → ${msg.action.action}`);
                log(`Action: ${actionText}`, 'action');
                break;

            case 'agentDone':
                finishAssistantMsg();
                addChatMsg('system', `✓ ${msg.summary}`);
                log(`Agent done: ${msg.summary}`, 'success');
                btnAgentStop.style.display = 'none';
                isStreaming = false;
                break;

            case 'agentStopped':
                finishAssistantMsg();
                addChatMsg('system', 'Agent stopped by user');
                btnAgentStop.style.display = 'none';
                isStreaming = false;
                break;

            case 'error':
                addChatMsg('error', msg.text);
                log(msg.text, 'error');
                isStreaming = false;
                btnAgentStop.style.display = 'none';
                break;
        }
    }

    // ── Models ──
    async function loadModels() {
        try {
            const res = await fetch('/api/models');
            const models = await res.json();
            modelSelect.innerHTML = '';
            if (models.length === 0) {
                modelSelect.innerHTML = '<option value="">No models (Prism running?)</option>';
                return;
            }
            // Group by provider
            const groups = {};
            for (const m of models) {
                const provider = m.name?.split(' - ')?.[0] || m.id.split(':')[0] || 'Other';
                if (!groups[provider]) groups[provider] = [];
                groups[provider].push(m);
            }
            for (const [provider, items] of Object.entries(groups)) {
                const optgroup = document.createElement('optgroup');
                optgroup.label = provider;
                for (const m of items) {
                    const opt = document.createElement('option');
                    opt.value = m.id;
                    opt.textContent = m.name || m.id;
                    optgroup.appendChild(opt);
                }
                modelSelect.appendChild(optgroup);
            }
            log(`Loaded ${models.length} models`, 'info');
        } catch {
            modelSelect.innerHTML = '<option value="">Failed to load models</option>';
        }
    }

    // ── Chat ──
    function renderMarkdown(text) {
        // Escape HTML first
        let html = escapeHtml(text);
        // Convert fenced code blocks: ```lang\n...\n```
        html = html.replace(/```(\w*)\n([\s\S]*?)```/g, (_, lang, code) => {
            const label = lang ? `<span class="code-lang">${lang}</span>` : '';
            return `<div class="code-block">${label}<pre><code>${code.trim()}</code></pre></div>`;
        });
        // Inline code
        html = html.replace(/`([^`]+)`/g, '<code class="inline-code">$1</code>');
        // Bold
        html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        return html;
    }

    function addChatMsg(role, text) {
        const div = document.createElement('div');
        div.className = `chat-msg ${role}`;
        if (role === 'assistant') {
            div.innerHTML = renderMarkdown(text);
        } else {
            div.textContent = text;
        }
        chatMessages.appendChild(div);
        chatMessages.scrollTop = chatMessages.scrollHeight;
        return div;
    }

    function appendAssistantChunk(text) {
        if (!currentAssistantMsg) {
            currentAssistantMsg = addChatMsg('assistant', '');
            currentAssistantMsg._rawText = '';
            isStreaming = true;
        }
        currentAssistantMsg._rawText += text;
        currentAssistantMsg.textContent += text;
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    function appendThinking(text) {
        // Find or create thinking message
        let thinkMsg = chatMessages.querySelector('.chat-msg.thinking:last-of-type');
        if (!thinkMsg) {
            thinkMsg = addChatMsg('thinking', '');
        }
        thinkMsg.textContent += text;
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    function finishAssistantMsg() {
        if (currentAssistantMsg && currentAssistantMsg._rawText) {
            currentAssistantMsg.innerHTML = renderMarkdown(currentAssistantMsg._rawText);
        }
        currentAssistantMsg = null;
        isStreaming = false;
    }

    function showDomTree(data) {
        if (data.title) pageTitle.textContent = data.title;
        if (data.url) pageUrl.textContent = data.url;

        let text = `DOM: ${data.url}\n${data.elements.length} interactive elements:\n\n`;
        for (const el of data.elements) {
            text += `[${el.index}] <${el.tag}> "${el.text}" — ${el.selector}\n`;
        }
        addChatMsg('system', text);
    }

    function showTabs(tabs) {
        const tabsList = $('#tabsList');
        tabsList.innerHTML = '';
        tabs.forEach((t, i) => {
            const div = document.createElement('div');
            div.className = 'tab-entry';
            div.textContent = `${i}: ${t.url.slice(0, 40)}`;
            div.onclick = () => send('switchTab', { index: i });
            tabsList.appendChild(div);
        });
    }

    // ── Logging ──
    function log(text, type = 'info') {
        const div = document.createElement('div');
        div.className = `log-entry log-${type}`;
        const time = new Date().toLocaleTimeString('en', { hour12: false });
        div.innerHTML = `<span class="log-time">${time}</span>${escapeHtml(text).slice(0, 200)}`;
        logEntries.prepend(div);
        // Keep max 100 entries
        while (logEntries.children.length > 100) logEntries.lastChild.remove();
    }

    function escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    // ── Event listeners ──
    // Engine toggle
    document.querySelectorAll('.engine-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.engine-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            selectedEngine = btn.dataset.engine;
        });
    });

    // Chat tabs
    document.querySelectorAll('.chat-tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.chat-tab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            currentTab = tab.dataset.tab;
        });
    });

    // Browser controls
    $('#btnLaunch').onclick = () => send('launch', { engine: selectedEngine });
    $('#btnClose').onclick = () => send('close');
    $('#btnNavigate').onclick = () => {
        const url = urlInput.value.trim();
        if (url) send('navigate', { url });
    };
    urlInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            const url = urlInput.value.trim();
            if (url) send('navigate', { url });
        }
    });

    // Quick actions
    document.querySelectorAll('.action-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const action = btn.dataset.action;
            if (action === 'scrollDown') send('scroll', { direction: 'down', amount: 400 });
            else if (action === 'scrollUp') send('scroll', { direction: 'up', amount: 400 });
            else send(action);
        });
    });

    // Element control
    $('#btnClick').onclick = () => {
        const sel = selectorInput.value.trim();
        if (sel) send('click', { selector: sel });
    };
    $('#btnWait').onclick = () => {
        const sel = selectorInput.value.trim();
        if (sel) send('waitForSelector', { selector: sel });
    };
    $('#btnType').onclick = () => {
        const sel = selectorInput.value.trim();
        const text = typeInput.value;
        if (sel && text) send('type', { selector: sel, text });
    };
    $('#btnKey').onclick = () => {
        const key = keyInput.value.trim();
        if (key) send('pressKey', { key });
    };

    // Tabs
    $('#btnNewTab').onclick = () => send('newTab', { url: urlInput.value.trim() || undefined });
    $('#btnGetTabs').onclick = () => send('getTabs');

    // Clear log
    $('#btnClearLog').onclick = () => { logEntries.innerHTML = ''; };

    // Agent stop
    btnAgentStop.onclick = () => send('agentStop');

    // Send message / agent task
    function sendMessage() {
        const text = chatInput.value.trim();
        if (!text || isStreaming) return;
        const model = modelSelect.value;
        if (!model) {
            addChatMsg('error', 'Select an AI model first');
            return;
        }

        addChatMsg('user', text);
        chatInput.value = '';

        if (currentTab === 'agent') {
            send('agentRun', { task: text, model });
            btnAgentStop.style.display = 'inline-flex';
        } else {
            send('chat', { message: text, model });
        }
    }

    $('#btnSend').onclick = sendMessage;
    chatInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });

    // ── Auto-refresh screenshots ──
    function startAutoRefresh() {
        stopAutoRefresh();
        browserOpen = true;
        autoRefreshTimer = setInterval(() => {
            if (browserOpen && !isStreaming && ws && ws.readyState === WebSocket.OPEN) {
                send('screenshot');
            }
        }, AUTO_REFRESH_MS);
    }

    function stopAutoRefresh() {
        browserOpen = false;
        if (autoRefreshTimer) {
            clearInterval(autoRefreshTimer);
            autoRefreshTimer = null;
        }
    }

    // ── Split view: drag handle ──
    const screenshotPanel = $('#screenshotPanel');
    const chatPanel = $('#chatPanel');
    const splitHandle = $('#splitHandle');

    let isDragging = false;

    splitHandle.addEventListener('mousedown', (e) => {
        isDragging = true;
        splitHandle.classList.add('dragging');
        document.body.style.cursor = 'row-resize';
        document.body.style.userSelect = 'none';
        e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
        if (!isDragging) return;
        const contentArea = screenshotPanel.parentElement;
        const rect = contentArea.getBoundingClientRect();
        const offset = e.clientY - rect.top;
        const total = rect.height;
        const pct = Math.min(Math.max(offset / total, 0.1), 0.9);

        // Remove any maximized/hidden states
        screenshotPanel.classList.remove('hidden-panel', 'maximized-panel');
        chatPanel.classList.remove('hidden-panel', 'maximized-panel');

        screenshotPanel.style.flex = `0 0 ${pct * 100}%`;
        chatPanel.style.flex = `0 0 ${(1 - pct) * 100}%`;
        chatPanel.style.height = 'auto';
    });

    document.addEventListener('mouseup', () => {
        if (!isDragging) return;
        isDragging = false;
        splitHandle.classList.remove('dragging');
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
    });

    // ── Split view: hide / maximize buttons ──
    function resetSplitStyles() {
        screenshotPanel.style.flex = '';
        chatPanel.style.flex = '';
        chatPanel.style.height = '';
    }

    $('#btnMaxBrowser').onclick = () => {
        resetSplitStyles();
        const isMax = screenshotPanel.classList.toggle('maximized-panel');
        chatPanel.classList.toggle('hidden-panel', isMax);
        screenshotPanel.classList.remove('hidden-panel');
        chatPanel.classList.remove('maximized-panel');
    };

    $('#btnHideBrowser').onclick = () => {
        resetSplitStyles();
        const isHidden = screenshotPanel.classList.toggle('hidden-panel');
        chatPanel.classList.toggle('maximized-panel', isHidden);
        screenshotPanel.classList.remove('maximized-panel');
        chatPanel.classList.remove('hidden-panel');
    };

    $('#btnMaxChat').onclick = () => {
        resetSplitStyles();
        const isMax = chatPanel.classList.toggle('maximized-panel');
        screenshotPanel.classList.toggle('hidden-panel', isMax);
        chatPanel.classList.remove('hidden-panel');
        screenshotPanel.classList.remove('maximized-panel');
    };

    $('#btnHideChat').onclick = () => {
        resetSplitStyles();
        const isHidden = chatPanel.classList.toggle('hidden-panel');
        screenshotPanel.classList.toggle('maximized-panel', isHidden);
        chatPanel.classList.remove('maximized-panel');
        screenshotPanel.classList.remove('hidden-panel');
    };

    // ── Init ──
    connect();
})();
