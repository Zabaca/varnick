// The tab view's pure rules, with no DOM: what `bun test` checks (PhonePage/tab.test.ts). The page shows a tab one pane at a time (ADR 0034).

/** The tab's route: `#t=<tab>` and optionally `&p=<pane>`, ids as the host writes them (lowercase uuids). Null for any other hash. */
export function parseTabHash(hash) {
  const match = /^#t=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:&p=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}))?$/.exec(hash);
  return match ? { tab: match[1], pane: match[2] ?? null } : null;
}

export const tabHash = (tab, pane) => (pane ? `#t=${tab}&p=${pane}` : `#t=${tab}`);

/** A pane whose zmx session runs, which the page can open as a terminal or a live screen. */
export const isOpenable = (pane) => pane.session !== null && pane.running === true;

/** Claude, then terminal, then the rest: the words the switcher uses for a kind. */
const kindWords = { claude: "Claude", terminal: "Terminal", web: "Page", app: "App", file: "File", transcript: "Transcript" };
export const kindWord = (kind) => kindWords[kind] ?? "Pane";

const lastPart = (path) => path.split("/").filter(Boolean).pop() ?? path;

/** The host of an address, or the address itself when it isn't one. */
export function addressHost(url) {
  try {
    return new URL(url).host || url;
  } catch {
    return url;
  }
}

/** What a pane is called in the switcher: its title, else what its kind would say. */
export function paneLabel(pane) {
  if (pane.kind === "file" && pane.file) return lastPart(pane.file);
  if (pane.kind === "web" && pane.url) return addressHost(pane.url);
  if (pane.kind === "app") return pane.app ?? pane.title ?? kindWord(pane.kind);
  if (pane.kind === "transcript") return "Transcript";
  return pane.title || kindWord(pane.kind);
}

/** The tab's name, else its first Claude session's title, else its first pane's. */
export function tabTitle(tab) {
  return tab.name || tab.panes.find((pane) => pane.kind === "claude" && pane.title)?.title || tab.panes[0]?.title || "Tab";
}

/** "Claude, terminal, page": what a row says of a tab's panes. A tab of one pane says its kind alone. */
export function paneSummary(tab) {
  const words = [];
  for (const pane of tab.panes) {
    const word = kindWord(pane.kind).toLowerCase();
    if (!words.includes(word)) words.push(word);
  }
  const count = tab.panes.length === 1 ? "" : `${tab.panes.length} panes · `;
  return count + words.join(", ");
}

/**
 * The pane to show: the one asked for if the tab has it, else the first that can be opened (a Claude or terminal pane that runs), else
 * the first. Null for a tab with no pane.
 */
export function choosePane(tab, wanted) {
  return tab.panes.find((pane) => pane.id === wanted) ?? tab.panes.find(isOpenable) ?? tab.panes[0] ?? null;
}

/** Whether two lists of panes would look the same in the switcher, so a refresh doesn't rebuild it for nothing. */
export function samePanes(a, b) {
  return a.length === b.length && a.every((pane, index) => pane.id === b[index].id && paneLabel(pane) === paneLabel(b[index]) && isOpenable(pane) === isOpenable(b[index]));
}

/** The address the tab view frames a web or app pane at, through the host's port proxy, or null when the pane has none. */
export const framedAddress = (pane) => ((pane.kind === "web" || pane.kind === "app") && pane.proxy ? pane.proxy : null);

/** An address only the host itself can reach (localhost and `*.localhost`, 127.0.0.0/8, ::1, the unspecified addresses). */
export function isLocalAddress(url) {
  if (!url) return true;
  try {
    const host = new URL(url).hostname.replace(/^\[|\]$/g, "").toLowerCase();
    return host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "::" || host === "0.0.0.0" || /^127(\.\d{1,3}){3}$/.test(host);
  } catch {
    return true;
  }
}

/**
 * What a pane that isn't a terminal says: its note, and the address or path it is at. A file's text is the page's to fetch, so it has none
 * here. A page at an outside address is opened in the browser, not framed; one the host proxies is framed (`framedAddress`) and says nothing.
 */
export function paneNote(pane, host) {
  switch (pane.kind) {
    case "claude":
    case "terminal":
      return { text: `${kindWord(pane.kind)} isn't running on ${host}.`, detail: pane.note ?? "" };
    case "file":
      return { text: "", detail: pane.file ?? "" };
    case "transcript":
      return { text: `The Transcript stays on ${host}.`, detail: "It is what the host heard while listening, and it never leaves that Mac." };
    case "app":
      return { text: `${pane.app ?? "This app"} runs on ${host}.`, detail: unreachable(pane, `Its server is at ${pane.url ?? "an address"} there, which only ${host} can reach.`) };
    case "web":
      return isLocalAddress(pane.url)
        ? { text: `This page runs on ${host}.`, detail: unreachable(pane, `It is at ${pane.url || "an address"} there, which only ${host} can reach.`) }
        : { text: `A page at ${addressHost(pane.url)}.`, detail: pane.url };
    default:
      return { text: "This version of the page can't show this pane.", detail: "" };
  }
}

/** Why a page or an app on the host can't be shown here: the host's own reason, else what the pane is at. */
const unreachable = (pane, where) => `${where} ${pane.proxyNote ? `It can't be shown here: ${pane.proxyNote}` : "It can't be shown here."}`;

/** Whether Take over is offered for the tab: something in it runs, and this phone isn't in control of it. */
export const offersTake = (tab) => tab.panes.some(isOpenable) && !tab.mine;
