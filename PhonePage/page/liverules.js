// The live screen's pure rules, with no DOM: what `bun test` checks (PhonePage/watch.test.ts).

/** The grid xterm.js is asked to draw: the same limits as the server's `frameLimits`, since the page checks what it is sent too. */
export const gridLimits = { maxCols: 400, maxRows: 200 };

/**
 * One websocket message as a frame: `{cols, rows, text}`. The grid is the host's, or `0 0` when the host couldn't read it (or it
 * is past what the page draws), which the view fits to the phone. `{tooLarge: true}` says a screen was too large to send. Null for
 * anything else.
 */
export function parseFrame(data) {
  if (typeof data !== "string") return null;
  let value;
  try { value = JSON.parse(data); } catch { return null; }
  if (typeof value !== "object" || value === null) return null;
  // The host's screen is too large to send: the view says so and keeps what it has drawn.
  if (value.tooLarge === true) return { tooLarge: true };
  if (typeof value.text !== "string") return null;
  const { cols, rows } = value;
  if (!Number.isInteger(cols) || !Number.isInteger(rows)) return null;
  const known = cols >= 1 && rows >= 1 && cols <= gridLimits.maxCols && rows <= gridLimits.maxRows;
  return { cols: known ? cols : 0, rows: known ? rows : 0, text: value.text };
}

/**
 * The scale that fits a grid's natural width to the phone's: never above 1, since a narrow grid is not worth blowing up.
 * Zooming in beyond it is the browser's own pinch.
 */
export function fitScale(available, natural) {
  if (!(available > 0) || !(natural > 0)) return 1;
  return Math.min(1, available / natural);
}
