// Prism Safari Extension — Background Service Worker
// Safari-compatible version (no sidePanel, no tabGroups)

const api = typeof browser !== 'undefined' ? browser : chrome;


// Wait for content script to be ready in a tab
async function waitForContentScript(tabId, timeout) {
    timeout = timeout || 5000;
    const start = Date.now();
    while (Date.now() - start < timeout) {
        try {
            const response = await api.tabs.sendMessage(tabId, { action: 'PING' });
            if (response && response.ok) return true;
        } catch (e) { /* content script not ready yet */ }
        await new Promise(r => setTimeout(r, 200));
    }
    return false;
}

// Wait for tab to finish loading
function waitForTabLoad(tabId, timeout) {
    timeout = timeout || 15000;
    return new Promise((resolve) => {
        const start = Date.now();
        const check = () => {
            api.tabs.get(tabId, (tab) => {
                if (api.runtime.lastError) { resolve(false); return; }
                if (tab.status === 'complete') { resolve(true); return; }
                if (Date.now() - start > timeout) { resolve(false); return; }
                setTimeout(check, 300);
            });
        };
        check();
    });
}

api.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "agentOpenTab") {
        (async () => {
            try {
                const tab = await new Promise(resolve =>
                    api.tabs.create({ url: request.url, active: request.active !== false }, resolve)
                );
                // Wait for the tab to load if active
                if (request.active !== false && request.waitForLoad !== false) {
                    await waitForTabLoad(tab.id, 10000);
                    await waitForContentScript(tab.id, 3000);
                }
                sendResponse({ ok: true, tabId: tab.id, summary: `Opened tab: ${request.url}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentCloseTab") {
        api.tabs.remove(request.tabId || sender.tab?.id, () => {
            sendResponse({ ok: true, summary: "Closed tab" });
        });
        return true;
    }

    if (request.action === "agentGetTabs") {
        api.tabs.query({}, (tabs) => {
            const tabList = tabs.map(t => ({
                id: t.id, title: t.title, url: t.url, active: t.active,
                windowId: t.windowId, index: t.index, pinned: t.pinned,
                muted: t.mutedInfo?.muted || false, audible: t.audible || false,
                status: t.status, favIconUrl: t.favIconUrl || ''
            }));
            sendResponse({ ok: true, tabs: tabList, summary: `Found ${tabs.length} tabs` });
        });
        return true;
    }

    if (request.action === "agentSwitchTab") {
        (async () => {
            try {
                // Support switching by tabId or by index or by title/url search
                let tabId = request.tabId;
                if (!tabId && request.query) {
                    const tabs = await new Promise(resolve => api.tabs.query({}, resolve));
                    const lower = request.query.toLowerCase();
                    const match = tabs.find(t =>
                        (t.title || '').toLowerCase().includes(lower) ||
                        (t.url || '').toLowerCase().includes(lower)
                    );
                    if (match) tabId = match.id;
                }
                if (!tabId && typeof request.index === 'number') {
                    const tabs = await new Promise(resolve => api.tabs.query({ currentWindow: true }, resolve));
                    if (request.index >= 0 && request.index < tabs.length) tabId = tabs[request.index].id;
                }
                if (!tabId) {
                    sendResponse({ ok: false, error: "Tab not found" });
                    return;
                }
                // Also focus the window containing this tab
                const tab = await new Promise(resolve => api.tabs.get(tabId, resolve));
                await new Promise(resolve => api.windows.update(tab.windowId, { focused: true }, resolve));
                await new Promise(resolve => api.tabs.update(tabId, { active: true }, resolve));
                // Wait for content script to be ready
                await waitForContentScript(tabId, 3000);
                sendResponse({ ok: true, tabId, title: tab.title, summary: `Switched to tab: ${tab.title}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentNavigate") {
        (async () => {
            try {
                const [tab] = await new Promise(resolve => api.tabs.query({ active: true, currentWindow: true }, resolve));
                if (tab) {
                    await new Promise(resolve => api.tabs.update(tab.id, { url: request.url }, resolve));
                    // Wait for navigation to complete
                    if (request.waitForLoad !== false) {
                        await waitForTabLoad(tab.id, 15000);
                        await waitForContentScript(tab.id, 3000);
                    }
                    sendResponse({ ok: true, tabId: tab.id, summary: `Navigated to ${request.url}` });
                } else {
                    sendResponse({ ok: false, error: "No active tab" });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    // ── ADDITIONAL BROWSER ACTIONS ───────────────────────────

    if (request.action === "agentGoBack") {
        api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) api.tabs.goBack(tab.id, () => sendResponse({ ok: true, summary: "Went back" }));
            else sendResponse({ ok: false, error: "No active tab" });
        });
        return true;
    }

    if (request.action === "agentGoForward") {
        api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) api.tabs.goForward(tab.id, () => sendResponse({ ok: true, summary: "Went forward" }));
            else sendResponse({ ok: false, error: "No active tab" });
        });
        return true;
    }

    if (request.action === "agentReloadTab") {
        (async () => {
            try {
                const [tab] = await new Promise(resolve => api.tabs.query({ active: true, currentWindow: true }, resolve));
                if (tab) {
                    await new Promise(resolve => api.tabs.reload(tab.id, { bypassCache: request.bypassCache || false }, resolve));
                    if (request.waitForLoad !== false) {
                        await waitForTabLoad(tab.id, 15000);
                        await waitForContentScript(tab.id, 3000);
                    }
                    sendResponse({ ok: true, summary: "Reloaded tab" });
                } else sendResponse({ ok: false, error: "No active tab" });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentDuplicateTab") {
        api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) api.tabs.duplicate(tab.id, (newTab) => sendResponse({ ok: true, tabId: newTab.id, summary: "Duplicated tab" }));
            else sendResponse({ ok: false, error: "No active tab" });
        });
        return true;
    }

    if (request.action === "agentPinTab") {
        const tabId = request.tabId;
        if (tabId) {
            api.tabs.get(tabId, (tab) => {
                api.tabs.update(tabId, { pinned: !tab.pinned }, () =>
                    sendResponse({ ok: true, summary: `Tab ${tab.pinned ? 'unpinned' : 'pinned'}` }));
            });
        } else {
            api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
                api.tabs.update(tab.id, { pinned: !tab.pinned }, () =>
                    sendResponse({ ok: true, summary: `Tab ${tab.pinned ? 'unpinned' : 'pinned'}` }));
            });
        }
        return true;
    }

    if (request.action === "agentGroupTabs") {
        // tabGroups API not available in Safari
        if (api.tabs.group) {
            api.tabs.group({ tabIds: request.tabIds }, (groupId) => {
                if (request.title && api.tabGroups) {
                    api.tabGroups.update(groupId, { title: request.title, color: request.color || 'blue' });
                }
                sendResponse({ ok: true, groupId, summary: `Grouped ${request.tabIds.length} tabs` });
            });
        } else {
            sendResponse({ ok: false, error: "Tab grouping is not supported in this browser" });
        }
        return true;
    }

    if (request.action === "agentCaptureTab") {
        api.tabs.captureVisibleTab(null, { format: request.format || 'jpeg', quality: request.quality || 70 }, (dataUrl) => {
            if (api.runtime.lastError) {
                sendResponse({ ok: false, error: api.runtime.lastError.message });
            } else {
                sendResponse({ ok: true, image: dataUrl, summary: "Captured screenshot" });
            }
        });
        return true;
    }

    if (request.action === "agentCreateBookmark") {
        api.bookmarks.create({ title: request.title, url: request.url }, () => {
            sendResponse({ ok: true, summary: `Bookmarked "${request.title}"` });
        });
        return true;
    }

    if (request.action === "agentSearchBookmarks") {
        api.bookmarks.search(request.query, (results) => {
            const bookmarks = results.slice(0, 20).map(b => ({ title: b.title, url: b.url }));
            sendResponse({ ok: true, bookmarks, summary: `Found ${bookmarks.length} bookmarks` });
        });
        return true;
    }

    // ── EXTERNAL API ACTIONS ─────────────────────────────────

    if (request.action === "agentWebSearch") {
        (async () => {
            try {
                const query = encodeURIComponent(request.query);
                const res = await fetch(`https://api.duckduckgo.com/?q=${query}&format=json&no_html=1&skip_disambig=1`);
                const data = await res.json();
                const results = {
                    abstract: data.AbstractText || '',
                    abstractSource: data.AbstractSource || '',
                    abstractURL: data.AbstractURL || '',
                    answer: data.Answer || '',
                    relatedTopics: (data.RelatedTopics || []).filter(t => t.Text).slice(0, 8).map(t => ({
                        text: t.Text || '',
                        url: t.FirstURL || ''
                    }))
                };
                sendResponse({ ok: true, data: results, summary: `Web search: "${request.query}"` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentFetchUrl") {
        (async () => {
            try {
                const url = request.url;
                if (/^(chrome|file|chrome-extension|about):/.test(url)) {
                    sendResponse({ ok: false, error: "Cannot fetch internal URLs" });
                    return;
                }
                const res = await fetch(url, { redirect: 'follow' });
                const contentType = res.headers.get('content-type') || '';
                let content;
                if (contentType.includes('application/json')) {
                    const json = await res.json();
                    content = JSON.stringify(json, null, 2).substring(0, 15000);
                } else {
                    const text = await res.text();
                    content = text
                        .replace(/<script[\s\S]*?<\/script>/gi, '')
                        .replace(/<style[\s\S]*?<\/style>/gi, '')
                        .replace(/<[^>]+>/g, ' ')
                        .replace(/\s+/g, ' ')
                        .trim()
                        .substring(0, 15000);
                }
                sendResponse({ ok: true, content, summary: `Fetched ${url} (${content.length} chars)` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentWikipedia") {
        (async () => {
            try {
                const title = encodeURIComponent(request.title);
                const res = await fetch(`https://en.wikipedia.org/api/rest_v1/page/summary/${title}`);
                const data = await res.json();
                sendResponse({
                    ok: true,
                    data: {
                        title: data.title || '',
                        extract: data.extract || '',
                        description: data.description || '',
                        thumbnail: data.thumbnail?.source || '',
                        url: data.content_urls?.desktop?.page || ''
                    },
                    summary: `Wikipedia: "${data.title || request.title}"`
                });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentWeather") {
        (async () => {
            try {
                const location = encodeURIComponent(request.location);
                const res = await fetch(`https://wttr.in/${location}?format=j1`);
                const data = await res.json();
                const current = data.current_condition?.[0] || {};
                const weather = {
                    location: data.nearest_area?.[0]?.areaName?.[0]?.value || request.location,
                    tempC: current.temp_C,
                    tempF: current.temp_F,
                    feelsLikeC: current.FeelsLikeC,
                    feelsLikeF: current.FeelsLikeF,
                    humidity: current.humidity + '%',
                    wind: current.windspeedMiles + ' mph / ' + current.windspeedKmph + ' km/h',
                    description: current.weatherDesc?.[0]?.value || '',
                    uvIndex: current.uvIndex
                };
                sendResponse({ ok: true, weather, summary: `Weather in ${weather.location}: ${weather.tempC}°C, ${weather.description}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentTranslate") {
        (async () => {
            try {
                const text = encodeURIComponent(request.text);
                const from = request.from || 'en';
                const to = request.to || 'es';
                const res = await fetch(`https://api.mymemory.translated.net/get?q=${text}&langpair=${from}|${to}`);
                const data = await res.json();
                const translated = data.responseData?.translatedText || '';
                sendResponse({
                    ok: true,
                    translation: translated,
                    summary: `Translated (${from}→${to}): "${translated.substring(0, 100)}"`
                });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentDictionary") {
        (async () => {
            try {
                const word = encodeURIComponent(request.word);
                const res = await fetch(`https://api.dictionaryapi.dev/api/v2/entries/en/${word}`);
                const data = await res.json();
                if (Array.isArray(data) && data.length > 0) {
                    const entry = data[0];
                    const definitions = entry.meanings?.slice(0, 3).map(m => ({
                        partOfSpeech: m.partOfSpeech,
                        definitions: m.definitions?.slice(0, 2).map(d => d.definition)
                    }));
                    sendResponse({
                        ok: true,
                        definition: { word: entry.word, phonetic: entry.phonetic || '', meanings: definitions },
                        summary: `Definition of "${entry.word}"`
                    });
                } else {
                    sendResponse({ ok: false, error: `No definition found for "${request.word}"` });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    // ── ADVANCED BROWSER ACTIONS ─────────────────────────────

    if (request.action === "agentDownloadFile") {
        (async () => {
            try {
                const url = request.url;
                if (!url || /^(chrome|file|chrome-extension|about|javascript):/.test(url)) {
                    sendResponse({ ok: false, error: "Invalid download URL" });
                    return;
                }
                const opts = { url };
                if (request.filename) opts.filename = request.filename;
                if (request.conflictAction) opts.conflictAction = request.conflictAction;
                api.downloads.download(opts, (downloadId) => {
                    if (api.runtime.lastError) {
                        sendResponse({ ok: false, error: api.runtime.lastError.message });
                    } else {
                        sendResponse({ ok: true, downloadId, summary: `Started download: ${url.substring(0, 80)}` });
                    }
                });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentGetDownloads") {
        api.downloads.search({ limit: request.limit || 20, orderBy: ['-startTime'] }, (items) => {
            const downloads = items.map(d => ({
                id: d.id, filename: d.filename, url: d.url?.substring(0, 100),
                state: d.state, fileSize: d.fileSize, bytesReceived: d.bytesReceived
            }));
            sendResponse({ ok: true, downloads, summary: `Found ${downloads.length} recent downloads` });
        });
        return true;
    }

    if (request.action === "agentGetHistory") {
        api.history.search({
            text: request.query || '',
            maxResults: Math.min(request.maxResults || 20, 100),
            startTime: request.startTime || (Date.now() - 7 * 24 * 60 * 60 * 1000) // last 7 days
        }, (results) => {
            const history = results.map(h => ({ title: h.title, url: h.url, lastVisitTime: h.lastVisitTime, visitCount: h.visitCount }));
            sendResponse({ ok: true, history, summary: `Found ${history.length} history items` });
        });
        return true;
    }

    if (request.action === "agentGetCookies") {
        (async () => {
            try {
                const url = request.url;
                if (!url) { sendResponse({ ok: false, error: "URL required" }); return; }
                const cookies = await api.cookies.getAll({ url });
                const safe = cookies.map(c => ({
                    name: c.name, domain: c.domain,
                    httpOnly: c.httpOnly, secure: c.secure,
                    expirationDate: c.expirationDate, sameSite: c.sameSite
                }));
                sendResponse({ ok: true, cookies: safe, summary: `Found ${safe.length} cookies for ${url}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentSetCookie") {
        (async () => {
            try {
                const cookie = await api.cookies.set({
                    url: request.url,
                    name: request.name,
                    value: request.value,
                    domain: request.domain,
                    path: request.path || '/',
                    secure: request.secure || false,
                    httpOnly: request.httpOnly || false,
                    sameSite: request.sameSite || 'lax',
                    expirationDate: request.expirationDate || (Date.now() / 1000 + 86400 * 30)
                });
                sendResponse({ ok: true, summary: `Set cookie "${request.name}" for ${request.url}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentDeleteCookies") {
        (async () => {
            try {
                await api.cookies.remove({ url: request.url, name: request.name });
                sendResponse({ ok: true, summary: `Deleted cookie "${request.name}" from ${request.url}` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentCreateWindow") {
        api.windows.create({
            url: request.url,
            type: request.type || 'normal',
            focused: request.focused !== false,
            incognito: request.incognito || false,
            width: request.width,
            height: request.height
        }, (win) => {
            sendResponse({ ok: true, windowId: win.id, summary: `Created new ${request.incognito ? 'incognito ' : ''}window` });
        });
        return true;
    }

    if (request.action === "agentGetWindows") {
        api.windows.getAll({ populate: true }, (windows) => {
            const wins = windows.map(w => ({
                id: w.id, type: w.type, focused: w.focused, incognito: w.incognito,
                tabCount: w.tabs?.length || 0, state: w.state
            }));
            sendResponse({ ok: true, windows: wins, summary: `Found ${wins.length} windows` });
        });
        return true;
    }

    if (request.action === "agentCloseWindow") {
        api.windows.remove(request.windowId, () => {
            sendResponse({ ok: true, summary: `Closed window ${request.windowId}` });
        });
        return true;
    }

    if (request.action === "agentMoveTab") {
        api.tabs.move(request.tabId, { index: request.index ?? -1, windowId: request.windowId }, (tab) => {
            if (api.runtime.lastError) {
                sendResponse({ ok: false, error: api.runtime.lastError.message });
            } else {
                sendResponse({ ok: true, summary: `Moved tab to position ${request.index}` });
            }
        });
        return true;
    }

    if (request.action === "agentZoomTab") {
        (async () => {
            try {
                const [tab] = await api.tabs.query({ active: true, currentWindow: true });
                const currentZoom = await api.tabs.getZoom(tab.id);
                const newZoom = request.zoom || (request.direction === 'in' ? currentZoom + 0.25 : currentZoom - 0.25);
                await api.tabs.setZoom(tab.id, Math.max(0.25, Math.min(5, newZoom)));
                sendResponse({ ok: true, summary: `Zoom set to ${Math.round(newZoom * 100)}%` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    if (request.action === "agentMuteTab") {
        (async () => {
            try {
                const tabId = request.tabId;
                if (tabId) {
                    const tab = await api.tabs.get(tabId);
                    await api.tabs.update(tabId, { muted: !tab.mutedInfo?.muted });
                    sendResponse({ ok: true, summary: `Tab ${tab.mutedInfo?.muted ? 'unmuted' : 'muted'}` });
                } else {
                    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
                    await api.tabs.update(tab.id, { muted: !tab.mutedInfo?.muted });
                    sendResponse({ ok: true, summary: `Tab ${tab.mutedInfo?.muted ? 'unmuted' : 'muted'}` });
                }
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    // Forward a content-script action to a specific tab
    if (request.action === "agentSendToTab") {
        (async () => {
            try {
                const tabId = request.tabId;
                if (!tabId) { sendResponse({ ok: false, error: "tabId required" }); return; }
                const ready = await waitForContentScript(tabId, 3000);
                if (!ready) { sendResponse({ ok: false, error: "Content script not ready in target tab" }); return; }
                const innerRequest = request.innerAction || {};
                const result = await new Promise(resolve =>
                    api.tabs.sendMessage(tabId, innerRequest, resolve)
                );
                sendResponse(result || { ok: false, error: "No response from tab" });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }

    // Find a tab by title or URL
    if (request.action === "agentFindTab") {
        (async () => {
            try {
                const tabs = await new Promise(resolve => api.tabs.query({}, resolve));
                const query = (request.query || '').toLowerCase();
                const matches = tabs.filter(t =>
                    (t.title || '').toLowerCase().includes(query) ||
                    (t.url || '').toLowerCase().includes(query)
                ).slice(0, 10).map(t => ({
                    id: t.id, title: t.title, url: t.url, active: t.active, windowId: t.windowId
                }));
                sendResponse({ ok: true, tabs: matches, summary: `Found ${matches.length} tabs matching "${request.query}"` });
            } catch (e) { sendResponse({ ok: false, error: e.message }); }
        })();
        return true;
    }
});
