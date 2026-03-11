// Playwright Engine — browser automation via Microsoft Playwright (Chrome)
const { chromium } = require('playwright');
const path = require('path');

const PROFILE_DIR = path.join(__dirname, '.chrome-profile-playwright');

class PlaywrightEngine {
    constructor() {
        this.browser = null;
        this.context = null;
        this.page = null;
    }

    get name() { return 'playwright'; }

    async launch(options = {}) {
        // launchPersistentContext keeps cookies, logins, and sessions across launches
        this.context = await chromium.launchPersistentContext(PROFILE_DIR, {
            headless: false,
            channel: 'chrome',
            viewport: null,
            args: [
                '--window-size=1280,900',
                '--disable-blink-features=AutomationControlled',
                ...(options.args || []),
            ],
        });
        this.browser = this.context.browser();
        const pages = this.context.pages();
        this.page = pages[0] || await this.context.newPage();
        // Track new pages so we always know the latest active tab
        this.context.on('page', (newPage) => {
            this.page = newPage;
        });
        return { status: 'launched', engine: 'playwright' };
    }

    async navigate(url) {
        if (!this.page) throw new Error('Browser not launched');
        await this.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        return { status: 'navigated', url: this.page.url(), title: await this.page.title() };
    }

    async screenshot() {
        if (!this.page) throw new Error('Browser not launched');
        // Use current tracked page directly — no tab cycling
        try {
            const buffer = await this.page.screenshot({ type: 'png' });
            return buffer.toString('base64');
        } catch {
            // Page may have closed, fall back to last available page
            const pages = this.context.pages();
            if (pages.length > 0) {
                this.page = pages[pages.length - 1];
                const buffer = await this.page.screenshot({ type: 'png' });
                return buffer.toString('base64');
            }
            throw new Error('No pages available');
        }
    }

    async click(selector) {
        if (!this.page) throw new Error('Browser not launched');
        await this.page.click(selector, { timeout: 5000 });
        return { status: 'clicked', selector };
    }

    async type(selector, text) {
        if (!this.page) throw new Error('Browser not launched');
        await this.page.fill(selector, '');
        await this.page.type(selector, text, { delay: 15 });
        return { status: 'typed', selector, text };
    }

    async pressKey(key) {
        if (!this.page) throw new Error('Browser not launched');
        await this.page.keyboard.press(key);
        return { status: 'pressed', key };
    }

    async scroll(direction, amount) {
        if (!this.page) throw new Error('Browser not launched');
        const dy = direction === 'up' ? -amount : amount;
        await this.page.evaluate((dy) => window.scrollBy(0, dy), dy);
        return { status: 'scrolled', direction, amount };
    }

    async getDomTree() {
        if (!this.page) throw new Error('Browser not launched');
        return await this.page.evaluate(() => {
            const elements = [];
            const interactive = document.querySelectorAll(
                'a, button, input, select, textarea, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [onclick], [contenteditable="true"]'
            );
            let idx = 0;
            interactive.forEach(el => {
                if (idx >= 60) return;
                const rect = el.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) return;
                const tag = el.tagName.toLowerCase();
                const text = (el.textContent || '').trim().slice(0, 80);
                const id = el.id ? `#${el.id}` : '';
                const cls = el.className && typeof el.className === 'string'
                    ? `.${el.className.split(/\s+/).slice(0, 2).join('.')}`
                    : '';
                elements.push({
                    index: idx++,
                    tag,
                    selector: `${tag}${id}${cls}`,
                    text,
                    type: el.type || '',
                    role: el.getAttribute('role') || '',
                    href: el.href || '',
                    placeholder: el.placeholder || '',
                });
            });
            return {
                url: location.href,
                title: document.title,
                elements,
            };
        });
    }

    async evaluate(code) {
        if (!this.page) throw new Error('Browser not launched');
        return await this.page.evaluate(code);
    }

    async waitForSelector(selector, timeout = 5000) {
        if (!this.page) throw new Error('Browser not launched');
        await this.page.waitForSelector(selector, { timeout });
        return { status: 'found', selector };
    }

    async getPageInfo() {
        if (!this.page) throw new Error('Browser not launched');
        return {
            url: this.page.url(),
            title: await this.page.title(),
        };
    }

    async newTab(url) {
        if (!this.context) throw new Error('Browser not launched');
        this.page = await this.context.newPage();
        if (url) await this.page.goto(url, { waitUntil: 'domcontentloaded' });
        return { status: 'opened', url: url || 'about:blank' };
    }

    async getTabs() {
        if (!this.context) throw new Error('Browser not launched');
        const pages = this.context.pages();
        const tabs = [];
        for (let i = 0; i < pages.length; i++) {
            let title = '';
            try { title = await pages[i].title(); } catch { }
            tabs.push({ index: i, url: pages[i].url(), title });
        }
        return tabs;
    }

    async getTabContent(index) {
        if (!this.context) throw new Error('Browser not launched');
        const pages = this.context.pages();
        if (index < 0 || index >= pages.length) throw new Error('Tab index out of range');
        const p = pages[index];
        const content = await p.evaluate(() => {
            return {
                url: location.href,
                title: document.title,
                content: document.body ? document.body.innerText.substring(0, 20000) : '',
            };
        });
        return content;
    }

    async switchTab(index) {
        if (!this.context) throw new Error('Browser not launched');
        const pages = this.context.pages();
        if (index < 0 || index >= pages.length) throw new Error('Tab index out of range');
        this.page = pages[index];
        await this.page.bringToFront();
        return { status: 'switched', index };
    }

    async close() {
        if (this.context) {
            await this.context.close();
            this.browser = null;
            this.context = null;
            this.page = null;
        }
        return { status: 'closed' };
    }

    isOpen() {
        return !!this.context;
    }
}

module.exports = PlaywrightEngine;
