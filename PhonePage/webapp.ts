// The Phone page's installable parts, one app per host (each host's page is its own origin): the manifest, the worker's template and the
// page's content policy. No I/O.

import { escapeHTML } from "./home";

/** Each icon by the path it is served at: its file under `page/icons/` (checked against `DIGESTS` by `bun test`), its size and its purpose. */
export const iconFiles: Record<string, { file: string; size: number; purpose: "any" | "maskable" }> = {
  "/icons/apple-touch-icon.png": { file: "page/icons/apple-touch-icon.png", size: 180, purpose: "any" },
  "/icons/icon-192.png": { file: "page/icons/icon-192.png", size: 192, purpose: "any" },
  "/icons/icon-512.png": { file: "page/icons/icon-512.png", size: 512, purpose: "any" },
  "/icons/icon-maskable-512.png": { file: "page/icons/icon-maskable-512.png", size: 512, purpose: "maskable" },
};

/** The manifest for a host's page. Its colours are the dark ones only (a manifest holds one); index.html's `theme-color` tags give both. */
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
    icons: Object.entries(iconFiles).map(([src, icon]) => ({ src, sizes: `${icon.size}x${icon.size}`, type: "image/png", purpose: icon.purpose })),
  });
}

/** The worker's template (`page/sw.js`) with the host's name where its first line says. A function replaces, so `$&` in a name stays as written. */
export function workerSource(template: string, hostName: string): string {
  return template.replace(`/*HOST*/ ""`, () => JSON.stringify(hostName));
}

/** Whether a browser is loading or updating the worker, and not another site reading the script, which holds the host's name. A page can't set either header. */
export function isWorkerFetch(headers: Headers): boolean {
  return headers.get("service-worker") === "script" || headers.get("sec-fetch-dest") === "serviceworker";
}

/** The Home Screen title iOS gives the page, a tag the server writes into index.html in place of the token: the host's name. */
export const appTitleToken = "<!--APP-TITLE-->";
export const appTitleTag = (hostName: string): string => `<meta name="apple-mobile-web-app-title" content="${escapeHTML(hostName)}">`;

/** What a listed device's page may load. Styles may be inline (xterm.js writes <style> elements), scripts may not; the websocket is named because not every browser takes 'self' to cover wss. */
export function pageContentPolicy(dnsName: string, wantHost: string): string {
  return `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss://${wantHost}; frame-src https://${dnsName}:*; manifest-src 'self'; img-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;
}
