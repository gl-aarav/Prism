#!/usr/bin/env node
// Test script — runs both Puppeteer and Playwright on Google Chrome
const PuppeteerEngine = require('./puppeteer-engine');
const PlaywrightEngine = require('./playwright-engine');

const target = process.argv[2] || 'both'; // puppeteer | playwright | both
const TEST_URL = 'https://www.google.com';

async function testEngine(Engine, name) {
    console.log(`\n── Testing ${name} ──`);
    const engine = new Engine();

    try {
        console.log('  Launching Chrome...');
        await engine.launch();
        console.log('  ✓ Browser launched');

        console.log(`  Navigating to ${TEST_URL}...`);
        const nav = await engine.navigate(TEST_URL);
        console.log(`  ✓ Page loaded: ${nav.title}`);

        console.log('  Taking screenshot...');
        const b64 = await engine.screenshot();
        console.log(`  ✓ Screenshot captured (${Math.round(b64.length / 1024)} KB base64)`);

        console.log('  Getting DOM tree...');
        const dom = await engine.getDomTree();
        console.log(`  ✓ Found ${dom.elements.length} interactive elements`);

        console.log('  Getting page info...');
        const info = await engine.getPageInfo();
        console.log(`  ✓ URL: ${info.url}, Title: ${info.title}`);

        console.log('  Typing in search box...');
        const searchSel = 'textarea[name="q"], input[name="q"]';
        await engine.type(searchSel, 'Prism AI browser automation');
        console.log('  ✓ Typed search query');

        console.log('  Pressing Enter...');
        await engine.pressKey('Enter');
        await new Promise(r => setTimeout(r, 2000));
        console.log('  ✓ Search submitted');

        const results = await engine.getPageInfo();
        console.log(`  ✓ Results page: ${results.url}`);

        console.log('  Scrolling down...');
        await engine.scroll('down', 500);
        console.log('  ✓ Scrolled');

        console.log('  Closing browser...');
        await engine.close();
        console.log(`  ✓ ${name} test PASSED\n`);

        return true;
    } catch (err) {
        console.error(`  ✗ ${name} test FAILED: ${err.message}\n`);
        await engine.close().catch(() => { });
        return false;
    }
}

(async () => {
    console.log('╔══════════════════════════════════════╗');
    console.log('║  Prism Browser Automation Test Suite  ║');
    console.log('╚══════════════════════════════════════╝');

    const results = {};

    if (target === 'puppeteer' || target === 'both') {
        results.puppeteer = await testEngine(PuppeteerEngine, 'Puppeteer');
    }
    if (target === 'playwright' || target === 'both') {
        results.playwright = await testEngine(PlaywrightEngine, 'Playwright');
    }

    console.log('── Summary ──');
    for (const [name, passed] of Object.entries(results)) {
        console.log(`  ${passed ? '✓' : '✗'} ${name}`);
    }

    const allPassed = Object.values(results).every(Boolean);
    process.exit(allPassed ? 0 : 1);
})();
