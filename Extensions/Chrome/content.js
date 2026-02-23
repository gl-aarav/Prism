chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "getPageContext") {
        sendResponse({ content: document.body.innerText });
    }

    // ── AGENTIC BROWSER CONTROL ──────────────────────────────
    if (request.action === "agentClick") {
        try {
            const el = findElement(request.selector);
            if (el) { el.click(); sendResponse({ ok: true, summary: `Clicked "${getLabel(el)}"` }); }
            else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentType") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.focus();
                el.value = request.text || '';
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                sendResponse({ ok: true, summary: `Typed in "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentScroll") {
        try {
            const amount = request.amount || 300;
            const dir = request.direction || 'down';
            window.scrollBy({ top: dir === 'up' ? -amount : amount, behavior: 'smooth' });
            sendResponse({ ok: true, summary: `Scrolled ${dir} ${amount}px` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentDrag") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const rect = el.getBoundingClientRect();
                const startX = rect.left + rect.width / 2;
                const startY = rect.top + rect.height / 2;
                const endX = startX + (request.dx || 0);
                const endY = startY + (request.dy || 0);

                el.dispatchEvent(new MouseEvent('mousedown', { clientX: startX, clientY: startY, bubbles: true }));
                el.dispatchEvent(new MouseEvent('mousemove', { clientX: endX, clientY: endY, bubbles: true }));
                el.dispatchEvent(new MouseEvent('mouseup', { clientX: endX, clientY: endY, bubbles: true }));
                sendResponse({ ok: true, summary: `Dragged "${getLabel(el)}" by (${request.dx}, ${request.dy})` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetElements") {
        try {
            const interactive = Array.from(document.querySelectorAll(
                'a, button, input, textarea, select, [role="button"], [role="link"], [contenteditable], [tabindex]'
            )).slice(0, 100).map((el, i) => ({
                index: i,
                tag: el.tagName.toLowerCase(),
                type: el.type || '',
                text: getLabel(el).substring(0, 80),
                id: el.id || '',
                name: el.name || '',
                selector: getCssSelector(el)
            }));
            sendResponse({ ok: true, elements: interactive });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentScreenshot") {
        // Can't do full screenshot from content script, return page info instead
        sendResponse({
            ok: true,
            summary: "Scanned page",
            pageInfo: {
                title: document.title,
                url: window.location.href,
                scrollY: window.scrollY,
                bodyHeight: document.body.scrollHeight,
                viewportHeight: window.innerHeight
            }
        });
    }

    return true;
});

// ── HELPERS ──────────────────────────────────────────────
function findElement(selector) {
    if (!selector) return null;
    // Try CSS selector first
    try { const el = document.querySelector(selector); if (el) return el; } catch (e) { }
    // Try by text content
    const all = document.querySelectorAll('a, button, input, textarea, select, [role="button"]');
    for (const el of all) {
        if (getLabel(el).toLowerCase().includes(selector.toLowerCase())) return el;
    }
    return null;
}

function getLabel(el) {
    return (el.textContent || el.getAttribute('aria-label') || el.getAttribute('title')
        || el.getAttribute('placeholder') || el.getAttribute('alt') || el.tagName).trim().substring(0, 60);
}

function getCssSelector(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    if (el.name) return `${el.tagName.toLowerCase()}[name="${CSS.escape(el.name)}"]`;
    const path = [];
    while (el && el !== document.body) {
        let selector = el.tagName.toLowerCase();
        if (el.className && typeof el.className === 'string') {
            const cls = el.className.trim().split(/\s+/).filter(c => c.length < 30).slice(0, 2);
            if (cls.length) selector += '.' + cls.map(CSS.escape).join('.');
        }
        path.unshift(selector);
        el = el.parentElement;
    }
    return path.join(' > ');
}
