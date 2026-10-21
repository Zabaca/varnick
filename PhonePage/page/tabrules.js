// The tab view's pure rules, with no DOM: what `bun test` checks (PhonePage/tab.test.ts). The page shows a tab one pane at a time (ADR 0034).

/** The tab's route: `#t=<tab>` and optionally `&p=<pane>`, ids as the host writes them (lowercase uuids). Null for any other hash. */
export function parseTabHash(hash) {
  const match = /^#t=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:&p=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}))?$/.exec(hash);
  return match ? { tab: match[1], pane: match[2] ?? null } : null;
}

export const tabHash = (tab, pane) => (pane ? `#t=${tab}&p=${pane}` : `#t=${tab}`);

/** Whether a kind of pane runs in a zmx session of its own (Claude and terminal), which a device can attach to and which `end` closes by its session. */
export const hasSession = (kind) => kind === "claude" || kind === "terminal";

/** A pane whose zmx session runs, which the page can open as a terminal or a live screen. */
export const isOpenable = (pane) => pane.session !== null && pane.running === true;

/**
 * Whether a pane the page just added can be shown as soon as the host lists it: a page, an app and a file at once (a note, or a frame once the
 * page server has looked at it), a Claude or terminal pane once its session runs.
 */
export const readyToShow = (pane) => (hasSession(pane.kind) ? isOpenable(pane) : true);

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

/**
 * Whether an address can't be loaded from another machine: none yet, one that doesn't parse, a scheme other than http and https (`about:`,
 * `file:` would load the viewer's own), or a host that is the machine itself: localhost and `*.localhost`, 127.0.0.0/8 however it is written
 * (`127.1`, `2130706433`: the URL parser turns them into dotted form), ::1, the unspecified addresses and IPv4-mapped IPv6. The Swift copy is
 * `PeerPane.isLocalAddress`, which `SessionRecord` uses; this one is the page's and the proxy's.
 */
export function isLocalAddress(url) {
  if (!url) return true;
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return true;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return true;
  const host = parsed.hostname.replace(/^\[|\]$/g, "").replace(/\.$/, "").toLowerCase();
  return host === "" || host === "localhost" || host.endsWith(".localhost") || host === "::" || host === "::1" || host.startsWith("::ffff:")
    || host === "0.0.0.0" || /^127(\.\d{1,3}){3}$/.test(host);
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

/** Whether Add pane is offered for the tab: this phone is in control of it, and it has a pane to put the new one beside (option 03 of panes-open-only-by-hand-at-a-mac). */
export const offersAdd = (tab) => tab.mine === true && tab.panes.length > 0;

/**
 * Whether Close is offered in the switcher: this phone controls the tab and it has more than one pane. The tab's only pane is closed by End, which ends
 * the tab the same way (the host decides whether a pane is the last, `closePane` in launch.ts).
 */
export const offersClose = (tab) => tab.mine === true && tab.panes.length > 1;

/** Whether `pane` is the last Claude or terminal pane of the tab that runs: once it is closed nothing in the tab can be controlled from this phone. */
const lastRunning = (tab, pane) => isOpenable(pane) && !tab.panes.some((other) => other.id !== pane.id && hasSession(other.kind) && isOpenable(other));

/** What Close asks before it closes the pane shown: what stops, in the words of its kind, and when the tab can no longer be changed from here. */
export function closeQuestion(tab, pane, host) {
  const where = host || "its host";
  const what = {
    claude: `Close “${paneLabel(pane)}”? Claude stops and its conversation goes to the tab's history.`,
    terminal: `Close this terminal? It ends on ${where}, and whatever runs in it stops.`,
    app: `Close ${paneLabel(pane)}? Its server stops on ${where}.`,
    file: `Close ${paneLabel(pane)}? The file itself isn't touched.`,
    web: `Close the page at ${paneLabel(pane)}?`,
  }[pane.kind] ?? "Close this pane?";
  const last = hasSession(pane.kind) && lastRunning(tab, pane) ? " It is the tab's last Claude or terminal pane, so this phone can't change the tab afterwards." : "";
  return `${what} The tab keeps its other panes.${last}`;
}

/** Whether the switcher is drawn: with more than one pane, and with one when Add pane is its button. */
export const showsSwitcher = (tab) => tab.panes.length > 1 || offersAdd(tab);

/**
 * Whether Restart is offered over the pane shown: a Claude session that runs, in a tab this phone controls, the same rule as Add pane and End. The host
 * decides again when it is asked.
 */
export const offersRestart = (tab, pane) => tab.mine === true && pane?.kind === "claude" && isOpenable(pane);

/**
 * Whether Done is offered in the tab's menu (protocol 33, ADR 0045): the tab has a Claude pane, whether or not this phone controls it. The host closes the
 * tab whoever controls or started it, and refuses a tab with no Claude pane, as a Mac's Done needs one. The single-session view (`#s=`) has no tab.
 */
export const offersDone = (tab) => Boolean(tab) && tab.panes.some((pane) => pane.kind === "claude");

/** What Done asks before the host closes the tab: it always asks, whether or not a session works, since the phone can't see what runs. */
export const doneQuestion = (title, host) => `Done with “${title}”? Every pane of it ends on ${host || "its host"}, terminals and pages included, and it goes to Completed.`;

/** What Restart asks before it ends the session's claude and starts it again. */
export const restartQuestion = (title) => `Restart “${title}”? Claude stops what it is doing and starts again in this pane, picking up the conversation where it was.`;
