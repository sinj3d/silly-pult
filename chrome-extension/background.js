const HELPER_URL = "http://127.0.0.1:42424/api/browser-activity";
const HEARTBEAT_ALARM = "sillypult-heartbeat";

function normalizeHostname(urlString) {
  try {
    const url = new URL(urlString);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return null;
    }

    return url.hostname.toLowerCase();
  } catch {
    return null;
  }
}

async function sendTabToHelper(tab) {
  const domain = tab?.url ? normalizeHostname(tab.url) : null;
  if (!domain || !tab?.windowId) {
    return;
  }

  const payload = {
    url: tab.url,
    domain,
    title: tab.title ?? "",
    tabId: tab.id ?? -1,
    windowId: tab.windowId,
    observedAt: new Date().toISOString(),
  };

  try {
    await fetch(HELPER_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch {
    // The helper may not be running yet. Ignore failures silently.
  }
}

async function reportActiveTab(windowId) {
  const tabs = await chrome.tabs.query({
    active: true,
    lastFocusedWindow: windowId == null,
    ...(windowId == null ? {} : { windowId }),
  });

  if (tabs[0]) {
    await sendTabToHelper(tabs[0]);
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(HEARTBEAT_ALARM, {
    periodInMinutes: 0.5,
  });
});

chrome.tabs.onActivated.addListener(async ({ tabId, windowId }) => {
  const tab = await chrome.tabs.get(tabId);
  await sendTabToHelper({
    ...tab,
    windowId,
  });
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.active) {
    await sendTabToHelper({
      ...tab,
      id: tabId,
    });
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) {
    await reportActiveTab(windowId);
  }
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === HEARTBEAT_ALARM) {
    await reportActiveTab();
  }
});
