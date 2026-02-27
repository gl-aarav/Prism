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

    // ── NEW AGENTIC ACTIONS ──────────────────────────────────

    if (request.action === "agentSelect") {
        try {
            const el = findElement(request.selector);
            if (el && el.tagName === 'SELECT') {
                el.value = request.value;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                sendResponse({ ok: true, summary: `Selected "${request.value}" in ${getLabel(el)}` });
            } else { sendResponse({ ok: false, error: "Select element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExtractText") {
        try {
            const selector = request.selector || 'body';
            const els = document.querySelectorAll(selector);
            const texts = Array.from(els).map(el => el.innerText.trim()).filter(t => t).slice(0, 50);
            const combined = texts.join('\n\n').substring(0, 10000);
            sendResponse({ ok: true, text: combined, summary: `Extracted text from ${texts.length} elements` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExtractLinks") {
        try {
            const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 200).map(a => ({
                text: (a.textContent || '').trim().substring(0, 100),
                href: a.href,
                selector: getCssSelector(a)
            })).filter(l => l.href && !l.href.startsWith('javascript:'));
            sendResponse({ ok: true, links, summary: `Found ${links.length} links` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExtractTable") {
        try {
            const table = request.selector ? document.querySelector(request.selector) : document.querySelector('table');
            if (!table) { sendResponse({ ok: false, error: "No table found" }); return; }
            const rows = Array.from(table.querySelectorAll('tr')).slice(0, 100);
            const data = rows.map(row =>
                Array.from(row.querySelectorAll('th, td')).map(cell => cell.innerText.trim())
            );
            sendResponse({ ok: true, data, summary: `Extracted table with ${data.length} rows` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentHighlight") {
        try {
            const els = document.querySelectorAll(request.selector);
            const color = request.color || 'yellow';
            els.forEach(el => {
                el.style.outline = `3px solid ${color}`;
                el.style.outlineOffset = '2px';
            });
            sendResponse({ ok: true, summary: `Highlighted ${els.length} elements in ${color}` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentWaitFor") {
        try {
            const timeout = Math.min(request.timeout || 5000, 10000);
            const start = Date.now();
            const check = () => {
                const el = document.querySelector(request.selector);
                if (el) {
                    sendResponse({ ok: true, summary: `Element "${request.selector}" found` });
                } else if (Date.now() - start > timeout) {
                    sendResponse({ ok: false, error: `Timeout waiting for "${request.selector}"` });
                } else {
                    setTimeout(check, 200);
                }
            };
            check();
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentFillForm") {
        try {
            const results = [];
            for (const field of (request.fields || [])) {
                const el = findElement(field.selector);
                if (el) {
                    el.focus();
                    if (el.tagName === 'SELECT') {
                        el.value = field.value || '';
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    } else {
                        el.value = field.value || '';
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    results.push(`Filled ${getLabel(el)}`);
                } else {
                    results.push(`Not found: ${field.selector}`);
                }
            }
            sendResponse({ ok: true, summary: `Form: ${results.join(', ')}` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentHover") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
                el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                sendResponse({ ok: true, summary: `Hovered "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentToggleCheckbox") {
        try {
            const el = findElement(request.selector);
            if (el && (el.type === 'checkbox' || el.type === 'radio')) {
                el.click();
                sendResponse({ ok: true, summary: `Toggled ${getLabel(el)} (now ${el.checked ? 'checked' : 'unchecked'})` });
            } else { sendResponse({ ok: false, error: "Checkbox/radio not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetAttribute") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const val = el.getAttribute(request.attribute);
                sendResponse({ ok: true, value: val, summary: `${request.attribute}="${val}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentReadSelection") {
        try {
            const selection = window.getSelection().toString();
            sendResponse({ ok: true, text: selection, summary: selection ? `Selected: "${selection.substring(0, 100)}"` : 'No text selected' });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentReadPageMeta") {
        try {
            const meta = {
                title: document.title,
                url: window.location.href,
                description: document.querySelector('meta[name="description"]')?.content || '',
                keywords: document.querySelector('meta[name="keywords"]')?.content || '',
                ogTitle: document.querySelector('meta[property="og:title"]')?.content || '',
                ogDescription: document.querySelector('meta[property="og:description"]')?.content || '',
                ogImage: document.querySelector('meta[property="og:image"]')?.content || '',
                canonical: document.querySelector('link[rel="canonical"]')?.href || '',
                lang: document.documentElement.lang || '',
                favicon: document.querySelector('link[rel="icon"]')?.href || document.querySelector('link[rel="shortcut icon"]')?.href || ''
            };
            sendResponse({ ok: true, meta, summary: `Page: "${meta.title}"` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
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
