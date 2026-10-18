// Add pane's pure rules, with no DOM: which kinds the form shows, when Add can be pressed and what it sends. `bun test` checks them
// (PhonePage/tab.test.ts). The server decides what the host offers (`splitOffer` in launch.ts); the form only draws it.

import { hasSession, kindWord } from "./tabrules.js";

/** The kinds Add pane knows, in the order of its row; the words are the tab view's (`kindWord`). */
export const addKinds = ["claude", "terminal", "app", "web", "file"];
export { kindWord };

/**
 * The kinds the form shows: those the server offered for this tab and pane, in the form's order. Claude and a terminal are always there, and
 * they are all there is until the server has answered (or when it doesn't know the others, as a host built before them).
 */
export function kindsOffered(offer) {
  const sent = Array.isArray(offer?.kinds) ? offer.kinds : [];
  return addKinds.filter((kind) => hasSession(kind) || sent.includes(kind));
}

/** The kind to show: the one chosen if it is offered, else Claude. */
export const kindShown = (kind, offered) => (offered.includes(kind) ? kind : "claude");

/** Whether Add can be pressed: Claude and a terminal always can, the others once they have what they need. */
export function addable(s) {
  switch (s.kind) {
    case "app": return Boolean(s.app);
    case "web": return s.url.trim() !== "";
    case "file": return Boolean(s.file);
    default: return true;
  }
}

/** `POST /api/split`'s body for the form's state: the kind's own field only, so a field left over from another kind is never sent. */
export function addBody(s, prompt) {
  const place = { tab: s.tab, pane: s.pane, kind: s.kind };
  switch (s.kind) {
    case "claude": return { ...place, agent: s.agent, prompt };
    case "app": return { ...place, app: s.app };
    case "web": return { ...place, url: s.url.trim() };
    case "file": return { ...place, file: s.file };
    default: return place;
  }
}

/** The path of an entry of the folder being browsed. */
export const entryPath = (dir, name) => `${dir.replace(/\/+$/, "")}/${name}`;

/** The folder as the picker shows it: below the shown pane's folder it is the part after it, so a deep path doesn't fill a narrow screen. */
export function relativeTo(root, dir) {
  const base = root.replace(/\/+$/, "");
  if (dir === root || dir === base) return "./";
  return dir.startsWith(`${base}/`) ? `./${dir.slice(base.length + 1)}` : dir;
}
