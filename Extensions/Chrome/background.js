if (chrome.sidePanel && chrome.sidePanel.setPanelBehavior) {
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(console.error);
}

chrome.action.onClicked.addListener((tab) => {
    // Fallback if setPanelBehavior doesn't automatically open it in some Safari versions
    if (chrome.sidePanel && chrome.sidePanel.open) {
        chrome.sidePanel.open({ windowId: tab.windowId });
    }
});

// ── AGENTIC BROWSER CONTROL - Background handlers ──────────
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "agentOpenTab") {
        chrome.tabs.create({ url: request.url, active: request.active !== false }, (tab) => {
            sendResponse({ ok: true, tabId: tab.id, summary: `Opened tab: ${request.url}` });
        });
        return true;
    }

    if (request.action === "agentCloseTab") {
        chrome.tabs.remove(request.tabId || sender.tab?.id, () => {
            sendResponse({ ok: true, summary: "Closed tab" });
        });
        return true;
    }

    if (request.action === "agentGetTabs") {
        chrome.tabs.query({}, (tabs) => {
            const tabList = tabs.map(t => ({ id: t.id, title: t.title, url: t.url, active: t.active }));
            sendResponse({ ok: true, tabs: tabList, summary: `Found ${tabs.length} tabs` });
        });
        return true;
    }

    if (request.action === "agentSwitchTab") {
        chrome.tabs.update(request.tabId, { active: true }, () => {
            sendResponse({ ok: true, summary: `Switched to tab ${request.tabId}` });
        });
        return true;
    }

    if (request.action === "agentNavigate") {
        chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) {
                chrome.tabs.update(tab.id, { url: request.url }, () => {
                    sendResponse({ ok: true, summary: `Navigated to ${request.url}` });
                });
            }
        });
        return true;
    }
});
