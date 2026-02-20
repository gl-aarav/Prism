chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "getPageContext") {
        sendResponse({ content: document.body.innerText });
    }
    return true;
});
