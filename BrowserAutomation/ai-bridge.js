// AI Bridge — connects to Prism's extension server API for model access
const PRISM_BASE = 'http://127.0.0.1:8080';

async function fetchModels() {
    try {
        const res = await fetch(`${PRISM_BASE}/api/models`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
    } catch (err) {
        console.error('[AI Bridge] Cannot reach Prism app:', err.message);
        return [];
    }
}

async function streamChat(messages, model, systemPrompt, onChunk, options = {}) {
    const body = {
        messages,
        model,
    };
    if (options.thinkingLevel && options.thinkingLevel !== 'off') {
        body.thinkingLevel = options.thinkingLevel;
    }

    const res = await fetch(`${PRISM_BASE}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });

    if (!res.ok) {
        const text = await res.text();
        throw new Error(`Chat API error ${res.status}: ${text}`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let fullContent = '';

    while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop();

        for (const line of lines) {
            if (!line.startsWith('data: ')) continue;
            const data = line.slice(6);
            if (data === '[DONE]') continue;
            try {
                const parsed = JSON.parse(data);
                if (parsed.text) {
                    fullContent += parsed.text;
                    onChunk({ type: 'content', text: parsed.text });
                }
                if (parsed.thinking) {
                    onChunk({ type: 'thinking', text: parsed.thinking });
                }
                if (parsed.error) {
                    onChunk({ type: 'error', text: parsed.error });
                }
            } catch { /* non-JSON SSE line */ }
        }
    }

    return fullContent;
}

module.exports = { fetchModels, streamChat };
