// What makes the Phone page installable as an app, one per host (the host's page is its own origin): the web app manifest and the
// service worker, both written per request with the host's name, the icons' paths, and the page's content policy. No I/O.

import { escapeHTML } from "./home";

/** The icons, by the path they are served at, and the file under `page/icons/` (checked against `DIGESTS` by `bun test`). */
export const iconFiles: Record<string, string> = {
  "/icons/apple-touch-icon.png": "page/icons/apple-touch-icon.png",
  "/icons/icon-192.png": "page/icons/icon-192.png",
  "/icons/icon-512.png": "page/icons/icon-512.png",
  "/icons/icon-maskable-512.png": "page/icons/icon-maskable-512.png",
};

/**
 * The manifest for a host's page. It is one app per host: its name says which, and its scope is the page. The colours are the page's own
 * dark ones, which a manifest can hold only one of; index.html's `theme-color` tags give both. No `orientation`, so any.
 */
export function manifestFor(hostName: string): string {
  return JSON.stringify({
    name: `Varnick · ${hostName}`,
    short_name: hostName,
    description: `Sessions on ${hostName}, from the phone.`,
    id: "/",
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#111111",
    theme_color: "#111111",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  });
}

/** The worker's template (`page/sw.js`) with the host's name where its first line says. A function replaces, so `$&` in a name stays as written. */
export function workerSource(template: string, hostName: string): string {
  return template.replace(`/*HOST*/ ""`, () => JSON.stringify(hostName));
}

/** The Home Screen title iOS gives the page, a tag the server writes into index.html in place of the token: the host's name. */
export const appTitleToken = "<!--APP-TITLE-->";
export const appTitleTag = (hostName: string): string => `<meta name="apple-mobile-web-app-title" content="${escapeHTML(hostName)}">`;

/**
 * What a listed device's page may load. The page's scripts and styles are its own and xterm.js's, vendored; the terminal's websocket is
 * named outright, since not every browser takes 'self' to cover wss; frames only from this host's own name, on the proxied ports
 * (proxy.ts). The manifest, the icons and the worker are the page's own files, so each names 'self' and nothing else.
 */
export function pageContentPolicy(dnsName: string, wantHost: string): string {
  // xterm.js's renderer writes <style> elements, which `style-src 'self'` would refuse: styles may be inline, scripts may not.
  return `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss://${wantHost}; frame-src https://${dnsName}:*; manifest-src 'self'; img-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;
}
