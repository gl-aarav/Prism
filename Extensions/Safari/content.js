// Prism Safari Extension — Content Script
// Safari-compatible (uses browser/chrome API)

const api = typeof browser !== 'undefined' ? browser : chrome;

api.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "getPageContext") {
        sendResponse({ content: document.body.innerText });
    }

    // ── AGENTIC BROWSER CONTROL ──────────────────────────────
    if (request.action === "agentClick") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
                el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
                el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
                el.click();
                sendResponse({ ok: true, summary: `Clicked "${getLabel(el)}"` });
            }
            else { sendResponse({ ok: false, error: "Element not found for: " + request.selector }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentType") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                el.focus();
                const text = request.text || '';
                const isRichEditor = isContentEditable(el) || isRichTextEditor(el);

                if (isRichEditor) {
                    if (request.clear !== false) {
                        document.execCommand('selectAll', false, null);
                        document.execCommand('delete', false, null);
                    }
                    const inserted = document.execCommand('insertText', false, text);
                    if (!inserted) {
                        el.dispatchEvent(new InputEvent('beforeinput', {
                            inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true
                        }));
                        el.dispatchEvent(new InputEvent('input', {
                            inputType: 'insertText', data: text, bubbles: true, composed: true
                        }));
                    }
                    sendResponse({ ok: true, summary: `Typed "${text.substring(0, 50)}" in "${getLabel(el)}"` });
                } else {
                    if (request.clear !== false) {
                        el.value = '';
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                    }
                    for (const char of text) {
                        el.dispatchEvent(new KeyboardEvent('keydown', { key: char, bubbles: true }));
                        el.dispatchEvent(new KeyboardEvent('keypress', { key: char, bubbles: true }));
                        const nativeSet = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
                        if (nativeSet) {
                            nativeSet.call(el, el.value + char);
                        } else {
                            el.value += char;
                        }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new KeyboardEvent('keyup', { key: char, bubbles: true }));
                    }
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    sendResponse({ ok: true, summary: `Typed "${text.substring(0, 50)}" in "${getLabel(el)}"` });
                }
            } else { sendResponse({ ok: false, error: "Element not found for: " + request.selector }); }
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

    if (request.action === "agentPressKey") {
        try {
            const el = findElement(request.selector) || document.activeElement || document.body;
            const key = request.key || 'Enter';
            const opts = { key, bubbles: true, cancelable: true };
            if (request.ctrlKey) opts.ctrlKey = true;
            if (request.shiftKey) opts.shiftKey = true;
            if (request.altKey) opts.altKey = true;
            if (request.metaKey) opts.metaKey = true;
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
            el.dispatchEvent(new KeyboardEvent('keypress', opts));
            el.dispatchEvent(new KeyboardEvent('keyup', opts));
            sendResponse({ ok: true, summary: `Pressed ${request.metaKey ? 'Cmd+' : ''}${request.ctrlKey ? 'Ctrl+' : ''}${request.shiftKey ? 'Shift+' : ''}${request.altKey ? 'Alt+' : ''}${key}` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentClearInput") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.focus();
                if (isContentEditable(el) || isRichTextEditor(el)) {
                    document.execCommand('selectAll', false, null);
                    document.execCommand('delete', false, null);
                } else {
                    const nativeSet = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
                    if (nativeSet) nativeSet.call(el, '');
                    else el.value = '';
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                }
                sendResponse({ ok: true, summary: `Cleared "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentSelectText") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const range = document.createRange();
                range.selectNodeContents(el);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                sendResponse({ ok: true, summary: `Selected text in "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetFormValues") {
        try {
            const form = request.selector ? document.querySelector(request.selector) : document.querySelector('form');
            if (!form) { sendResponse({ ok: false, error: "No form found" }); return true; }
            const data = {};
            const inputs = form.querySelectorAll('input, textarea, select');
            inputs.forEach(el => {
                const name = el.name || el.id || getCssSelector(el);
                if (el.type === 'checkbox' || el.type === 'radio') {
                    data[name] = el.checked;
                } else {
                    data[name] = el.value;
                }
            });
            sendResponse({ ok: true, data, summary: `Read ${Object.keys(data).length} form fields` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetStyles") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const computed = window.getComputedStyle(el);
                const props = request.properties || ['display', 'visibility', 'color', 'backgroundColor', 'fontSize', 'position'];
                const styles = {};
                props.forEach(p => styles[p] = computed.getPropertyValue(p.replace(/([A-Z])/g, '-$1').toLowerCase()));
                sendResponse({ ok: true, styles, summary: `Got styles for "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentScrollTo") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: request.block || 'center' });
                sendResponse({ ok: true, summary: `Scrolled to "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentDoubleClick") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }));
                sendResponse({ ok: true, summary: `Double-clicked "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentRightClick") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
                sendResponse({ ok: true, summary: `Right-clicked "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentFocusElement") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                el.focus();
                sendResponse({ ok: true, summary: `Focused "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    // ── ADVANCED AGENTIC ACTIONS ─────────────────────────────

    if (request.action === "agentDismissPopups") {
        try {
            let dismissed = 0;
            const popupSelectors = [
                '[class*="cookie"] button', '[class*="Cookie"] button',
                '[id*="cookie"] button', '[id*="Cookie"] button',
                '[class*="consent"] button', '[id*="consent"] button',
                '[class*="gdpr"] button', '[id*="gdpr"] button',
                '[class*="banner"] [class*="close"]', '[class*="banner"] [class*="dismiss"]',
                '[class*="modal"] [class*="close"]', '[class*="overlay"] [class*="close"]',
                '[class*="popup"] [class*="close"]', '[class*="dialog"] [class*="close"]',
                'button[class*="close"]', '[aria-label="Close"]', '[aria-label="Dismiss"]',
                '[aria-label="close"]', '[aria-label="dismiss"]',
                '[class*="notification"] [class*="close"]',
                '.cookie-banner button', '#cookie-banner button',
                'button[class*="accept"]', 'button[class*="Accept"]',
                'button[class*="agree"]', 'button[class*="Agree"]',
                '[role="dialog"] button[class*="close"]',
                '[role="alertdialog"] button[class*="close"]'
            ];
            for (const sel of popupSelectors) {
                try {
                    const btns = document.querySelectorAll(sel);
                    for (const btn of btns) {
                        if (btn.offsetParent !== null) {
                            btn.click();
                            dismissed++;
                        }
                    }
                } catch (e) { }
            }
            const allEls = document.querySelectorAll('div, section, aside');
            for (const el of allEls) {
                const style = window.getComputedStyle(el);
                if ((style.position === 'fixed' || style.position === 'sticky') && style.zIndex > 999) {
                    const rect = el.getBoundingClientRect();
                    if (rect.width > window.innerWidth * 0.5 && rect.height > 50) {
                        el.remove();
                        dismissed++;
                    }
                }
            }
            sendResponse({ ok: true, summary: `Dismissed ${dismissed} popup(s)/overlay(s)` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentPaste") {
        try {
            const el = findElement(request.selector) || document.activeElement;
            if (el) {
                el.focus();
                const text = request.text || '';
                if (isContentEditable(el) || isRichTextEditor(el)) {
                    document.execCommand('insertText', false, text);
                } else {
                    const nativeSet = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
                    if (nativeSet) nativeSet.call(el, (el.value || '') + text);
                    else el.value = (el.value || '') + text;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                }
                el.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, clipboardData: new DataTransfer() }));
                sendResponse({ ok: true, summary: `Pasted "${text.substring(0, 50)}" into "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "No element to paste into" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentWaitForNavigation") {
        try {
            const timeout = Math.min(request.timeout || 10000, 30000);
            if (document.readyState === 'complete') {
                sendResponse({ ok: true, summary: 'Page already loaded' });
            } else {
                const start = Date.now();
                const check = () => {
                    if (document.readyState === 'complete') {
                        sendResponse({ ok: true, summary: 'Page loaded', url: window.location.href });
                    } else if (Date.now() - start > timeout) {
                        sendResponse({ ok: false, error: 'Timeout waiting for page load' });
                    } else {
                        setTimeout(check, 200);
                    }
                };
                check();
            }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetStructuredData") {
        try {
            const data = {};
            const jsonLd = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
            data.jsonLd = jsonLd.map(s => { try { return JSON.parse(s.textContent); } catch (e) { return null; } }).filter(Boolean);
            data.openGraph = {};
            document.querySelectorAll('meta[property^="og:"]').forEach(m => {
                data.openGraph[m.getAttribute('property')] = m.content;
            });
            data.twitterCard = {};
            document.querySelectorAll('meta[name^="twitter:"]').forEach(m => {
                data.twitterCard[m.getAttribute('name')] = m.content;
            });
            const microdata = document.querySelectorAll('[itemscope]');
            data.microdata = Array.from(microdata).slice(0, 10).map(el => ({
                type: el.getAttribute('itemtype') || '',
                props: Array.from(el.querySelectorAll('[itemprop]')).slice(0, 20).map(p => ({
                    name: p.getAttribute('itemprop'),
                    value: (p.content || p.textContent || '').trim().substring(0, 200)
                }))
            }));
            sendResponse({ ok: true, data, summary: `Found ${data.jsonLd.length} JSON-LD, ${Object.keys(data.openGraph).length} OG tags` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetPageState") {
        try {
            const state = {
                url: window.location.href,
                title: document.title,
                readyState: document.readyState,
                bodyLength: document.body?.innerText?.length || 0,
                scrollY: window.scrollY,
                scrollHeight: document.body?.scrollHeight || 0,
                viewportHeight: window.innerHeight,
                viewportWidth: window.innerWidth,
                hasScrollbar: document.body?.scrollHeight > window.innerHeight,
                forms: document.forms.length,
                images: document.images.length,
                links: document.links.length,
                iframes: document.querySelectorAll('iframe').length
            };
            state.hasOverlay = !!document.querySelector('[class*="overlay"][style*="fixed"], [class*="modal"][style*="display"], [role="dialog"]:not([style*="none"])');
            state.hasCaptcha = !!document.querySelector('[class*="captcha"], [id*="captcha"], [class*="recaptcha"], iframe[src*="captcha"], iframe[src*="recaptcha"]');
            state.hasLoginForm = !!document.querySelector('input[type="password"]');
            state.isErrorPage = /404|500|error|not found/i.test(document.title) || document.querySelectorAll('main, article, [role="main"]').length === 0;
            sendResponse({ ok: true, state, summary: `Page: ${state.readyState}, ${state.bodyLength} chars, ${state.forms} forms` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentClickAtPosition") {
        try {
            const x = request.x || 0;
            const y = request.y || 0;
            const el = document.elementFromPoint(x, y);
            if (el) {
                el.dispatchEvent(new MouseEvent('mousedown', { clientX: x, clientY: y, bubbles: true, cancelable: true }));
                el.dispatchEvent(new MouseEvent('mouseup', { clientX: x, clientY: y, bubbles: true, cancelable: true }));
                el.dispatchEvent(new MouseEvent('click', { clientX: x, clientY: y, bubbles: true, cancelable: true }));
                sendResponse({ ok: true, summary: `Clicked at (${x}, ${y}) on "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: `No element at (${x}, ${y})` }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExtractImages") {
        try {
            const images = Array.from(document.querySelectorAll('img[src]')).slice(0, 100).map(img => ({
                src: img.src,
                alt: img.alt || '',
                width: img.naturalWidth || img.width,
                height: img.naturalHeight || img.height,
                selector: getCssSelector(img)
            })).filter(i => i.src && !i.src.startsWith('data:'));
            sendResponse({ ok: true, images, summary: `Found ${images.length} images` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentSummarizePage") {
        try {
            const summary = {};
            summary.title = document.title;
            summary.url = window.location.href;
            summary.description = document.querySelector('meta[name="description"]')?.content || '';
            summary.headings = Array.from(document.querySelectorAll('h1, h2, h3')).slice(0, 30).map(h => ({
                level: parseInt(h.tagName[1]),
                text: h.textContent.trim().substring(0, 100)
            }));
            const mainEl = document.querySelector('main, article, [role="main"], .content, #content') || document.body;
            summary.mainText = mainEl.innerText.trim().substring(0, 5000);
            const nav = document.querySelector('nav, [role="navigation"]');
            summary.navLinks = nav ? Array.from(nav.querySelectorAll('a')).slice(0, 20).map(a => ({
                text: a.textContent.trim().substring(0, 50), href: a.href
            })) : [];
            summary.elementCounts = {
                forms: document.forms.length,
                buttons: document.querySelectorAll('button, [role="button"]').length,
                inputs: document.querySelectorAll('input, textarea, select').length,
                tables: document.querySelectorAll('table').length,
                images: document.images.length,
                videos: document.querySelectorAll('video, iframe[src*="youtube"], iframe[src*="vimeo"]').length
            };
            sendResponse({ ok: true, data: summary, summary: `Page summary: "${summary.title}" — ${summary.headings.length} headings, ${summary.mainText.length} chars` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetSelectOptions") {
        try {
            const el = findElement(request.selector);
            if (el && el.tagName === 'SELECT') {
                const options = Array.from(el.options).map(o => ({
                    value: o.value,
                    text: o.textContent.trim(),
                    selected: o.selected,
                    disabled: o.disabled
                }));
                sendResponse({ ok: true, options, selected: el.value, summary: `${options.length} options in "${getLabel(el)}"` });
            } else { sendResponse({ ok: false, error: "Select element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentSetValue") {
        try {
            const el = findElement(request.selector);
            if (el) {
                el.focus();
                const nativeSet = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set
                    || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
                if (nativeSet) nativeSet.call(el, request.value || '');
                else el.value = request.value || '';
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                sendResponse({ ok: true, summary: `Set value of "${getLabel(el)}" to "${(request.value || '').substring(0, 50)}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentScrollToPosition") {
        try {
            const position = request.position || 'top';
            if (position === 'top') {
                window.scrollTo({ top: 0, behavior: 'smooth' });
            } else if (position === 'bottom') {
                window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
            } else if (typeof position === 'number') {
                const target = (position / 100) * document.body.scrollHeight;
                window.scrollTo({ top: target, behavior: 'smooth' });
            }
            sendResponse({ ok: true, summary: `Scrolled to ${position}` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentMultiAction") {
        (async () => {
            try {
                const results = [];
                for (const subAction of (request.actions || [])) {
                    const result = await new Promise(resolve => {
                        api.runtime.sendMessage({ ...subAction, action: 'agent' + subAction.type.charAt(0).toUpperCase() + subAction.type.slice(1) }, resolve);
                    });
                    results.push({ type: subAction.type, result: result || { ok: false, error: 'No response' } });
                    if (subAction.delay) await new Promise(r => setTimeout(r, Math.min(subAction.delay, 5000)));
                }
                sendResponse({ ok: true, results, summary: `Executed ${results.length} actions` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
    }

    if (request.action === "agentFindByContent") {
        try {
            const query = (request.query || '').toLowerCase();
            const matches = [];
            const allEls = document.querySelectorAll('*');
            for (const el of allEls) {
                if (el.children.length > 3) continue;
                const text = (el.textContent || '').trim().toLowerCase();
                if (text.includes(query) && text.length < query.length * 5 && text.length > 0) {
                    matches.push({
                        tag: el.tagName.toLowerCase(),
                        text: el.textContent.trim().substring(0, 100),
                        selector: getCssSelector(el),
                        isInteractive: el.matches('a, button, input, textarea, select, [role="button"], [role="link"], [tabindex]'),
                        rect: { x: Math.round(el.getBoundingClientRect().x), y: Math.round(el.getBoundingClientRect().y) }
                    });
                    if (matches.length >= 20) break;
                }
            }
            sendResponse({ ok: true, matches, summary: `Found ${matches.length} elements matching "${request.query}"` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentRemoveElement") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const label = getLabel(el);
                el.remove();
                sendResponse({ ok: true, summary: `Removed "${label}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetElementInfo") {
        try {
            const el = findElement(request.selector);
            if (el) {
                const rect = el.getBoundingClientRect();
                const computed = window.getComputedStyle(el);
                sendResponse({
                    ok: true,
                    info: {
                        tag: el.tagName.toLowerCase(),
                        id: el.id || '',
                        classes: Array.from(el.classList),
                        text: el.textContent?.trim()?.substring(0, 200) || '',
                        value: el.value || '',
                        href: el.href || '',
                        src: el.src || '',
                        type: el.type || '',
                        name: el.name || '',
                        placeholder: el.placeholder || '',
                        ariaLabel: el.getAttribute('aria-label') || '',
                        role: el.getAttribute('role') || '',
                        disabled: el.disabled || false,
                        visible: computed.display !== 'none' && computed.visibility !== 'hidden' && el.offsetParent !== null,
                        rect: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
                        selector: getCssSelector(el),
                        childCount: el.children.length,
                        attributes: Array.from(el.attributes).slice(0, 20).map(a => ({ name: a.name, value: a.value.substring(0, 100) }))
                    },
                    summary: `Info for ${el.tagName.toLowerCase()}: "${getLabel(el)}"`
                });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    return true;
});

// ── HELPERS ──────────────────────────────────────────────
function findElement(selector) {
    if (!selector) return null;

    if (selector.startsWith('text=')) {
        const searchText = selector.substring(5).trim();
        return findByText(searchText);
    }

    try { const el = document.querySelector(selector); if (el) return el; } catch (e) { }

    if (selector.startsWith('/') || selector.startsWith('(')) {
        try {
            const xResult = document.evaluate(selector, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            if (xResult.singleNodeValue) return xResult.singleNodeValue;
        } catch (e) { }
    }

    try {
        const byAria = document.querySelector(`[aria-label="${CSS.escape(selector)}"]`) ||
            document.querySelector(`[aria-label*="${CSS.escape(selector)}" i]`);
        if (byAria) return byAria;
    } catch (e) { }

    return findByText(selector);
}

function findByText(text) {
    if (!text) return null;
    const lowerText = text.toLowerCase().trim();

    const interactive = document.querySelectorAll('a, button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="menuitem"], summary, label');
    for (const el of interactive) {
        if (getLabel(el).toLowerCase().trim() === lowerText) return el;
    }

    for (const el of interactive) {
        if (getLabel(el).toLowerCase().includes(lowerText)) return el;
    }

    const allVisible = document.querySelectorAll('h1, h2, h3, h4, h5, h6, span, div, p, li, td, th, nav, section, details, summary, [onclick], [tabindex]');
    for (const el of allVisible) {
        const directText = getDirectText(el).toLowerCase().trim();
        if (directText === lowerText) return el;
    }
    for (const el of allVisible) {
        const directText = getDirectText(el).toLowerCase().trim();
        if (directText.includes(lowerText) && directText.length < lowerText.length * 3) return el;
    }

    try {
        const xpathResult = document.evaluate(
            `//*[contains(translate(text(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '${lowerText.replace(/'/g, "\\'")}')]`,
            document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null
        );
        if (xpathResult.singleNodeValue) return xpathResult.singleNodeValue;
    } catch (e) { }

    return null;
}

function getDirectText(el) {
    let text = '';
    for (const node of el.childNodes) {
        if (node.nodeType === Node.TEXT_NODE) text += node.textContent;
    }
    return text.trim() || getLabel(el);
}

function getLabel(el) {
    return (el.textContent || el.getAttribute('aria-label') || el.getAttribute('title')
        || el.getAttribute('placeholder') || el.getAttribute('alt') || el.tagName).trim().substring(0, 80);
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

function isContentEditable(el) {
    if (!el) return false;
    if (el.isContentEditable) return true;
    if (el.getAttribute('contenteditable') === 'true') return true;
    let parent = el.parentElement;
    while (parent) {
        if (parent.isContentEditable || parent.getAttribute('contenteditable') === 'true') return true;
        parent = parent.parentElement;
    }
    return false;
}

function isRichTextEditor(el) {
    if (!el) return false;
    if (el.classList.contains('docs-texteventtarget') || el.closest('.docs-texteventtarget')) return true;
    if (el.closest('.kix-appview-editor')) return true;
    if (el.getAttribute('role') === 'textbox' && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return true;
    if (el.closest('[data-block-id]') || el.closest('[data-content-editable-leaf]')) return true;
    if (el.closest('.cm-editor') || el.closest('.monaco-editor')) return true;
    if (el.closest('.ProseMirror')) return true;
    if (el.closest('[data-slate-editor]')) return true;
    if (el.closest('.mce-content-body') || el.closest('.ck-editor__editable')) return true;
    return false;
}
