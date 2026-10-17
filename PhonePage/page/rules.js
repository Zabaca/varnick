// The terminal page's pure rules, with no DOM: what `bun test` checks (PhonePage/terminal.test.ts).

/** Seconds before each reconnect try while the page is visible: 1, 2, 5 and 10, then every 30. */
export const reconnectSeconds = [1, 2, 5, 10];
export const reconnectDelay = (tries) => (reconnectSeconds[tries] ?? 30) * 1000;

/**
 * Whether a connection that has just closed was a working one: only then do the tries start over. A connection that opens
 * and fails at once would otherwise reconnect every second for as long as the page is visible.
 */
export const livedLongEnough = (milliseconds) => milliseconds >= 10_000;

/** The controller a 4001 names: the reason is `{"controller": "X"}`. Null when it isn't. */
export function takenController(reason) {
  try {
    const value = JSON.parse(reason).controller;
    return typeof value === "string" && value !== "" ? value : null;
  } catch {
    return null;
  }
}

/** The close codes the server sends (`closeCode` in terminal.ts). */
export const closeCodes = { taken: 4001, ended: 4002, dropped: 4003, refused: 4004 };

/**
 * What the page does when its websocket closes:
 * - taken: the session view, "Taken over on X" (the reason), once;
 * - ended: "Session ended";
 * - refused: the relay's error, then the status, which says why;
 * - reconnect: anything else, a dropped client included, and only while the page is visible.
 */
export function closeAction(code) {
  if (code === closeCodes.taken) return "taken";
  if (code === closeCodes.ended) return "ended";
  if (code === closeCodes.refused) return "refused";
  return "reconnect";
}

/** The key bar's buttons, by name: what the phone's own keyboard lacks (Enter and paste come from it, Ctrl+C from the Ctrl key). */
export const keys = {
  esc: "\x1b",
  tab: "\t",
  up: "\x1b[A",
  down: "\x1b[B",
  left: "\x1b[D",
  right: "\x1b[C",
  enter: "\r",
};

/** What the sticky Ctrl makes of one typed character: its control code, or null when it makes nothing (it then stays on). */
export function ctrlCode(text) {
  if (text.length !== 1 || !/[a-z@[\\\]^_ ]/i.test(text)) return null;
  return String.fromCharCode(text.toUpperCase().charCodeAt(0) & 0x1f);
}

/**
 * How far a touch drag scrolls the terminal: the whole rows in `pixels` (positive is down the screen, which shows earlier
 * lines), and the pixels left over, carried into the next move so a slow drag still scrolls.
 */
export function dragLines(pixels, rowHeight) {
  if (!(rowHeight > 0)) return { lines: 0, rest: 0 };
  const lines = Math.trunc(pixels / rowHeight);
  return { lines, rest: pixels - lines * rowHeight };
}
