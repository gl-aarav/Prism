// ── CONFIGURATION ────────────────────────────────────────
const MAX_CLICK_RETRIES = 3;
const CLICK_RETRY_DELAY = 400;
const TYPING_DELAY_MS = 15;
const ELEMENT_WAIT_TIMEOUT = 3000;
const MAX_INTERACTIVE_ELEMENTS = 60;

const OVERLAY_DISMISS_SELECTORS = [
    '[id*="cookie"] button[id*="accept"]', '[class*="cookie"] button[class*="accept"]',
    '[id*="consent"] button', '[class*="consent"] button',
    '[class*="gdpr"] button', '[id*="gdpr"] button',
    '[class*="modal"] button[class*="close"]', '[class*="dialog"] button[class*="close"]',
    '[role="dialog"] button[aria-label*="close"]', '[role="dialog"] button[aria-label*="Close"]',
    '#sp-cc-accept', '[data-action="sp-cc-accept"]', '.a-modal-close',
    'button[class*="accept"]', 'button[class*="Accept"]',
    'button[class*="agree"]', 'button[class*="Agree"]',
    '[role="alertdialog"] button[class*="close"]',
    '.cookie-banner button', '#cookie-banner button',
    '[aria-label="Close"]', '[aria-label="Dismiss"]',
    '[aria-label="close"]', '[aria-label="dismiss"]',
    '[class*="notification"] [class*="close"]',
    '[class*="banner"] [class*="close"]', '[class*="banner"] [class*="dismiss"]',
    '[class*="popup"] [class*="close"]', '[class*="overlay"] [class*="close"]',
    'button.close', '[data-dismiss="modal"]',
];

const INTERACTIVE_SELECTORS = [
    'a[href]', 'button', 'input', 'textarea', 'select',
    '[role="button"]', '[role="link"]', '[role="tab"]', '[role="menuitem"]',
    '[role="option"]', '[role="switch"]', '[role="checkbox"]', '[role="radio"]',
    '[role="combobox"]', '[role="listbox"]', '[role="menu"]', '[role="menubar"]',
    '[role="treeitem"]', '[role="slider"]', '[role="spinbutton"]',
    '[onclick]', '[contenteditable="true"]',
    '[tabindex]:not([tabindex="-1"])', 'summary', 'details',
    'label[for]', '[data-action]', '[data-click]',
];

// ── HELPER UTILITIES ─────────────────────────────────────
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function isElementVisible(el) {
    if (!el || !(el instanceof HTMLElement)) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
    if (el.hidden || el.closest('[hidden]')) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return false;
    return true;
}

function isElementCovered(el) {
    const rect = el.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    const topEl = document.elementFromPoint(centerX, centerY);
    if (!topEl) return true;
    if (topEl === el || el.contains(topEl) || topEl.contains(el)) return false;
    return true;
}

async function dismissOverlays() {
    let dismissed = 0;
    for (const sel of OVERLAY_DISMISS_SELECTORS) {
        try {
            const el = document.querySelector(sel);
            if (el && el instanceof HTMLElement && isElementVisible(el)) {
                el.click();
                dismissed++;
                await sleep(200);
            }
        } catch (e) { }
    }
    // Also close visible modals via generic close buttons
    const closeButtons = document.querySelectorAll(
        'button[aria-label*="close"], button[aria-label*="Close"], button.close, .modal-close, [data-dismiss="modal"]'
    );
    for (const btn of closeButtons) {
        if (btn instanceof HTMLElement && isElementVisible(btn)) {
            const modal = btn.closest('[role="dialog"], .modal, [class*="modal"]');
            if (modal) { btn.click(); dismissed++; await sleep(200); break; }
        }
    }
    return dismissed;
}

async function waitForElement(selector, timeout) {
    timeout = timeout || ELEMENT_WAIT_TIMEOUT;
    const start = Date.now();
    while (Date.now() - start < timeout) {
        const el = findElement(selector);
        if (el && isElementVisible(el)) return el;
        await sleep(100);
    }
    return null;
}

function resolveSelector(selector) {
    if (!selector) return null;

    // Semantic selectors: text:, button:, input:, link:, option:
    if (selector.startsWith('text:') || selector.startsWith('text=')) {
        return findByText(selector.replace(/^text[:=]/, '').trim());
    }
    if (selector.startsWith('button:')) {
        return findButtonByText(selector.slice(7).trim());
    }
    if (selector.startsWith('input:')) {
        return findInputByLabel(selector.slice(6).trim());
    }
    if (selector.startsWith('link:')) {
        return findLinkByText(selector.slice(5).trim());
    }
    if (selector.startsWith('option:')) {
        return findOptionByText(selector.slice(7).trim());
    }

    // CSS selector
    try { const el = document.querySelector(selector); if (el) return el; } catch (e) { }

    // XPath
    if (selector.startsWith('/') || selector.startsWith('(')) {
        try {
            const xr = document.evaluate(selector, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            if (xr.singleNodeValue) return xr.singleNodeValue;
        } catch (e) { }
    }

    // aria-label
    try {
        const byAria = document.querySelector(`[aria-label="${CSS.escape(selector)}"]`) ||
            document.querySelector(`[aria-label*="${CSS.escape(selector)}" i]`);
        if (byAria) return byAria;
    } catch (e) { }

    // Fall back to text search
    return findByText(selector);
}

function findButtonByText(text) {
    const lower = text.toLowerCase();
    const buttons = document.querySelectorAll('button, [role="button"], input[type="submit"], input[type="button"]');
    for (const btn of buttons) {
        if (!isElementVisible(btn)) continue;
        const label = getLabel(btn).toLowerCase();
        if (label === lower) return btn;
    }
    for (const btn of buttons) {
        if (!isElementVisible(btn)) continue;
        const label = getLabel(btn).toLowerCase();
        if (label.includes(lower)) return btn;
    }
    return null;
}

function findInputByLabel(text) {
    const lower = text.toLowerCase();
    const inputs = document.querySelectorAll('input, textarea, select, [contenteditable="true"]');
    for (const input of inputs) {
        const placeholder = (input.getAttribute('placeholder') || '').toLowerCase();
        const ariaLabel = (input.getAttribute('aria-label') || '').toLowerCase();
        const name = (input.getAttribute('name') || '').toLowerCase();
        const id = (input.id || '').toLowerCase();
        if (placeholder.includes(lower) || ariaLabel.includes(lower) || name.includes(lower) || id.includes(lower)) return input;
        // Check associated label
        if (input.id) {
            const label = document.querySelector(`label[for="${input.id}"]`);
            if (label && label.textContent.toLowerCase().includes(lower)) return input;
        }
    }
    // Check labels wrapping inputs
    const labels = document.querySelectorAll('label');
    for (const label of labels) {
        if (label.textContent.toLowerCase().includes(lower)) {
            const input = label.querySelector('input, textarea, select');
            if (input) return input;
        }
    }
    return null;
}

function findLinkByText(text) {
    const lower = text.toLowerCase();
    const links = document.querySelectorAll('a');
    for (const link of links) {
        if (!isElementVisible(link)) continue;
        const label = (link.innerText || link.getAttribute('aria-label') || link.getAttribute('title') || '').toLowerCase();
        if (label.trim() === lower) return link;
    }
    for (const link of links) {
        if (!isElementVisible(link)) continue;
        const label = (link.innerText || link.getAttribute('aria-label') || link.getAttribute('title') || '').toLowerCase();
        if (label.includes(lower)) return link;
    }
    return null;
}

function findOptionByText(text) {
    const lower = text.toLowerCase();
    // Find in any open listbox/menu/dropdown
    const options = document.querySelectorAll('[role="option"], [role="menuitem"], [role="treeitem"], li[data-value], .dropdown-item, option');
    for (const opt of options) {
        if (!isElementVisible(opt)) continue;
        const label = (opt.textContent || '').trim().toLowerCase();
        if (label === lower || label.includes(lower)) return opt;
    }
    return null;
}

function getNativeValueSetter(el) {
    // Get the correct prototype based on element type
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype :
        el instanceof HTMLSelectElement ? HTMLSelectElement.prototype :
            HTMLInputElement.prototype;
    return Object.getOwnPropertyDescriptor(proto, 'value')?.set ||
        Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
}

function simulateFullClick(el, opts) {
    opts = opts || {};
    const rect = el.getBoundingClientRect();
    const x = opts.x || rect.left + rect.width / 2;
    const y = opts.y || rect.top + rect.height / 2;
    const mouseOpts = { clientX: x, clientY: y, bubbles: true, cancelable: true, view: window };
    el.dispatchEvent(new MouseEvent('mouseenter', { ...mouseOpts, cancelable: false }));
    el.dispatchEvent(new MouseEvent('mouseover', { ...mouseOpts, cancelable: false }));
    el.dispatchEvent(new MouseEvent('mousedown', mouseOpts));
    el.focus();
    el.dispatchEvent(new MouseEvent('mouseup', mouseOpts));
    el.dispatchEvent(new MouseEvent('click', mouseOpts));
    // Also call native click for elements that need it
    if (typeof el.click === 'function') el.click();
}

// ── MAIN MESSAGE HANDLER ────────────────────────────────
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    // Ping for content script readiness
    if (request.action === "PING") {
        sendResponse({ ok: true });
        return true;
    }

    if (request.action === "getPageContext") {
        const mainEl = document.querySelector('main, article, [role="main"], .content, #content') || document.body;
        sendResponse({ content: mainEl.innerText.substring(0, 15000) });
    }

    // ── AGENTIC BROWSER CONTROL ──────────────────────────────
    if (request.action === "agentClick") {
        (async () => {
            try {
                let lastError = '';
                for (let attempt = 0; attempt < MAX_CLICK_RETRIES; attempt++) {
                    if (attempt > 0) {
                        await dismissOverlays();
                        await sleep(CLICK_RETRY_DELAY);
                    }

                    let el = resolveSelector(request.selector);
                    if (!el) {
                        el = await waitForElement(request.selector, 2000);
                    }
                    if (!el) {
                        lastError = `Element not found: ${request.selector}`;
                        continue;
                    }
                    if (!(el instanceof HTMLElement)) {
                        lastError = `Element is not interactive: ${request.selector}`;
                        continue;
                    }
                    if (!isElementVisible(el)) {
                        lastError = `Element is not visible: ${request.selector}`;
                        continue;
                    }

                    // Check coverage and try to dismiss blockers
                    if (isElementCovered(el)) {
                        await dismissOverlays();
                        await sleep(300);
                        if (isElementCovered(el)) {
                            // Try scrolling into better view
                            el.scrollIntoView({ behavior: 'instant', block: 'center' });
                            await sleep(200);
                            if (isElementCovered(el)) {
                                lastError = `Element covered by overlay: ${request.selector}`;
                                continue;
                            }
                        }
                    }

                    // Scroll into view
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(200);

                    // Handle special elements
                    // Dropdown <select> — open it
                    if (el.tagName === 'SELECT') {
                        el.focus();
                        el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
                        sendResponse({ ok: true, summary: `Opened dropdown "${getLabel(el)}"` });
                        return;
                    }

                    // Handle <option> — select it on parent
                    if (el.tagName === 'OPTION') {
                        const select = el.closest('select');
                        if (select) {
                            const nativeSet = getNativeValueSetter(select);
                            if (nativeSet) nativeSet.call(select, el.value);
                            else select.value = el.value;
                            select.dispatchEvent(new Event('input', { bubbles: true }));
                            select.dispatchEvent(new Event('change', { bubbles: true }));
                            sendResponse({ ok: true, summary: `Selected option "${el.textContent.trim()}"` });
                            return;
                        }
                    }

                    // Handle <details>/<summary> — toggle
                    if (el.tagName === 'SUMMARY' || el.closest('summary')) {
                        const summary = el.tagName === 'SUMMARY' ? el : el.closest('summary');
                        summary.click();
                        sendResponse({ ok: true, summary: `Toggled "${getLabel(summary)}"` });
                        return;
                    }

                    // Full mouse event sequence for best compatibility
                    simulateFullClick(el);

                    // Special post-click handling for links
                    if (el instanceof HTMLAnchorElement && el.href && !el.href.startsWith('javascript:')) {
                        await sleep(300);
                        if (window.location.href !== el.href && !el.target) {
                            // Click didn't navigate — force it
                            window.location.href = el.href;
                        }
                        sendResponse({ ok: true, summary: `Clicked link "${getLabel(el)}"` });
                        return;
                    }

                    sendResponse({ ok: true, summary: `Clicked "${getLabel(el)}"` });
                    return;
                }
                sendResponse({ ok: false, error: lastError || `Failed to click: ${request.selector}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentType") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);

                if (!el) {
                    sendResponse({ ok: false, error: "Element not found for: " + request.selector });
                    return;
                }

                // If element is not an input, try to find one inside it
                if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || isContentEditable(el) || isRichTextEditor(el))) {
                    const inner = el.querySelector('input, textarea, [contenteditable="true"]');
                    if (inner) el = inner;
                }

                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                await sleep(100);

                // Click to focus — needed for many modern frameworks
                simulateFullClick(el);
                await sleep(50);
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
                        // Character-by-character fallback for editors that don't support execCommand
                        for (const char of text) {
                            const kc = char.toUpperCase().charCodeAt(0);
                            const keyOpts = { key: char, code: 'Key' + char.toUpperCase(), keyCode: kc, which: kc, bubbles: true, cancelable: true, composed: true };
                            el.dispatchEvent(new KeyboardEvent('keydown', keyOpts));
                            el.dispatchEvent(new InputEvent('beforeinput', {
                                inputType: 'insertText', data: char, bubbles: true, cancelable: true, composed: true
                            }));
                            el.dispatchEvent(new InputEvent('input', {
                                inputType: 'insertText', data: char, bubbles: true, composed: true
                            }));
                            el.dispatchEvent(new KeyboardEvent('keyup', keyOpts));
                            await sleep(TYPING_DELAY_MS);
                        }
                    }
                    sendResponse({ ok: true, summary: `Typed "${text.substring(0, 50)}" in "${getLabel(el)}"` });
                } else {
                    const nativeSet = getNativeValueSetter(el);
                    if (request.clear !== false) {
                        if (nativeSet) nativeSet.call(el, ''); else el.value = '';
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    }

                    // Type character by character for React/Vue/Angular compatibility
                    for (const char of text) {
                        const kc = char.toUpperCase().charCodeAt(0);
                        const keyOpts = { key: char, code: 'Key' + char.toUpperCase(), keyCode: kc, which: kc, bubbles: true, cancelable: true, composed: true };
                        el.dispatchEvent(new KeyboardEvent('keydown', keyOpts));
                        el.dispatchEvent(new KeyboardEvent('keypress', { ...keyOpts, charCode: char.charCodeAt(0) }));
                        el.dispatchEvent(new InputEvent('beforeinput', {
                            inputType: 'insertText', data: char, bubbles: true, cancelable: true
                        }));
                        if (nativeSet) {
                            nativeSet.call(el, el.value + char);
                        } else {
                            el.value += char;
                        }
                        el.dispatchEvent(new InputEvent('input', {
                            inputType: 'insertText', data: char, bubbles: true
                        }));
                        el.dispatchEvent(new KeyboardEvent('keyup', keyOpts));
                        await sleep(TYPING_DELAY_MS);
                    }
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    sendResponse({ ok: true, summary: `Typed "${text.substring(0, 50)}" in "${getLabel(el)}"` });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentScroll") {
        try {
            const amount = request.amount || 300;
            const dir = request.direction || 'down';
            // Check for scrollable container specified by selector
            const target = request.selector ? findElement(request.selector) : null;
            if (target) {
                target.scrollBy({ top: dir === 'up' ? -amount : amount, behavior: 'smooth' });
            } else {
                window.scrollBy({ top: dir === 'up' ? -amount : amount, behavior: 'smooth' });
            }
            sendResponse({ ok: true, summary: `Scrolled ${dir} ${amount}px (pos: ${Math.round(window.scrollY)})` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentDrag") {
        (async () => {
            try {
                const el = findElement(request.selector);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(200);
                    const rect = el.getBoundingClientRect();
                    const startX = rect.left + rect.width / 2;
                    const startY = rect.top + rect.height / 2;
                    const endX = startX + (request.dx || 0);
                    const endY = startY + (request.dy || 0);

                    // Proper drag sequence
                    el.dispatchEvent(new MouseEvent('mousedown', { clientX: startX, clientY: startY, bubbles: true, cancelable: true }));
                    await sleep(50);
                    // Intermediate moves for frameworks that track movement
                    const steps = 5;
                    for (let i = 1; i <= steps; i++) {
                        const x = startX + (endX - startX) * (i / steps);
                        const y = startY + (endY - startY) * (i / steps);
                        el.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true, cancelable: true }));
                        await sleep(20);
                    }
                    el.dispatchEvent(new MouseEvent('mouseup', { clientX: endX, clientY: endY, bubbles: true, cancelable: true }));
                    // Also dispatch drop for drag-and-drop APIs
                    const dropTarget = document.elementFromPoint(endX, endY);
                    if (dropTarget) {
                        dropTarget.dispatchEvent(new MouseEvent('mouseup', { clientX: endX, clientY: endY, bubbles: true }));
                    }
                    sendResponse({ ok: true, summary: `Dragged "${getLabel(el)}" by (${request.dx}, ${request.dy})` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentGetElements") {
        try {
            const selector = INTERACTIVE_SELECTORS.join(', ');
            const nodes = document.querySelectorAll(selector);
            const inViewport = [];
            const offViewport = [];

            nodes.forEach((el) => {
                if (!(el instanceof HTMLElement)) return;
                if (!isElementVisible(el)) return;
                const rect = el.getBoundingClientRect();
                if (rect.width < 5 || rect.height < 5) return;

                const info = {
                    tag: el.tagName.toLowerCase(),
                    type: el.type || el.getAttribute('role') || '',
                    text: getLabel(el).substring(0, 100),
                    id: el.id || '',
                    name: el.name || '',
                    href: el.href || '',
                    placeholder: el.placeholder || '',
                    ariaLabel: el.getAttribute('aria-label') || '',
                    disabled: el.disabled || el.getAttribute('aria-disabled') === 'true',
                    checked: el.checked || el.getAttribute('aria-checked') === 'true',
                    value: (el.tagName === 'SELECT' && el.options && el.selectedIndex >= 0)
                        ? el.options[el.selectedIndex]?.text || '' : '',
                    selector: getCssSelector(el),
                    rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) }
                };

                if (rect.top >= -50 && rect.bottom <= window.innerHeight + 50) {
                    inViewport.push(info);
                } else {
                    offViewport.push(info);
                }
            });

            // Viewport-first, then off-viewport, limited to MAX
            const interactive = [...inViewport, ...offViewport].slice(0, MAX_INTERACTIVE_ELEMENTS).map((el, i) => ({ index: i, ...el }));
            sendResponse({ ok: true, elements: interactive, summary: `${interactive.length} interactive elements (${inViewport.length} in viewport)` });
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

    // ── DROPDOWN / SELECT HANDLING ───────────────────────────

    if (request.action === "agentSelect") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);

                if (el && el.tagName === 'SELECT') {
                    const value = request.value || '';
                    // Try exact value match first
                    let matched = false;
                    for (const opt of el.options) {
                        if (opt.value === value) {
                            const nativeSet = getNativeValueSetter(el);
                            if (nativeSet) nativeSet.call(el, value);
                            else el.value = value;
                            matched = true;
                            break;
                        }
                    }
                    // Try text match
                    if (!matched) {
                        const lower = value.toLowerCase();
                        for (const opt of el.options) {
                            if (opt.textContent.trim().toLowerCase().includes(lower)) {
                                const nativeSet = getNativeValueSetter(el);
                                if (nativeSet) nativeSet.call(el, opt.value);
                                else el.value = opt.value;
                                matched = true;
                                break;
                            }
                        }
                    }
                    if (matched) {
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        sendResponse({ ok: true, summary: `Selected "${value}" in "${getLabel(el)}"` });
                    } else {
                        sendResponse({ ok: false, error: `Option "${value}" not found in dropdown` });
                    }
                } else if (el) {
                    // Custom dropdown — click the option
                    simulateFullClick(el);
                    await sleep(300);
                    // Look for the value in opened dropdown
                    const option = findOptionByText(request.value);
                    if (option) {
                        simulateFullClick(option);
                        sendResponse({ ok: true, summary: `Selected "${request.value}" from custom dropdown` });
                    } else {
                        sendResponse({ ok: false, error: `Option "${request.value}" not found in custom dropdown` });
                    }
                } else {
                    sendResponse({ ok: false, error: "Select/dropdown element not found" });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentSelectDropdownOption") {
        (async () => {
            try {
                // First click the dropdown trigger to open it
                let trigger = resolveSelector(request.selector);
                if (!trigger) trigger = await waitForElement(request.selector, 2000);
                if (!trigger) {
                    sendResponse({ ok: false, error: "Dropdown trigger not found" });
                    return;
                }

                trigger.scrollIntoView({ behavior: 'smooth', block: 'center' });
                await sleep(150);
                simulateFullClick(trigger);
                await sleep(400); // Wait for dropdown to open/animate

                // Now find the option
                const optionText = (request.option || request.value || '').toLowerCase();
                const optionSelectors = [
                    '[role="option"]', '[role="menuitem"]', '[role="treeitem"]',
                    'li[data-value]', '.dropdown-item', '.dropdown-menu li',
                    '.select-option', '.option', '[class*="option"]',
                    '[class*="menu-item"]', '[class*="listbox"] > *',
                    'ul[role="listbox"] li', 'div[role="listbox"] > div',
                    'option'
                ];

                let found = null;
                for (const optSel of optionSelectors) {
                    const opts = document.querySelectorAll(optSel);
                    for (const opt of opts) {
                        if (!isElementVisible(opt)) continue;
                        const text = (opt.textContent || '').trim().toLowerCase();
                        if (text === optionText || text.includes(optionText)) {
                            found = opt;
                            break;
                        }
                    }
                    if (found) break;
                }

                if (found) {
                    found.scrollIntoView({ block: 'nearest' });
                    await sleep(100);
                    simulateFullClick(found);
                    sendResponse({ ok: true, summary: `Selected option "${request.option || request.value}"` });
                } else {
                    sendResponse({ ok: false, error: `Option "${request.option || request.value}" not found in dropdown` });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentExtractText") {
        try {
            const selector = request.selector || 'body';
            let els;
            if (selector === 'body' || selector === 'page') {
                const mainEl = document.querySelector('main, article, [role="main"], .content, #content') || document.body;
                els = [mainEl];
            } else {
                els = document.querySelectorAll(selector);
            }
            const texts = Array.from(els).map(el => el.innerText.trim()).filter(t => t).slice(0, 50);
            const combined = texts.join('\n\n').substring(0, 15000);
            sendResponse({ ok: true, text: combined, summary: `Extracted text from ${texts.length} elements (${combined.length} chars)` });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExtractLinks") {
        try {
            const links = Array.from(document.querySelectorAll('a[href]'))
                .filter(a => isElementVisible(a))
                .slice(0, 200).map(a => ({
                    text: (a.textContent || '').trim().substring(0, 100),
                    href: a.href,
                    selector: getCssSelector(a)
                })).filter(l => l.href && !l.href.startsWith('javascript:'));
            sendResponse({ ok: true, links, summary: `Found ${links.length} visible links` });
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
        (async () => {
            try {
                const timeout = Math.min(request.timeout || 5000, 15000);
                const el = await waitForElement(request.selector, timeout);
                if (el) {
                    sendResponse({ ok: true, summary: `Element "${request.selector}" found` });
                } else {
                    sendResponse({ ok: false, error: `Timeout waiting for "${request.selector}"` });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentFillForm") {
        (async () => {
            try {
                const results = [];
                for (const field of (request.fields || [])) {
                    let el = resolveSelector(field.selector);
                    if (!el) el = await waitForElement(field.selector, 1000);
                    if (el) {
                        el.focus();
                        await sleep(50);
                        if (el.tagName === 'SELECT') {
                            const nativeSet = getNativeValueSetter(el);
                            // Try text match first
                            const lower = (field.value || '').toLowerCase();
                            let optVal = field.value;
                            for (const opt of el.options) {
                                if (opt.textContent.trim().toLowerCase().includes(lower)) {
                                    optVal = opt.value;
                                    break;
                                }
                            }
                            if (nativeSet) nativeSet.call(el, optVal);
                            else el.value = optVal;
                            el.dispatchEvent(new Event('change', { bubbles: true }));
                        } else if (isContentEditable(el) || isRichTextEditor(el)) {
                            document.execCommand('selectAll', false, null);
                            document.execCommand('delete', false, null);
                            document.execCommand('insertText', false, field.value || '');
                        } else {
                            const nativeSet = getNativeValueSetter(el);
                            if (nativeSet) nativeSet.call(el, field.value || '');
                            else el.value = field.value || '';
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
        })();
        return true;
    }

    if (request.action === "agentHover") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(100);
                    const rect = el.getBoundingClientRect();
                    const x = rect.left + rect.width / 2;
                    const y = rect.top + rect.height / 2;
                    el.dispatchEvent(new MouseEvent('mouseenter', { clientX: x, clientY: y, bubbles: true }));
                    el.dispatchEvent(new MouseEvent('mouseover', { clientX: x, clientY: y, bubbles: true }));
                    el.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
                    // Wait to let hover menus/tooltips appear
                    await sleep(request.duration || 300);
                    sendResponse({ ok: true, summary: `Hovered "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentToggleCheckbox") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    // Handle native checkbox/radio
                    if (el.type === 'checkbox' || el.type === 'radio') {
                        simulateFullClick(el);
                        sendResponse({ ok: true, summary: `Toggled ${getLabel(el)} (now ${el.checked ? 'checked' : 'unchecked'})` });
                    }
                    // Handle ARIA checkbox/switch
                    else if (el.getAttribute('role') === 'checkbox' || el.getAttribute('role') === 'switch') {
                        simulateFullClick(el);
                        const checked = el.getAttribute('aria-checked');
                        sendResponse({ ok: true, summary: `Toggled ${getLabel(el)} (aria-checked: ${checked})` });
                    }
                    // Handle label wrapping a checkbox
                    else if (el.tagName === 'LABEL') {
                        const cb = el.querySelector('input[type="checkbox"], input[type="radio"]');
                        if (cb) {
                            simulateFullClick(cb);
                            sendResponse({ ok: true, summary: `Toggled ${getLabel(el)} (now ${cb.checked ? 'checked' : 'unchecked'})` });
                        } else {
                            simulateFullClick(el);
                            sendResponse({ ok: true, summary: `Clicked label "${getLabel(el)}"` });
                        }
                    }
                    else { sendResponse({ ok: false, error: "Not a checkbox/radio/switch element" }); }
                } else { sendResponse({ ok: false, error: "Checkbox/radio not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentGetAttribute") {
        try {
            const el = resolveSelector(request.selector);
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
        (async () => {
            try {
                let el = request.selector ? resolveSelector(request.selector) : null;
                if (!el) el = document.activeElement || document.body;
                const key = request.key || 'Enter';

                const keyCodeMap = {
                    'Enter': 13, 'Tab': 9, 'Escape': 27, 'Backspace': 8, 'Delete': 46,
                    'ArrowUp': 38, 'ArrowDown': 40, 'ArrowLeft': 37, 'ArrowRight': 39,
                    'Home': 36, 'End': 35, 'PageUp': 33, 'PageDown': 34,
                    ' ': 32, 'Space': 32
                };
                const codeMap = {
                    'Enter': 'Enter', 'Tab': 'Tab', 'Escape': 'Escape',
                    'Backspace': 'Backspace', 'Delete': 'Delete',
                    'ArrowUp': 'ArrowUp', 'ArrowDown': 'ArrowDown',
                    'ArrowLeft': 'ArrowLeft', 'ArrowRight': 'ArrowRight',
                    'Home': 'Home', 'End': 'End', 'PageUp': 'PageUp', 'PageDown': 'PageDown',
                    ' ': 'Space', 'Space': 'Space'
                };
                const kc = keyCodeMap[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
                const code = codeMap[key] || (key.length === 1 ? 'Key' + key.toUpperCase() : key);

                const opts = {
                    key, code, keyCode: kc, which: kc, charCode: 0,
                    bubbles: true, cancelable: true, composed: true
                };
                if (request.ctrlKey) opts.ctrlKey = true;
                if (request.shiftKey) opts.shiftKey = true;
                if (request.altKey) opts.altKey = true;
                if (request.metaKey) opts.metaKey = true;

                el.dispatchEvent(new KeyboardEvent('keydown', opts));
                el.dispatchEvent(new KeyboardEvent('keypress', { ...opts, charCode: kc }));
                el.dispatchEvent(new KeyboardEvent('keyup', opts));

                // Programmatically perform the default action since synthetic events are untrusted
                let extra = '';

                if (key === 'Enter' && !request.ctrlKey && !request.metaKey && !request.altKey) {
                    if (el.tagName === 'INPUT' && el.type !== 'textarea') {
                        const form = el.closest('form');
                        if (form) {
                            const submitBtn = form.querySelector('button[type="submit"], input[type="submit"], button:not([type])');
                            if (submitBtn) {
                                submitBtn.click();
                                extra = ' (clicked submit)';
                            } else if (form.requestSubmit) {
                                form.requestSubmit();
                                extra = ' (submitted form)';
                            } else {
                                form.submit();
                                extra = ' (submitted form)';
                            }
                        }
                    } else if (el.tagName === 'TEXTAREA') {
                        // Insert newline in textarea
                        const start = el.selectionStart || 0;
                        const end = el.selectionEnd || 0;
                        const nativeSet = getNativeValueSetter(el);
                        const newVal = el.value.substring(0, start) + '\n' + el.value.substring(end);
                        if (nativeSet) nativeSet.call(el, newVal); else el.value = newVal;
                        el.selectionStart = el.selectionEnd = start + 1;
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        extra = ' (inserted newline)';
                    } else if (isContentEditable(el) || isRichTextEditor(el)) {
                        document.execCommand('insertLineBreak', false, null);
                        extra = ' (inserted line break)';
                    }
                } else if (key === 'Backspace') {
                    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        const start = el.selectionStart || 0;
                        const end = el.selectionEnd || 0;
                        const nativeSet = getNativeValueSetter(el);
                        if (start !== end) {
                            const newVal = el.value.substring(0, start) + el.value.substring(end);
                            if (nativeSet) nativeSet.call(el, newVal); else el.value = newVal;
                            el.selectionStart = el.selectionEnd = start;
                        } else if (start > 0) {
                            const newVal = el.value.substring(0, start - 1) + el.value.substring(start);
                            if (nativeSet) nativeSet.call(el, newVal); else el.value = newVal;
                            el.selectionStart = el.selectionEnd = start - 1;
                        }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        extra = ' (deleted char)';
                    } else if (isContentEditable(el) || isRichTextEditor(el)) {
                        document.execCommand('delete', false, null);
                        extra = ' (deleted in editor)';
                    }
                } else if (key === 'Delete') {
                    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        const start = el.selectionStart || 0;
                        const end = el.selectionEnd || 0;
                        const nativeSet = getNativeValueSetter(el);
                        if (start !== end) {
                            const newVal = el.value.substring(0, start) + el.value.substring(end);
                            if (nativeSet) nativeSet.call(el, newVal); else el.value = newVal;
                            el.selectionStart = el.selectionEnd = start;
                        } else if (start < el.value.length) {
                            const newVal = el.value.substring(0, start) + el.value.substring(start + 1);
                            if (nativeSet) nativeSet.call(el, newVal); else el.value = newVal;
                            el.selectionStart = el.selectionEnd = start;
                        }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        extra = ' (deleted char)';
                    } else if (isContentEditable(el) || isRichTextEditor(el)) {
                        document.execCommand('forwardDelete', false, null);
                        extra = ' (deleted in editor)';
                    }
                } else if (key === 'Tab') {
                    const focusable = Array.from(document.querySelectorAll(
                        'a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
                    )).filter(e => e.offsetParent !== null);
                    const idx = focusable.indexOf(el);
                    if (idx >= 0) {
                        const next = request.shiftKey ? focusable[idx - 1] : focusable[idx + 1];
                        if (next) { next.focus(); extra = ` (focused ${getLabel(next).substring(0, 30)})`; }
                    }
                } else if (key === 'Escape') {
                    el.blur();
                    extra = ' (blurred element)';
                } else if (key === 'a' && (request.ctrlKey || request.metaKey)) {
                    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        el.select();
                        extra = ' (selected all)';
                    } else {
                        document.execCommand('selectAll', false, null);
                        extra = ' (selected all)';
                    }
                } else if (key === ' ' || key === 'Space') {
                    // Space on buttons/checkboxes should click them
                    if (el.tagName === 'BUTTON' || el.type === 'checkbox' || el.type === 'radio' || el.getAttribute('role') === 'button') {
                        el.click();
                        extra = ' (activated element)';
                    }
                }

                const modifiers = (request.metaKey ? 'Cmd+' : '') + (request.ctrlKey ? 'Ctrl+' : '') +
                    (request.shiftKey ? 'Shift+' : '') + (request.altKey ? 'Alt+' : '');
                sendResponse({ ok: true, summary: `Pressed ${modifiers}${key}${extra}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentClearInput") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.focus();
                    if (isContentEditable(el) || isRichTextEditor(el)) {
                        document.execCommand('selectAll', false, null);
                        document.execCommand('delete', false, null);
                    } else {
                        const nativeSet = getNativeValueSetter(el);
                        if (nativeSet) nativeSet.call(el, '');
                        else el.value = '';
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    sendResponse({ ok: true, summary: `Cleared "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentSelectText") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        el.focus();
                        el.select();
                    } else {
                        const range = document.createRange();
                        range.selectNodeContents(el);
                        const sel = window.getSelection();
                        sel.removeAllRanges();
                        sel.addRange(range);
                    }
                    sendResponse({ ok: true, summary: `Selected text in "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
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
            const el = resolveSelector(request.selector);
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
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: request.block || 'center' });
                    await sleep(300);
                    sendResponse({ ok: true, summary: `Scrolled to "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentDoubleClick") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(150);
                    const rect = el.getBoundingClientRect();
                    const x = rect.left + rect.width / 2;
                    const y = rect.top + rect.height / 2;
                    const mouseOpts = { clientX: x, clientY: y, bubbles: true, cancelable: true, view: window };
                    el.dispatchEvent(new MouseEvent('mousedown', mouseOpts));
                    el.dispatchEvent(new MouseEvent('mouseup', mouseOpts));
                    el.dispatchEvent(new MouseEvent('click', mouseOpts));
                    el.dispatchEvent(new MouseEvent('mousedown', { ...mouseOpts, detail: 2 }));
                    el.dispatchEvent(new MouseEvent('mouseup', { ...mouseOpts, detail: 2 }));
                    el.dispatchEvent(new MouseEvent('click', { ...mouseOpts, detail: 2 }));
                    el.dispatchEvent(new MouseEvent('dblclick', { ...mouseOpts, detail: 2 }));
                    sendResponse({ ok: true, summary: `Double-clicked "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentRightClick") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(150);
                    const rect = el.getBoundingClientRect();
                    const x = rect.left + rect.width / 2;
                    const y = rect.top + rect.height / 2;
                    const mouseOpts = { clientX: x, clientY: y, bubbles: true, cancelable: true, view: window, button: 2, buttons: 2 };
                    el.dispatchEvent(new MouseEvent('mousedown', mouseOpts));
                    el.dispatchEvent(new MouseEvent('mouseup', mouseOpts));
                    el.dispatchEvent(new MouseEvent('contextmenu', mouseOpts));
                    sendResponse({ ok: true, summary: `Right-clicked "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentFocusElement") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(100);
                    simulateFullClick(el);
                    el.focus();
                    sendResponse({ ok: true, summary: `Focused "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    // ── ADVANCED AGENTIC ACTIONS ─────────────────────────────

    if (request.action === "agentDismissPopups") {
        (async () => {
            try {
                let dismissed = await dismissOverlays();
                // Also remove fixed/sticky overlays that block the page
                const allEls = document.querySelectorAll('div, section, aside');
                for (const el of allEls) {
                    const style = window.getComputedStyle(el);
                    if ((style.position === 'fixed' || style.position === 'sticky') && parseInt(style.zIndex) > 999) {
                        const rect = el.getBoundingClientRect();
                        if (rect.width > window.innerWidth * 0.5 && rect.height > 50) {
                            el.remove();
                            dismissed++;
                        }
                    }
                }
                sendResponse({ ok: true, summary: `Dismissed ${dismissed} popup(s)/overlay(s)` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentPaste") {
        (async () => {
            try {
                let el = request.selector ? resolveSelector(request.selector) : null;
                if (!el && request.selector) el = await waitForElement(request.selector, 2000);
                if (!el) el = document.activeElement;
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(100);
                    simulateFullClick(el);
                    el.focus();
                    const text = request.text || '';
                    if (isContentEditable(el) || isRichTextEditor(el)) {
                        document.execCommand('insertText', false, text);
                    } else {
                        const nativeSet = getNativeValueSetter(el);
                        const curVal = el.value || '';
                        const start = el.selectionStart || curVal.length;
                        const end = el.selectionEnd || curVal.length;
                        const newVal = curVal.substring(0, start) + text + curVal.substring(end);
                        if (nativeSet) nativeSet.call(el, newVal);
                        else el.value = newVal;
                        el.selectionStart = el.selectionEnd = start + text.length;
                        el.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', data: text, bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    // Also dispatch paste event for frameworks that listen
                    try {
                        const dt = new DataTransfer();
                        dt.setData('text/plain', text);
                        el.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt }));
                    } catch (e) { }
                    sendResponse({ ok: true, summary: `Pasted "${text.substring(0, 50)}" into "${getLabel(el)}"` });
                } else { sendResponse({ ok: false, error: "No element to paste into" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
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
            // JSON-LD
            const jsonLd = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
            data.jsonLd = jsonLd.map(s => { try { return JSON.parse(s.textContent); } catch (e) { return null; } }).filter(Boolean);
            // OpenGraph
            data.openGraph = {};
            document.querySelectorAll('meta[property^="og:"]').forEach(m => {
                data.openGraph[m.getAttribute('property')] = m.content;
            });
            // Twitter Cards
            data.twitterCard = {};
            document.querySelectorAll('meta[name^="twitter:"]').forEach(m => {
                data.twitterCard[m.getAttribute('name')] = m.content;
            });
            // Microdata
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
            // Detect potential blockers
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
            // Get headings structure
            summary.headings = Array.from(document.querySelectorAll('h1, h2, h3')).slice(0, 30).map(h => ({
                level: parseInt(h.tagName[1]),
                text: h.textContent.trim().substring(0, 100)
            }));
            // Main content
            const mainEl = document.querySelector('main, article, [role="main"], .content, #content') || document.body;
            summary.mainText = mainEl.innerText.trim().substring(0, 5000);
            // Navigation links
            const nav = document.querySelector('nav, [role="navigation"]');
            summary.navLinks = nav ? Array.from(nav.querySelectorAll('a')).slice(0, 20).map(a => ({
                text: a.textContent.trim().substring(0, 50), href: a.href
            })) : [];
            // Counts
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
            const el = resolveSelector(request.selector);
            if (el && el.tagName === 'SELECT') {
                const options = Array.from(el.options).map(o => ({
                    value: o.value,
                    text: o.textContent.trim(),
                    selected: o.selected,
                    disabled: o.disabled
                }));
                sendResponse({ ok: true, options, selected: el.value, summary: `${options.length} options in "${getLabel(el)}"` });
            } else {
                // Handle custom dropdowns — find visible option-like elements
                const options = [];
                const optEls = document.querySelectorAll('[role="option"], [role="menuitem"], .dropdown-item, li[data-value]');
                for (const opt of optEls) {
                    if (!isElementVisible(opt)) continue;
                    options.push({
                        value: opt.getAttribute('data-value') || opt.textContent.trim(),
                        text: opt.textContent.trim(),
                        selected: opt.getAttribute('aria-selected') === 'true',
                        disabled: opt.getAttribute('aria-disabled') === 'true'
                    });
                }
                if (options.length > 0) {
                    sendResponse({ ok: true, options, summary: `${options.length} custom dropdown options` });
                } else {
                    sendResponse({ ok: false, error: "Select/dropdown element not found" });
                }
            }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentSetValue") {
        (async () => {
            try {
                let el = resolveSelector(request.selector);
                if (!el) el = await waitForElement(request.selector, 2000);
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    await sleep(100);
                    simulateFullClick(el);
                    el.focus();
                    const nativeSet = getNativeValueSetter(el);
                    if (nativeSet) nativeSet.call(el, request.value || '');
                    else el.value = request.value || '';
                    el.dispatchEvent(new InputEvent('input', { inputType: 'insertText', bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    sendResponse({ ok: true, summary: `Set value of "${getLabel(el)}" to "${(request.value || '').substring(0, 50)}"` });
                } else { sendResponse({ ok: false, error: "Element not found" }); }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
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
                        chrome.runtime.sendMessage({ ...subAction, action: 'agent' + subAction.type.charAt(0).toUpperCase() + subAction.type.slice(1) }, resolve);
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
                if (el.children.length > 3) continue; // skip containers
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
            const el = resolveSelector(request.selector);
            if (el) {
                const label = getLabel(el);
                el.remove();
                sendResponse({ ok: true, summary: `Removed "${label}"` });
            } else { sendResponse({ ok: false, error: "Element not found" }); }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetElementInfo") {
        try {
            const el = resolveSelector(request.selector);
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
                        checked: el.checked || el.getAttribute('aria-checked') === 'true' || false,
                        visible: isElementVisible(el),
                        covered: isElementCovered(el),
                        editable: isContentEditable(el) || isRichTextEditor(el),
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

    // ── FULL PAGE CONTEXT (for LLM) ─────────────────────────
    if (request.action === "agentGetDOMState") {
        try {
            const selector = INTERACTIVE_SELECTORS.join(', ');
            const nodes = document.querySelectorAll(selector);
            const elements = [];

            nodes.forEach((el) => {
                if (!(el instanceof HTMLElement)) return;
                if (!isElementVisible(el)) return;
                const rect = el.getBoundingClientRect();
                if (rect.width < 3 || rect.height < 3) return;

                const info = {
                    tag: el.tagName.toLowerCase(),
                    role: el.getAttribute('role') || el.type || '',
                    text: getLabel(el).substring(0, 120),
                    selector: getCssSelector(el),
                    inViewport: rect.top >= -50 && rect.bottom <= window.innerHeight + 50,
                    covered: isElementCovered(el),
                    rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) }
                };
                // Add extra data for specific element types
                if (el.href) info.href = el.href;
                if (el.value !== undefined && el.value !== '') info.value = el.value.substring(0, 100);
                if (el.placeholder) info.placeholder = el.placeholder;
                if (el.disabled || el.getAttribute('aria-disabled') === 'true') info.disabled = true;
                if (el.checked || el.getAttribute('aria-checked') === 'true') info.checked = true;
                if (el.getAttribute('aria-expanded')) info.expanded = el.getAttribute('aria-expanded') === 'true';
                if (el.getAttribute('aria-selected')) info.selected = el.getAttribute('aria-selected') === 'true';
                if (isContentEditable(el) || isRichTextEditor(el)) info.editable = true;

                elements.push(info);
            });

            // Sort: viewport first, then by position
            elements.sort((a, b) => {
                if (a.inViewport !== b.inViewport) return a.inViewport ? -1 : 1;
                return a.rect.y - b.rect.y || a.rect.x - b.rect.x;
            });

            const limited = elements.slice(0, 100).map((el, i) => ({ index: i, ...el }));

            sendResponse({
                ok: true,
                state: {
                    url: window.location.href,
                    title: document.title,
                    viewport: { width: window.innerWidth, height: window.innerHeight },
                    scroll: { y: Math.round(window.scrollY), maxY: Math.round(document.body.scrollHeight - window.innerHeight) },
                    elements: limited
                },
                summary: `DOM state: ${limited.length} elements (${limited.filter(e => e.inViewport).length} in viewport)`
            });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentGetFullContext") {
        try {
            const mainEl = document.querySelector('main, article, [role="main"], .content, #content') || document.body;
            // Get visible text, headings, and structure
            const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).slice(0, 50).map(h => ({
                level: parseInt(h.tagName[1]),
                text: h.textContent.trim().substring(0, 150)
            }));
            // Active element info
            const active = document.activeElement;
            const activeInfo = active && active !== document.body ? {
                tag: active.tagName.toLowerCase(),
                role: active.getAttribute('role') || active.type || '',
                label: getLabel(active),
                value: active.value || '',
                editable: isContentEditable(active) || isRichTextEditor(active)
            } : null;
            // Forms summary
            const forms = Array.from(document.forms).slice(0, 10).map(form => {
                const fields = Array.from(form.querySelectorAll('input, textarea, select')).slice(0, 20).map(f => ({
                    type: f.type || f.tagName.toLowerCase(),
                    name: f.name || f.id || '',
                    label: getLabel(f).substring(0, 50),
                    value: f.type === 'password' ? '***' : (f.value || '').substring(0, 100),
                    required: f.required || false
                }));
                return { action: form.action || '', method: form.method || 'get', fields };
            });
            // Alerts/dialogs
            const dialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], .modal, [class*="modal"]'))
                .filter(d => isElementVisible(d))
                .slice(0, 5)
                .map(d => ({ text: d.textContent.trim().substring(0, 300), selector: getCssSelector(d) }));

            sendResponse({
                ok: true,
                context: {
                    url: window.location.href,
                    title: document.title,
                    description: document.querySelector('meta[name="description"]')?.content || '',
                    headings,
                    mainText: mainEl.innerText.trim().substring(0, 10000),
                    activeElement: activeInfo,
                    forms,
                    dialogs,
                    hasOverlay: dialogs.length > 0,
                    scroll: { y: Math.round(window.scrollY), maxY: Math.round(document.body.scrollHeight - window.innerHeight), pct: Math.round(100 * window.scrollY / Math.max(1, document.body.scrollHeight - window.innerHeight)) }
                },
                summary: `Full context: "${document.title}" — ${headings.length} headings, ${forms.length} forms, ${dialogs.length} dialogs`
            });
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    if (request.action === "agentExecuteScript") {
        // Execute a simple DOM query and return results (read-only, no eval)
        try {
            const query = request.query || '';
            if (query.startsWith('count:')) {
                const sel = query.slice(6).trim();
                const count = document.querySelectorAll(sel).length;
                sendResponse({ ok: true, result: count, summary: `Found ${count} elements matching "${sel}"` });
            } else if (query.startsWith('exists:')) {
                const sel = query.slice(7).trim();
                const exists = !!resolveSelector(sel);
                sendResponse({ ok: true, result: exists, summary: `Element "${sel}" ${exists ? 'exists' : 'not found'}` });
            } else if (query.startsWith('text:')) {
                const sel = query.slice(5).trim();
                const el = resolveSelector(sel);
                sendResponse({ ok: true, result: el ? el.textContent.trim().substring(0, 2000) : null, summary: el ? `Text: "${el.textContent.trim().substring(0, 100)}"` : 'Element not found' });
            } else if (query.startsWith('value:')) {
                const sel = query.slice(6).trim();
                const el = resolveSelector(sel);
                sendResponse({ ok: true, result: el ? (el.value || el.textContent?.trim() || '') : null, summary: el ? `Value: "${(el.value || '').substring(0, 100)}"` : 'Element not found' });
            } else {
                sendResponse({ ok: false, error: 'Query must start with count:, exists:, text:, or value:' });
            }
        } catch (e) { sendResponse({ ok: false, error: e.message }); }
    }

    return true;
});

// ── HELPERS ──────────────────────────────────────────────
// findElement is now an alias for resolveSelector (legacy compatibility)
function findElement(selector) {
    return resolveSelector(selector);
}

function findByText(text) {
    if (!text) return null;
    const lowerText = text.toLowerCase().trim();

    // Priority 1: Interactive elements — exact match (visible first)
    const interactive = document.querySelectorAll(
        'a, button, input, textarea, select, [role="button"], [role="link"], [role="tab"], ' +
        '[role="menuitem"], [role="option"], [role="switch"], [role="checkbox"], [role="radio"], ' +
        '[role="combobox"], [role="treeitem"], summary, label, [onclick], [tabindex]:not([tabindex="-1"])'
    );
    for (const el of interactive) {
        if (!isElementVisible(el)) continue;
        if (getLabel(el).toLowerCase().trim() === lowerText) return el;
    }

    // Priority 2: Interactive elements — partial match (visible first)
    for (const el of interactive) {
        if (!isElementVisible(el)) continue;
        if (getLabel(el).toLowerCase().includes(lowerText)) return el;
    }

    // Priority 3: Exact text match on any visible text element
    const allVisible = document.querySelectorAll(
        'h1, h2, h3, h4, h5, h6, span, div, p, li, td, th, nav, section, details, summary, ' +
        '[onclick], [tabindex], [data-testid], [data-action]'
    );
    for (const el of allVisible) {
        if (!isElementVisible(el)) continue;
        const directText = getDirectText(el).toLowerCase().trim();
        if (directText === lowerText) return el;
    }

    // Priority 4: Partial text match on visible elements (prefer tighter matches)
    let bestMatch = null;
    let bestLen = Infinity;
    for (const el of allVisible) {
        if (!isElementVisible(el)) continue;
        const directText = getDirectText(el).toLowerCase().trim();
        if (directText.includes(lowerText) && directText.length < lowerText.length * 3 && directText.length < bestLen) {
            bestMatch = el;
            bestLen = directText.length;
        }
    }
    if (bestMatch) return bestMatch;

    // Priority 5: Fallback — allow non-visible interactive (e.g. inside hidden parent but still valid)
    for (const el of interactive) {
        if (getLabel(el).toLowerCase().trim() === lowerText) return el;
    }

    // Priority 6: XPath text search
    try {
        const escaped = lowerText.replace(/'/g, "\\'");
        const xpathResult = document.evaluate(
            `//*[contains(translate(text(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '${escaped}')]`,
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
    // Prefer aria-label / title / placeholder over deep textContent for containers
    const ariaLabel = el.getAttribute('aria-label');
    if (ariaLabel) return ariaLabel.trim().substring(0, 80);
    const title = el.getAttribute('title');
    if (title) return title.trim().substring(0, 80);
    const placeholder = el.getAttribute('placeholder');
    if (placeholder) return placeholder.trim().substring(0, 80);
    const alt = el.getAttribute('alt');
    if (alt) return alt.trim().substring(0, 80);
    // For inputs, show value hint
    if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.value) {
        return el.value.trim().substring(0, 80);
    }
    // Use innerText to avoid hidden content, fall back to textContent
    const text = (el.innerText || el.textContent || '').trim();
    if (text) return text.substring(0, 80);
    return el.tagName;
}

function getCssSelector(el) {
    if (!el || el === document.body || el === document.documentElement) return 'body';
    // Strategy 1: ID
    if (el.id) return '#' + CSS.escape(el.id);
    // Strategy 2: data-testid
    const testId = el.getAttribute('data-testid');
    if (testId) return `[data-testid="${CSS.escape(testId)}"]`;
    // Strategy 3: name attribute (for form elements)
    if (el.name && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT')) {
        return `${el.tagName.toLowerCase()}[name="${CSS.escape(el.name)}"]`;
    }
    // Strategy 4: aria-label
    const ariaLabel = el.getAttribute('aria-label');
    if (ariaLabel) return `${el.tagName.toLowerCase()}[aria-label="${CSS.escape(ariaLabel)}"]`;
    // Strategy 5: Unique class combination (short, non-generated classes)
    if (el.className && typeof el.className === 'string') {
        const cls = el.className.trim().split(/\s+/)
            .filter(c => c.length > 1 && c.length < 30 && !/^[a-z]{1,2}\d|^css-|^sc-|^_|^\d/.test(c))
            .slice(0, 3);
        if (cls.length > 0) {
            const sel = el.tagName.toLowerCase() + '.' + cls.map(CSS.escape).join('.');
            try {
                if (document.querySelectorAll(sel).length === 1) return sel;
            } catch (e) { }
        }
    }
    // Strategy 6: nth-child path (robust but verbose)
    const path = [];
    let current = el;
    while (current && current !== document.body && current !== document.documentElement) {
        let selector = current.tagName.toLowerCase();
        if (current.id) {
            path.unshift('#' + CSS.escape(current.id));
            break;
        }
        const parent = current.parentElement;
        if (parent) {
            const siblings = Array.from(parent.children).filter(c => c.tagName === current.tagName);
            if (siblings.length > 1) {
                const idx = siblings.indexOf(current) + 1;
                selector += `:nth-of-type(${idx})`;
            }
        }
        path.unshift(selector);
        current = parent;
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
    // Google Docs
    if (el.classList.contains('docs-texteventtarget') || el.closest('.docs-texteventtarget')) return true;
    if (el.closest('.kix-appview-editor')) return true;
    // Generic rich text editor roles
    if (el.getAttribute('role') === 'textbox' && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return true;
    // Notion, Confluence, and similar block editors
    if (el.closest('[data-block-id]') || el.closest('[data-content-editable-leaf]')) return true;
    // CodeMirror / Monaco
    if (el.closest('.cm-editor') || el.closest('.monaco-editor')) return true;
    // ProseMirror (used by many editors)
    if (el.closest('.ProseMirror')) return true;
    // Slate.js editors
    if (el.closest('[data-slate-editor]')) return true;
    // TinyMCE / CKEditor
    if (el.closest('.mce-content-body') || el.closest('.ck-editor__editable')) return true;
    // Quill editor
    if (el.closest('.ql-editor')) return true;
    // Draft.js
    if (el.closest('[data-contents]')?.closest('.DraftEditor-root')) return true;
    return false;
}
