// The Phone page's service worker: a page load the network failed gets a note naming the host. It caches nothing and leaves every other
// request alone (why: where-it-breaks, Phone page). The server writes the host's name into the next line (webapp.ts `workerSource`).
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

// With no state, an updated worker may replace the old one at once.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
  const request = event.request;
  // Only a page load, and only once the network has failed it: whatever the host answers, an error status included, is shown as sent.
  if (request.mode !== "navigate" || request.method !== "GET") return;
  event.respondWith(fetch(request).catch(note));
});
