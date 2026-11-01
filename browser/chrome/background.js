// RefWare Capture for Chrome. Hands a URL to the RefWare app through Chrome's native-messaging
// bridge (installed by scripts/install-capture-app.sh): no refware:// link, so no permission
// prompt and nothing for Chrome to block. The app looks up the metadata, saves the PDF (or a
// dated snapshot of a web page), files it, and shows a "just captured" banner.

const HOST = "ai.uefoundation.refware";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "refware-page", title: "Add this page to RefWare", contexts: ["page", "frame"] });
    chrome.contextMenus.create({ id: "refware-link", title: "Add linked item to RefWare", contexts: ["link"] });
    chrome.contextMenus.create({ id: "refware-review", title: "Open RefWare Review", contexts: ["action"] });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "refware-review") { send({ action: "review" }); return; }
  const url = info.menuItemId === "refware-link" ? info.linkUrl : (info.frameUrl || info.pageUrl || (tab && tab.url));
  capture(url);
});

// Toolbar button and Option-Shift-R: the current tab — works for PDFs open in Chrome's viewer.
chrome.action.onClicked.addListener((tab) => capture(tab.url));

function capture(url) {
  if (!url || !/^https?:/i.test(url)) { flash("!", "#b00020", "Only web pages and PDFs can be captured"); return; }
  send({ action: "capture", url });
}

function send(message) {
  chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
    if (chrome.runtime.lastError || !reply) {
      // Bridge not installed (or RefWare missing): a page with a real button — Chrome requires a click.
      const link = message.action === "capture"
        ? "refware://capture?url=" + encodeURIComponent(message.url)
        : "refware://" + message.action;
      chrome.tabs.create({ url: chrome.runtime.getURL("send.html") + "?link=" + encodeURIComponent(link) + "&u=" + encodeURIComponent(message.url || "") });
      return;
    }
    if (reply.ok) flash("✓", "#1e8e3e", "Sent to RefWare");
    else flash("!", "#b00020", reply.error || "RefWare couldn't take this");
  });
}

function flash(text, color, title) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  chrome.action.setTitle({ title });
  setTimeout(() => { chrome.action.setBadgeText({ text: "" }); chrome.action.setTitle({ title: "Add this tab to RefWare" }); }, 4000);
}
