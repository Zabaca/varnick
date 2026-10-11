# Sessions reach the screen through Varnick: `Varnick --mcp` relays look, point and click over the socket, and the running Varnick reads and acts under its own grants

With **Screen access** on (Settings › Claude, off by default), a Claude session started or restarted in a Varnick pane has one more MCP server, `varnick`, with three tools:
- **`look`** lists a window's controls, each with an id, in Hey Varnick's description. Where the window lists nothing, or Chrome hides its page, it adds the short lines of text read from a picture of the window on this Mac.
- **`point`** draws the **Arrow** at a control from `look`, or at a rectangle, with a sign that shows the session's name and its note.
- **`click`** shows the Arrow on the target for a second, then brings the target's app and window forward and waits for it to be frontmost. It then presses the control through Accessibility, or clicks at its centre, or left-clicks at a point. A control in a web page (an `AXWebArea` above it, or a browser or Electron app) is clicked, not pressed, since a press there can report success and do nothing. The control's frame is read again once the app is in front.

The server is Varnick's own binary in a relay mode, `Varnick --mcp --pane <id>`, like `--peer`. It turns each tool call into one request line on the user-only socket the peer relay already uses and prints the reply. **The relay has no path that reads or acts.** The running Varnick does the work in its own process, under its own Accessibility and Screen Recording, with the code Hey Varnick points with: `ScreenReader`, `ScreenText` and `ArrowOverlay`. Hey Varnick's text step is a function both use.

The user accepted this on 2026-10-09, narrower than first written: look, point and click now, one implementation on Varnick's socket, and permissioning later. The problem and its options are in `docs/problems/sessions-cant-see-or-act-on-the-screen/`; this records option 01.

This amends ADR 0019 and 0021. Varnick now reads, points and clicks for sessions as well as for spoken requests. "Nothing is opened, clicked or focused" stays true of a spoken request, which still only points.

## Clicks happen without asking

- **No approval prompt.** The Arrow on the target for a second is a signal, not a gate: the user can't stop a click in that second.
- **A session started with Skip permissions clicks with no prompt at all.** One without gets Claude Code's own prompt before an MCP tool call the user hasn't allowed, and Claude Code's per-tool rules can allow `look` and `point` while still asking for `click`. Inferred, not checked.
- **There is no scroll.** Typing, named keys and shortcuts, and drag were added on 2026-10-10 (Amendments).
- **One click at a time across all sessions.** A second waits for the first.
- **Another Mac's session.** While another Mac or a device is in control of a session, its calls are refused: the Arrow would show where nobody is looking.
- **Never Varnick's own window.** A target in Varnick's process is refused, and so is a posted click at a point that a visible window of Varnick's has its frame over, checked right before the click is posted, after the app has come forward (the Arrow's panel, which covers the display, is not counted). Varnick never moves its panel: a pinned one still over the point refuses the click, and the session asks the user to move or hide it.
- **A stale or replaced click does not fire.** A click that waited too long for its turn, or whose Arrow was replaced during its second, is refused with "Nothing was clicked".

## What a session is shown goes to Anthropic

A window's title, its controls' names and visible text, and short lines read from a picture of the window go to Anthropic with the session's context, and stay in its transcript on this Mac. Those lines may include short text typed in a field Varnick can't place, as ADR 0021 accepted for TypeSafe. **Nothing on this path goes to TypeSafe,** and Gemma isn't involved. The switch is the user's consent, and its detail says this, as the README and SECURITY.md do.

## The switch

- **Kept,** though it is not a permission. It is the consent to what goes to Anthropic, it keeps the tools out of every session's context and process list until wanted, and it is read at every call, so turning it off stops running sessions at once. That is the one stop there is while nothing asks.
- **Independent of Point at the screen,** Hey Varnick and the TypeSafe gate.
- **A session gains the tools at its start,** since Claude Code reads `--mcp-config` at launch. A pane started before the switch was turned on gains them with Restart.

## Permissioning is deferred

Every process in a Varnick pane gets Varnick's grants (the correction in ADR 0019). So whenever Varnick holds Accessibility and Screen Recording, any session can act directly, through `osascript`, `screencapture` or its own code, and an approval prompt would gate only the polite path: a pane process could click Allow in Varnick's own prompt. The per-pane switch, approval, deny list, indicator, per-pane record and a check of the caller's ancestry come back once pane processes no longer get Varnick's grants (`panes-share-launchys-permissions`, option 01: a disclaimed spawn, measured on 2026-10-09). At that point Varnick's command-line modes that read or act (`--ask --app`, `--draw`) must not do so for a caller either.

## The socket request

- **It has no `op`.** A line with a `screen` key holding the request's own version, the pane id, the tool and its arguments is told apart in the app's handler, before any peer check, only by having no `op`. A line with an `op` is a peer's request whatever else it holds.
- **No peer can send one.** The peer relay refuses any line without a known `op`, and every line it passes to the app carries one. So neither a paired Mac nor a device can send a screen request, and `PeerProtocol.version` doesn't change.
- **A server from an older launch** is answered "Restart this session to update Varnick's tools".

## Considered Options

- **Look and point only (option 02).** Rejected: option 01 includes it and adds click, by the user's choice.
- **Grant Launchy and let every pane inherit (option 03).** Today's state, not an answer; the planned end is that panes stop getting the grants.
- **The broker as a command line, `launchy-screen` (option 04).** Not built. It would reach any agent, but Claude reaches it through Bash, whose only gate a Skip-permissions session never shows. It could sit on the same socket requests later.
- **Start the chosen session outside zmx (option 05).** Rejected: every pane process is attributed to Launchy, zmx-hosted or not.
- **A disclaimed spawn first.** It makes permissioning real, but it is a problem of its own (`panes-share-launchys-permissions`) and the user chose to ship the tools now.

## Consequences

- **A session on this Mac can look at, point at and click on this Mac's screen.** Until panes stop sharing Varnick's grants it could do the same with its own tools; what Varnick adds is the Arrow before a click, the switch and one implementation.
- **A click brings its app forward first, then clicks.** The first click on a window of an app that is not in front only focuses it, so Varnick activates the app and raises the window before it presses or posts, and refuses ("Nothing was clicked") if the app is not frontmost within a second. Varnick's panel hides when it loses key, unless it is pinned. A click at a point also moves the pointer there.
- **Nothing is logged but the tool, the outcome's kind, durations and counts.** Never a label, note, window title, app name or session name.
- **Changing what `look` returns is a privacy change,** needing this ADR, the README, SECURITY.md and the switch's detail amended, as for ADR 0019.
- **The tools' text is Hey Varnick's:** `ScreenElement.description`, the 255-element cap, the "dimmed" and "under the pointer" marks, no field's value and nothing of a secure field. A fix to the read is a fix to both.

## Amendments

- **2026-10-10, option 06 of `sessions-cant-see-or-act-on-the-screen`: `type`, `drag` and `window`, and a focus line in `look`.** The server has three more tools, built as `click` is: the Arrow on the target for a second first, one action at a time across all sessions, and the switch, the pane, the request's age and the Arrow's generation checked again before acting. Nothing asks, as for `click`, and the request's version stays 1.
  - **`type`** puts the focus on a control from `look`, or uses the focus the app has, then types `text` and presses `keys` as key events posted to the app in front, never a field's value set through Accessibility. A call refuses while a secure text field has focus, where Varnick can see one (a Chrome page whose tree is hidden, a canvas app, a remote desktop and a virtual machine are the gap, as ADR 0021 accepted for reading), and refuses Varnick's own anywhere-shortcuts, log out, lock screen and Force Quit. Every character and key is checked right before it is posted, and typing stops when Varnick's panel has the keyboard, another app comes forward, the switch goes off or the Arrow is replaced. The text is never logged.
  - **`drag`** posts a mouse-down, a drag and a mouse-up between two controls or points, with click's refusals at both ends, and lets go on every path.
  - **`window`** moves or resizes an app's window through Accessibility, with no pointer and no activation.
  - **`look`** gives the window an id (`w1`), taken only by `point` and `window`, and a line saying which control has focus, by its id or its kind, never its label or value. That is a privacy change, a small one: `docs/privacy-and-security.md`, the README, the guide and the switch's detail say so.
  - Typing is the strongest tool a session gets: whatever can steer a session can type as the user. Claude Code's per-tool rules can still ask before `type`, `drag` and `window` while allowing `look` and `point` (inferred, not checked). Permissioning stays deferred.
- **2026-10-10, option 07 of `sessions-cant-see-or-act-on-the-screen`: `look` can return a picture of the window.** `look` takes `picture: true`, and `rect` to crop it to an area in screen points. The reply is the usual listing and an MCP image content item. The request's version stays 1: the reply gets an optional picture, and an older Varnick or server ignores what it doesn't know.
  - **The capture is the text step's.** ScreenCaptureKit, the one window `look` read, so no legacy-capture prompt, and Varnick's panel and Arrow are not in it. It needs Screen Recording and is refused without it, with the text step's words.
  - **It fits the socket.** The picture is scaled and encoded to a size worked out from the socket's line cap, which is unchanged for peers' requests and for every reply; the figures are in where-it-breaks.md. Only the check for the end of a line was made linear in the line's length.
  - **A privacy change, a large one.** A picture shows everything on the window, typed text included, which the listing leaves out (ADR 0019) and the text step drops (ADR 0021). It goes to Anthropic with the session and stays in its transcript on this Mac, and nothing on this path goes to TypeSafe. `docs/privacy-and-security.md`, the README, the guide and the switch's detail say so.
  - **Password fields are painted black where Varnick can see them:** the secure text fields the walk of `look` finds, and the focused one when it is secure, before the picture is encoded. The gaps are the ones accepted for reading and typing, and a few more; `docs/privacy-and-security.md` lists them, and the reply says when Varnick reached only part of a window. A window that changed size between the walk and the capture refuses the call.
  - **The log** holds the picture's kind, pixel size and byte count, and how many fields were hidden. Never what it showed.
