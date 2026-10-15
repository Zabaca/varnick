import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { appTitleTag, appTitleToken, iconFiles, manifestFor, pageContentPolicy, workerSource } from "./webapp";

const hostNames = ["Test Mac", `Jam "the" Mac`, "O'Brien's <Mac> & $& $1", "Café Ünï 書斎 \u{1F4BB}", "</script><b>x</b>", "back\\slash"];
const page = (path: string) => new URL(`./page/${path}`, import.meta.url);
const template = readFileSync(page("sw.js"), "utf8");

describe("the manifest", () => {
  test("is named for the host, whatever the host is called", () => {
    for (const name of hostNames) {
      const manifest = JSON.parse(manifestFor(name));
      expect(manifest.name).toBe(`Varnick · ${name}`);
      expect(manifest.short_name).toBe(name);
    }
  });

  test("starts the page standalone in any orientation, at the page's own scope", () => {
    const manifest = JSON.parse(manifestFor("Test Mac"));
    expect(manifest.start_url).toBe("/");
    expect(manifest.scope).toBe("/");
    expect(manifest.display).toBe("standalone");
    expect(manifest.orientation).toBeUndefined();
  });

  test("names icons of 192 and 512, and a maskable one, all of them served files", () => {
    const icons = JSON.parse(manifestFor("Test Mac")).icons as { src: string; sizes: string; purpose: string }[];
    expect(icons.map((icon) => `${icon.sizes} ${icon.purpose}`).sort()).toEqual(["192x192 any", "512x512 any", "512x512 maskable"]);
    for (const icon of icons) expect(Object.keys(iconFiles)).toContain(icon.src);
  });
});

describe("the worker's template", () => {
  test("takes the host's name as one string, however it is written", () => {
    for (const name of hostNames) {
      const source = workerSource(template, name);
      expect(source).toContain(`const host = ${JSON.stringify(name)};`);
      expect(source).not.toContain("/*HOST*/");
    }
  });

  test("has its one place for the name", () => {
    expect(template.split(`/*HOST*/ ""`).length).toBe(2);
  });
});

/** Runs the worker as a browser would load it, with the events it registers kept and the network as given. */
function load(name: string, network: (request: unknown) => Promise<unknown>) {
  const handlers: Record<string, (event: any) => void> = {};
  const self = { addEventListener: (type: string, handler: (event: any) => void) => { handlers[type] = handler; }, skipWaiting: () => {}, clients: { claim: async () => {} } };
  new Function("self", "fetch", workerSource(template, name))(self, network);
  return handlers;
}

/** What the worker does with a request: the response it answered with, or "passed" when it left the request alone. */
async function answered(handlers: Record<string, (event: any) => void>, request: Record<string, unknown>): Promise<Response | "passed"> {
  let given: Promise<Response> | null = null;
  handlers.fetch({ request, respondWith: (response: Promise<Response>) => { given = response; } });
  return given ? await given : "passed";
}

describe("the worker", () => {
  const down = () => Promise.reject(new TypeError("Failed to fetch"));

  test("answers a page load the network failed with a note naming the host, escaped", async () => {
    for (const name of hostNames) {
      const reply = await answered(load(name, down), { mode: "navigate", method: "GET" });
      expect(reply).not.toBe("passed");
      const response = reply as Response;
      const html = await response.text();
      expect(response.status).toBe(503);
      expect(html).toContain(`<title>Can't reach ${name.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!)}</title>`);
      // The name never becomes markup: its only tags are the note's own.
      expect(html.match(/<[a-z][a-z0-9]*/g)!.sort()).toEqual(["<a", "<body", "<h1", "<head", "<html", "<meta", "<meta", "<meta", "<p", "<style", "<title"].sort());
      expect(html).toContain("Try again");
      expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
      expect(response.headers.get("content-security-policy")).not.toContain("script");
    }
  });

  test("gives the host's own reply as it is when the network answers, an error status included", async () => {
    for (const status of [200, 403, 502]) {
      const sent = new Response("from the host", { status });
      const reply = await answered(load("Test Mac", () => Promise.resolve(sent)), { mode: "navigate", method: "GET" });
      expect(reply).toBe(sent);
    }
  });

  test("leaves every request that isn't a page load alone, so it is never asked of the network by the worker", async () => {
    let asked = 0;
    const handlers = load("Test Mac", () => { asked += 1; return down(); });
    for (const request of [{ mode: "no-cors", method: "GET" }, { mode: "cors", method: "GET" }, { mode: "same-origin", method: "POST" }, { mode: "navigate", method: "POST" }, { mode: "websocket", method: "GET" }]) {
      expect(await answered(handlers, request)).toBe("passed");
    }
    expect(asked).toBe(0);
  });

  test("keeps nothing: no cache, no storage, no stored response", () => {
    const code = template.split("\n").filter((line) => !line.trimStart().startsWith("//")).join("\n");
    for (const word of ["caches", "indexedDB", "localStorage", "importScripts"]) expect(code).not.toContain(word);
  });
});

describe("the content policy", () => {
  const policy = pageContentPolicy("host.example.test", "host.example.test:8444");

  test("names the manifest, the icons and the worker, each as this page's own", () => {
    for (const source of ["manifest-src 'self'", "img-src 'self'", "worker-src 'self'"]) expect(policy.split("; ")).toContain(source);
  });

  test("still starts from nothing and allows no script but its own", () => {
    expect(policy.split("; ")).toContain("default-src 'none'");
    expect(policy.split("; ")).toContain("script-src 'self'");
    expect(policy).toContain("connect-src 'self' wss://host.example.test:8444");
    expect(policy).toContain("frame-src https://host.example.test:*");
    expect(policy).not.toContain("'unsafe-eval'");
  });
});

describe("the page", () => {
  const index = readFileSync(page("index.html"), "utf8");

  test("links the manifest and the Home Screen icon, and leaves the host's title to the server", () => {
    expect(index).toContain(`<link rel="manifest" href="/manifest.webmanifest">`);
    const touch = /<link rel="apple-touch-icon" href="([^"]+)">/.exec(index)!;
    expect(Object.keys(iconFiles)).toContain(touch[1]);
    expect(index).toContain(appTitleToken);
  });

  test("the Home Screen title is the host's name, escaped", () => {
    expect(appTitleTag(`Jam "the" <Mac>`)).toBe(`<meta name="apple-mobile-web-app-title" content="Jam &quot;the&quot; &lt;Mac&gt;">`);
  });
});

describe("the icons", () => {
  const folder = page("icons/");
  const lines = readFileSync(new URL("DIGESTS", folder), "utf8").split("\n").filter((line) => line.trim() !== "" && !line.startsWith("#"));

  test("DIGESTS lists every icon, and its digests are the files'", () => {
    const listed = lines.map((line) => line.trim().split(/\s+/)[1]);
    expect(listed.sort()).toEqual(readdirSync(folder).filter((file) => file.endsWith(".png")).sort());
    for (const line of lines) {
      const [digest, file] = line.trim().split(/\s+/);
      expect(createHash("sha256").update(readFileSync(new URL(file, folder))).digest("hex")).toBe(digest);
    }
  });

  test("every served icon is a file there, at the size its name gives", () => {
    const sizes: Record<string, number> = { "apple-touch-icon.png": 180, "icon-192.png": 192, "icon-512.png": 512, "icon-maskable-512.png": 512 };
    expect(Object.keys(iconFiles).map((path) => path.replace("/icons/", "")).sort()).toEqual(Object.keys(sizes).sort());
    for (const [path, file] of Object.entries(iconFiles)) {
      const bytes = readFileSync(new URL(file, import.meta.url));
      const size = sizes[path.replace("/icons/", "")];
      expect(bytes.subarray(1, 4).toString("latin1")).toBe("PNG");
      expect([bytes.readUInt32BE(16), bytes.readUInt32BE(20)]).toEqual([size, size]);
    }
  });
});
