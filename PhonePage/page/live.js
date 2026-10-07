// The live screen: a read-only xterm.js that draws each frame from scratch at the grid it came with (the Macs' cards do the same),
// scaled to the phone's width. It takes no input and is never focused; zooming in is the browser's own pinch. A grid of `0 0` means
// the host couldn't read it: the view then fits the screen to the phone instead.

import { Terminal } from "/vendor/xterm.mjs";
import { FitAddon } from "/vendor/addon-fit.mjs";
import { fitScale } from "/liverules.js";

const fontSize = 12;
/** The host's screen has its own cursor, which isn't this view's to show. */
const hideCursor = "\x1b[?25l";
/** A full reset through the parser, so it comes after any frame still waiting to be parsed (`term.reset()` wouldn't): the screen is drawn from scratch. */
const fromScratch = "\x1bc";

/**
 * `host` scrolls, `sizer` is as big as the scaled screen, `mount` holds xterm at its natural size. All three exist in the page and
 * must be on screen (not `hidden`) when this is made, since xterm measures its cells as it opens.
 */
export function createLive({ host, sizer, mount }) {
  const term = new Terminal({
    fontSize,
    // Each frame is the whole screen, drawn again: what scrolled off is the host's tail, which this view doesn't keep.
    scrollback: 0,
    disableStdin: true,
    cursorBlink: false,
    cursorInactiveStyle: "none",
    theme: { background: "#111" },
    // A link the screen printed (OSC 8) opens nothing here.
    linkHandler: { allowNonHttpProtocols: false, activate: () => {} },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(mount);
  // Never focused, never typed into: not reachable by Tab, and nothing the screen asks of a terminal is answered.
  if (term.textarea) {
    term.textarea.tabIndex = -1;
    term.textarea.readOnly = true;
    term.textarea.setAttribute("aria-hidden", "true");
  }
  let last = null;
  let disposed = false;

  /** Sizes the scaled screen once xterm has the frame: its natural size is its cell grid, which is measured, not guessed. */
  function place() {
    if (disposed) return;
    const screen = term.element?.querySelector(".xterm-screen");
    if (!screen) return;
    const natural = { width: screen.offsetWidth, height: screen.offsetHeight };
    if (natural.width === 0 || natural.height === 0) return;
    const scale = fitScale(host.clientWidth, natural.width);
    mount.style.width = `${natural.width}px`;
    mount.style.height = `${natural.height}px`;
    mount.style.transform = scale === 1 ? "" : `scale(${scale})`;
    sizer.style.width = `${Math.ceil(natural.width * scale)}px`;
    sizer.style.height = `${Math.ceil(natural.height * scale)}px`;
  }

  /** The screen as the host couldn't read it: wrapped to the phone's own size, at full scale. */
  function placeFitted() {
    mount.style.transform = "";
    mount.style.width = `${host.clientWidth}px`;
    mount.style.height = `${host.clientHeight}px`;
    sizer.style.width = `${host.clientWidth}px`;
    sizer.style.height = `${host.clientHeight}px`;
    try { fit.fit(); } catch { /* not measurable yet */ }
  }

  function draw() {
    if (!last || disposed) return;
    const { cols, rows, text } = last;
    if (cols > 0) {
      if (term.cols !== cols || term.rows !== rows) term.resize(cols, rows);
      term.write(fromScratch + text + hideCursor, place);
    } else {
      placeFitted();
      term.write(fromScratch + text + hideCursor);
    }
  }

  return {
    /** Draws a frame from scratch. */
    show(frame) {
      last = frame;
      draw();
    },
    /** The phone's width changed (rotation): the scale is worked out again, and a screen with no grid wraps again. */
    refit() {
      if (!last) return;
      if (last.cols > 0) place();
      else draw();
    },
    dispose() {
      disposed = true;
      term.dispose();
      mount.replaceChildren();
      mount.style.cssText = "";
      sizer.style.cssText = "";
    },
  };
}
