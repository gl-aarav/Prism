if (chrome.sidePanel && chrome.sidePanel.setPanelBehavior) {
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(console.error);
}

chrome.action.onClicked.addListener((tab) => {
    // Fallback if setPanelBehavior doesn't automatically open it in some Safari versions
    if (chrome.sidePanel && chrome.sidePanel.open) {
        chrome.sidePanel.open({ windowId: tab.windowId });
    }
});
