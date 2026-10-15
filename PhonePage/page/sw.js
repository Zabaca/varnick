// The Phone page's service worker: a page load the network failed gets a note naming the host, and a push shows a notification. It caches
// nothing and leaves every other request alone (why: where-it-breaks, Phone page). The server writes the host's name into the line after the
// comments (webapp.ts `workerSource`).
const host = /*HOST*/ "";

const escapeHTML = (value) => value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);

/** The note, as a page of its own: no script, so its Content-Security-Policy allows none. Try again is a plain link to the page's start. */
function note() {
  const name = escapeHTML(host);
  const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>Can't reach ${name}</title>
<style>
  body { font: 16px/1.45 system-ui, sans-serif; margin: 0 auto; padding: 32px 16px; max-width: 34rem; background: #111; color: #e8e8e8; }
  h1 { font-size: 20px; margin: 0 0 12px; overflow-wrap: anywhere; }
  p { margin: 0 0 12px; }
  a { display: inline-block; padding: 12px 18px; border-radius: 8px; background: #2a2a2a; color: inherit; text-decoration: none; }
  @media (prefers-color-scheme: light) { body { background: #f5f5f4; color: #1d1d1b; } a { background: #ececea; } }
</style>
</head><body>
<h1>Can't reach ${name}</h1>
<p>Is Tailscale on for this phone, and is ${name} awake?</p>
<a href="/">Try again</a>
</body></html>
`;
  return new Response(html, {
    status: 503,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
    },
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Push (option 02 of phone-page-is-only-a-browser-tab). A push carries ids and the kind of notice, never a title: the worker asks the host for
// the session's title over the tailnet, and without it the notification names only the host.

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The wordings are sessions-finish-unnoticed option 02's. With the session's title they follow it; without, they name the host and no session. */
const phrase = { permission: "Needs permission", question: "Has a question", plan: "Plan to approve", input: "Waiting on an MCP server", done: "Done" };
const generic = {
  permission: "A session needs permission",
  question: "A session has a question",
  plan: "A session has a plan to approve",
  input: "A session is waiting on an MCP server",
  done: "A session is done",
};

/** An error's kind as a word: the host's list ("rate limit"), nothing else the push could carry. */
const errorWord = (failure) => (typeof failure === "string" && /^[a-z ]{1,30}$/.test(failure) ? failure : "API error");

/** The payload of a push, or null for anything this worker doesn't understand (it still shows a notification: every push must). */
function readPayload(event) {
  try {
    const payload = event.data ? event.data.json() : null;
    if (!payload || payload.v !== 1) return null;
    if (payload.kind === "test") return { kind: "test", tab: null, pane: null, failure: null };
    if (payload.kind !== "failed" && !Object.hasOwn(phrase, payload.kind)) return null;
    if (typeof payload.tab !== "string" || !uuid.test(payload.tab) || typeof payload.pane !== "string" || !uuid.test(payload.pane)) return null;
    return { kind: payload.kind, tab: payload.tab, pane: payload.pane, failure: payload.kind === "failed" ? errorWord(payload.failure) : null };
  } catch {
    return null;
  }
}

/** The notification's title and body. `title` is the session's, when the host could be asked. */
function noticeText(payload, hostName, title) {
  if (!payload) return { title: hostName, body: "A session needs a look" };
  if (payload.kind === "test") return { title: hostName, body: "Notifications work" };
  const named = typeof title === "string" && title.trim() !== "";
  if (payload.kind === "failed") {
    const said = `Stopped on an error: ${payload.failure}`;
    return named ? { title: title.trim(), body: `${said} · ${hostName}` } : { title: hostName, body: `A session stopped on an error: ${payload.failure}` };
  }
  return named ? { title: title.trim(), body: `${phrase[payload.kind]} · ${hostName}` } : { title: hostName, body: generic[payload.kind] };
}

/** The session's title, read over the tailnet within three seconds; null when the host can't be reached or the pane is gone. */
async function readTitle(payload) {
  if (!payload || !payload.tab) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch(`/api/tab?tab=${payload.tab}`, { cache: "no-store", headers: { accept: "application/json" }, signal: controller.signal });
    if (!response.ok) return null;
    const body = await response.json();
    const pane = body && body.tab && Array.isArray(body.tab.panes) ? body.tab.panes.find((candidate) => candidate && candidate.id === payload.pane) : null;
    return pane && typeof pane.title === "string" && pane.title.trim() !== "" ? pane.title.trim().slice(0, 120) : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** One notification per pane: a newer one replaces the older and alerts again. */
async function show(event) {
  const payload = readPayload(event);
  const text = noticeText(payload, host, await readTitle(payload));
  await self.registration.showNotification(text.title, {
    body: text.body,
    tag: payload && payload.pane ? payload.pane : "varnick",
    renotify: true,
    icon: "/icons/icon-192.png",
    data: { tab: payload ? payload.tab : null, pane: payload ? payload.pane : null },
  });
  await setBadge();
}

/** The app's badge (iOS) is the number of its standing notifications; the page clears it when it opens. Android shows its own dot and ignores it. */
async function setBadge() {
  try {
    if (!self.navigator || !self.navigator.setAppBadge || !self.registration.getNotifications) return;
    await self.navigator.setAppBadge((await self.registration.getNotifications()).length);
  } catch {
    // A browser without badges, or one that refuses: the notification is shown all the same.
  }
}

/** Where a tap goes: the tab and pane, the page's own address (`#t=<tab>&p=<pane>`). */
function target(data) {
  if (!data || typeof data.tab !== "string" || !uuid.test(data.tab)) return "/";
  return typeof data.pane === "string" && uuid.test(data.pane) ? `/#t=${data.tab}&p=${data.pane}` : `/#t=${data.tab}`;
}

/** Focuses the app's open window and tells it where to go, or opens one there. */
async function openTarget(data) {
  const address = target(data);
  const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  for (const client of windows) {
    if (new URL(client.url).origin !== self.location.origin) continue;
    if (client.focus) await client.focus();
    client.postMessage({ type: "open", hash: address.slice(1) });
    return;
  }
  await self.clients.openWindow(address);
}

// With no state, an updated worker may replace the old one at once.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => event.waitUntil(show(event)));
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(openTarget(event.notification.data));
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  // Only a page load, and only once the network has failed it: whatever the host answers, an error status included, is shown as sent.
  if (request.mode !== "navigate" || request.method !== "GET") return;
  event.respondWith(fetch(request).catch(note));
});
