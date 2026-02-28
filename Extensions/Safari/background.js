// Prism Safari Extension — Background Service Worker
// Safari-compatible version (no sidePanel, no tabGroups)

const api = typeof browser !== 'undefined' ? browser : chrome;

// ── AGENTIC BROWSER CONTROL - Background handlers ──────────
api.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "agentOpenTab") {
        api.tabs.create({ url: request.url, active: request.active !== false }, (tab) => {
            sendResponse({ ok: true, tabId: tab.id, summary: `Opened tab: ${request.url}` });
        });
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
            const tabList = tabs.map(t => ({ id: t.id, title: t.title, url: t.url, active: t.active }));
            sendResponse({ ok: true, tabs: tabList, summary: `Found ${tabs.length} tabs` });
        });
        return true;
    }

    if (request.action === "agentSwitchTab") {
        api.tabs.update(request.tabId, { active: true }, () => {
            sendResponse({ ok: true, summary: `Switched to tab ${request.tabId}` });
        });
        return true;
    }

    if (request.action === "agentNavigate") {
        api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) {
                api.tabs.update(tab.id, { url: request.url }, () => {
                    sendResponse({ ok: true, summary: `Navigated to ${request.url}` });
                });
            }
        });
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
        api.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) api.tabs.reload(tab.id, () => sendResponse({ ok: true, summary: "Reloaded tab" }));
            else sendResponse({ ok: false, error: "No active tab" });
        });
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

    if (request.action === "agentCaptureTab") {
        api.tabs.captureVisibleTab(null, { format: 'png' }, (dataUrl) => {
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
                if (/^(safari-web-extension|file|about):/.test(url)) {
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
});
