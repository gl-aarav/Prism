// Prism Browser Automation Server
// Real-time browser control via Puppeteer & Playwright with Prism AI models
const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');
const path = require('path');
const PuppeteerEngine = require('./puppeteer-engine');
const PlaywrightEngine = require('./playwright-engine');
const { fetchModels, streamChat } = require('./ai-bridge');

const PORT = 9090;
const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

// State
const engines = { puppeteer: new PuppeteerEngine(), playwright: new PlaywrightEngine() };
let activeEngine = null;
let conversationHistory = [];
let isAgentRunning = false;

app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json({ limit: '10mb' }));

// REST endpoints
app.get('/api/models', async (req, res) => {
    try {
        const models = await fetchModels();
        res.json(models);
    } catch (e) {
        res.status(502).json({ error: 'Cannot reach Prism app. Make sure it is running.' });
    }
});

app.get('/api/status', (req, res) => {
    res.json({
        engine: activeEngine ? activeEngine.name : null,
        isOpen: activeEngine ? activeEngine.isOpen() : false,
        isAgentRunning,
    });
});

// WebSocket for real-time control
wss.on('connection', (ws) => {
    console.log('[WS] Client connected');

    ws.on('message', async (raw) => {
        let msg;
        try {
            msg = JSON.parse(raw);
        } catch {
            return ws.send(JSON.stringify({ type: 'error', text: 'Invalid JSON' }));
        }

        try {
            await handleCommand(ws, msg);
        } catch (err) {
            ws.send(JSON.stringify({ type: 'error', text: err.message }));
        }
    });

    ws.on('close', () => console.log('[WS] Client disconnected'));
});

async function handleCommand(ws, msg) {
    const { action, payload } = msg;

    switch (action) {
        case 'launch': {
            const engineName = payload.engine || 'puppeteer';
            if (activeEngine && activeEngine.isOpen()) await activeEngine.close();
            activeEngine = engines[engineName] || engines.puppeteer;
            const result = await activeEngine.launch();
            conversationHistory = [];
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            break;
        }

        case 'navigate': {
            const result = await activeEngine.navigate(payload.url);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            await sendScreenshot(ws);
            break;
        }

        case 'screenshot': {
            await sendScreenshot(ws);
            break;
        }

        case 'click': {
            const result = await activeEngine.click(payload.selector);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            await sleep(500);
            await sendScreenshot(ws);
            break;
        }

        case 'type': {
            const result = await activeEngine.type(payload.selector, payload.text);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            break;
        }

        case 'pressKey': {
            const result = await activeEngine.pressKey(payload.key);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            await sleep(300);
            await sendScreenshot(ws);
            break;
        }

        case 'scroll': {
            const result = await activeEngine.scroll(payload.direction || 'down', payload.amount || 400);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            await sleep(300);
            await sendScreenshot(ws);
            break;
        }

        case 'domTree': {
            const tree = await activeEngine.getDomTree();
            ws.send(JSON.stringify({ type: 'result', action, data: tree }));
            break;
        }

        case 'pageInfo': {
            const info = await activeEngine.getPageInfo();
            ws.send(JSON.stringify({ type: 'result', action, data: info }));
            break;
        }

        case 'newTab': {
            const result = await activeEngine.newTab(payload.url);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            break;
        }

        case 'getTabs': {
            const tabs = await activeEngine.getTabs();
            ws.send(JSON.stringify({ type: 'result', action, data: tabs }));
            break;
        }

        case 'switchTab': {
            const result = await activeEngine.switchTab(payload.index);
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            await sendScreenshot(ws);
            break;
        }

        case 'close': {
            const result = await activeEngine.close();
            ws.send(JSON.stringify({ type: 'result', action, data: result }));
            break;
        }

        case 'chat': {
            await handleChat(ws, payload);
            break;
        }

        case 'agentRun': {
            await handleAgentRun(ws, payload);
            break;
        }

        case 'agentStop': {
            isAgentRunning = false;
            ws.send(JSON.stringify({ type: 'agentStopped' }));
            break;
        }

        case 'clearHistory': {
            conversationHistory = [];
            ws.send(JSON.stringify({ type: 'result', action, data: { status: 'cleared' } }));
            break;
        }

        default:
            ws.send(JSON.stringify({ type: 'error', text: `Unknown action: ${action}` }));
    }
}

async function sendScreenshot(ws) {
    try {
        const base64 = await activeEngine.screenshot();
        ws.send(JSON.stringify({ type: 'screenshot', data: base64 }));
    } catch { /* page may have closed */ }
}

async function handleChat(ws, payload) {
    const { message, model, thinkingLevel } = payload;
    conversationHistory.push({ role: 'user', content: message });

    let fullResponse = '';
    try {
        await streamChat(conversationHistory, model, '', (chunk) => {
            if (chunk.type === 'content') {
                fullResponse += chunk.text;
                ws.send(JSON.stringify({ type: 'chatChunk', text: chunk.text }));
            } else if (chunk.type === 'thinking') {
                ws.send(JSON.stringify({ type: 'chatThinking', text: chunk.text }));
            }
        }, { thinkingLevel });
        conversationHistory.push({ role: 'assistant', content: fullResponse });
        ws.send(JSON.stringify({ type: 'chatDone' }));
    } catch (err) {
        ws.send(JSON.stringify({ type: 'error', text: `Chat error: ${err.message}` }));
    }
}

const AGENT_SYSTEM_PROMPT = `You are a browser automation agent. You control a web browser by outputting JSON actions. You MUST include exactly one JSON action block in every response.

CRITICAL: Every response MUST contain a JSON action in this format:
\`\`\`json
{"action": "ACTION_NAME", ...params}
\`\`\`

Available actions:
- {"action": "navigate", "url": "https://..."}
- {"action": "click", "selector": "CSS_SELECTOR"}
- {"action": "type", "selector": "CSS_SELECTOR", "text": "text to type"}
- {"action": "pressKey", "key": "Enter"}
- {"action": "scroll", "direction": "down", "amount": 400}
- {"action": "newTab", "url": "https://..."}
- {"action": "switchTab", "index": 0}
- {"action": "wait", "ms": 2000}
- {"action": "done", "summary": "what was accomplished"}

Rules:
1. ALWAYS output a JSON action block — never respond with only text.
2. Use CSS selectors from the element list provided (prefer [index] notation or IDs).
3. After typing in a search field, use pressKey Enter to submit.
4. When the task is complete, use the "done" action.
5. You may include brief reasoning text before the JSON block.

Example response:
I see the Google homepage. I'll type in the search box.
\`\`\`json
{"action": "type", "selector": "textarea[name='q']", "text": "cats"}
\`\`\``;

async function handleAgentRun(ws, payload) {
    const { task, model, thinkingLevel } = payload;
    if (!activeEngine || !activeEngine.isOpen()) {
        return ws.send(JSON.stringify({ type: 'error', text: 'Launch a browser first' }));
    }

    isAgentRunning = true;
    const agentHistory = [];
    let stepCount = 0;
    const maxSteps = 25;

    // Inject system prompt as first user message (Prism API ignores systemPrompt body field)
    agentHistory.push({
        role: 'user',
        content: AGENT_SYSTEM_PROMPT,
    });
    agentHistory.push({
        role: 'assistant',
        content: 'Understood. I will always include a JSON action block in every response. Ready for the task.',
    });

    // Initial context
    const screenshot = await activeEngine.screenshot();
    const dom = await activeEngine.getDomTree();

    agentHistory.push({
        role: 'user',
        content: `Task: ${task}\n\nCurrent page: ${dom.url}\nTitle: ${dom.title}\n\nInteractive elements:\n${formatDomElements(dom.elements)}\n\n[Screenshot attached - base64 image of current page state]`,
    });

    ws.send(JSON.stringify({ type: 'agentStep', step: 0, text: `Starting task: ${task}` }));
    ws.send(JSON.stringify({ type: 'screenshot', data: screenshot }));

    while (isAgentRunning && stepCount < maxSteps) {
        stepCount++;
        let fullResponse = '';

        try {
            await streamChat(agentHistory, model, '', (chunk) => {
                if (chunk.type === 'content') {
                    fullResponse += chunk.text;
                    ws.send(JSON.stringify({ type: 'agentChunk', text: chunk.text }));
                }
            }, { thinkingLevel });
        } catch (err) {
            ws.send(JSON.stringify({ type: 'error', text: `Agent error: ${err.message}` }));
            break;
        }

        agentHistory.push({ role: 'assistant', content: fullResponse });

        // Parse agent action — try multiple formats
        console.log('[Agent] Raw response length:', fullResponse.length);
        console.log('[Agent] Raw response (first 500):', fullResponse.substring(0, 500));

        let agentAction = extractAction(fullResponse);

        // If no action found, re-prompt the model once asking for the action block
        if (!agentAction) {
            console.log('[Agent] No action found, re-prompting model...');
            agentHistory.push({
                role: 'user',
                content: 'You must respond with a JSON action block. Use this exact format:\n```agent-action\n{"action": "navigate", "url": "https://example.com"}\n```\nDo NOT respond with just text. Provide your next action now.',
            });
            let retryResponse = '';
            try {
                await streamChat(agentHistory, model, '', (chunk) => {
                    if (chunk.type === 'content') {
                        retryResponse += chunk.text;
                        ws.send(JSON.stringify({ type: 'agentChunk', text: chunk.text }));
                    }
                }, { thinkingLevel });
            } catch (err) {
                ws.send(JSON.stringify({ type: 'error', text: `Agent retry error: ${err.message}` }));
                break;
            }
            agentHistory.push({ role: 'assistant', content: retryResponse });
            console.log('[Agent] Retry response (first 500):', retryResponse.substring(0, 500));
            agentAction = extractAction(retryResponse);
        }

        if (!agentAction) {
            ws.send(JSON.stringify({ type: 'agentStep', step: stepCount, text: 'No action found in response. Stopping.' }));
            break;
        }

        ws.send(JSON.stringify({ type: 'agentAction', step: stepCount, action: agentAction }));

        // Execute action
        if (agentAction.action === 'done') {
            ws.send(JSON.stringify({ type: 'agentDone', summary: agentAction.summary || 'Task complete' }));
            break;
        }

        if (agentAction.action === 'wait') {
            await sleep(agentAction.ms || 1000);
        } else {
            try {
                await executeAgentAction(agentAction);
            } catch (err) {
                ws.send(JSON.stringify({ type: 'agentStep', step: stepCount, text: `Action failed: ${err.message}` }));
                agentHistory.push({
                    role: 'user',
                    content: `Action failed with error: ${err.message}\n\nPlease try a different approach.`,
                });
                continue;
            }
        }

        await sleep(800);

        // Get new state
        let newScreenshot, newDom;
        try {
            newScreenshot = await activeEngine.screenshot();
            newDom = await activeEngine.getDomTree();
        } catch {
            ws.send(JSON.stringify({ type: 'agentStep', step: stepCount, text: 'Browser closed or page error.' }));
            break;
        }

        ws.send(JSON.stringify({ type: 'screenshot', data: newScreenshot }));

        agentHistory.push({
            role: 'user',
            content: `Action completed. New page state:\nURL: ${newDom.url}\nTitle: ${newDom.title}\n\nInteractive elements:\n${formatDomElements(newDom.elements)}\n\n[Screenshot of current page state]`,
        });
    }

    isAgentRunning = false;
    if (stepCount >= maxSteps) {
        ws.send(JSON.stringify({ type: 'agentDone', summary: 'Reached maximum steps limit.' }));
    }
}

async function executeAgentAction(action) {
    switch (action.action) {
        case 'navigate': return activeEngine.navigate(action.url);
        case 'click': return activeEngine.click(action.selector);
        case 'type': return activeEngine.type(action.selector, action.text);
        case 'pressKey': return activeEngine.pressKey(action.key);
        case 'scroll': return activeEngine.scroll(action.direction || 'down', action.amount || 400);
        case 'newTab': return activeEngine.newTab(action.url);
        case 'switchTab': return activeEngine.switchTab(action.index);
        default: throw new Error(`Unknown action: ${action.action}`);
    }
}

// Extract an action JSON from the AI response — handles many formats
function extractAction(text) {
    if (!text || text.trim().length === 0) return null;

    // 1. ```agent-action ... ```
    let m = text.match(/```agent-action\s*\n?([\s\S]*?)\n?```/);
    if (m && m[1]) {
        try { return JSON.parse(m[1].trim()); } catch { }
    }

    // 2. ```json ... ``` containing "action"
    m = text.match(/```json\s*\n?([\s\S]*?)\n?```/);
    if (m && m[1] && m[1].includes('"action"')) {
        try { return JSON.parse(m[1].trim()); } catch { }
    }

    // 3. Any ``` ... ``` block containing "action"
    m = text.match(/```\w*\s*\n?([\s\S]*?)\n?```/);
    if (m && m[1] && m[1].includes('"action"')) {
        try { return JSON.parse(m[1].trim()); } catch { }
    }

    // 4. Raw JSON object with "action" key anywhere in text
    m = text.match(/(\{[^{}]*"action"\s*:\s*"[^"]+"[^{}]*\})/);
    if (m) {
        try { return JSON.parse(m[1].trim()); } catch { }
    }

    // 5. Multi-line raw JSON (with nested braces up to 1 level)
    m = text.match(/(\{[^{}]*"action"\s*:[\s\S]*?\})/m);
    if (m) {
        try { return JSON.parse(m[1].trim()); } catch { }
    }

    return null;
}

function formatDomElements(elements) {
    if (!elements || elements.length === 0) return '(no interactive elements found)';
    return elements.map(el => {
        let desc = `[${el.index}] <${el.tag}>`;
        if (el.role) desc += ` role="${el.role}"`;
        if (el.type) desc += ` type="${el.type}"`;
        if (el.placeholder) desc += ` placeholder="${el.placeholder}"`;
        if (el.text) desc += ` "${el.text}"`;
        if (el.href) desc += ` → ${el.href.slice(0, 60)}`;
        desc += `  selector: ${el.selector}`;
        return desc;
    }).join('\n');
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Cleanup
process.on('SIGINT', async () => {
    console.log('\nShutting down...');
    for (const e of Object.values(engines)) {
        if (e.isOpen()) await e.close();
    }
    process.exit(0);
});

server.listen(PORT, () => {
    console.log(`\n  🔮 Prism Browser Automation`);
    console.log(`  ──────────────────────────`);
    console.log(`  UI:     http://localhost:${PORT}`);
    console.log(`  Prism:  http://127.0.0.1:8080 (required)\n`);
});
