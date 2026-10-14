// Right-click "Add to local library" on YouTube song links and song pages.
importScripts("ytlink.js");
const HOST = "com.unome.music";
const LINKS = ["*://*.youtube.com/watch*", "*://youtu.be/*", "*://*.youtube.com/shorts/*"];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "add-link", title: "Add song to local library", contexts: ["link"],
                                 targetUrlPatterns: LINKS });
    chrome.contextMenus.create({ id: "add-page", title: "Add this song to local library", contexts: ["page", "video"],
                                 documentUrlPatterns: LINKS });
  });
});

function badge(tabId, text) {
  chrome.action.setBadgeBackgroundColor({ color: "#ffffff" });
  if (chrome.action.setBadgeTextColor) chrome.action.setBadgeTextColor({ color: "#0a0a0a" });
  chrome.action.setBadgeText({ tabId, text });
  setTimeout(() => chrome.action.setBadgeText({ tabId, text: "" }), 4000);
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const link = songLink(info.menuItemId === "add-link" ? info.linkUrl : info.pageUrl);
  const tabId = tab && tab.id;
  if (!link) return badge(tabId, "?");
  try {
    const r = await chrome.runtime.sendNativeMessage(HOST, { cmd: "add", url: link.url, id: link.id });
    badge(tabId, r && r.ok ? (r.already ? "✓" : "+") : "!");
  } catch (e) {
    badge(tabId, "!");
  }
});
