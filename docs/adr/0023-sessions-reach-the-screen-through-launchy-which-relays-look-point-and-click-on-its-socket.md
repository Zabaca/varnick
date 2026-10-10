# Sessions reach the screen through Launchy: `Launchy --mcp` relays look, point and click over the socket, and the running Launchy reads and acts under its own grants

With **Screen access** on (Settings › Claude, off by default), a Claude session started or restarted in a Launchy pane has one more MCP server, `launchy`, with three tools:
- **`look`** lists a window's controls, each with an id, in Hey Launchy's description. Where the window lists nothing, or Chrome hides its page, it adds the short lines of text read from a picture of the window on this Mac.
- **`point`** draws the **Arrow** at a control from `look`, or at a rectangle, with a sign that shows the session's name and its note.
- **`click`** shows the Arrow on the target for a second, then presses the control through Accessibility, or clicks at its centre, or left-clicks at a point.

The server is Launchy's own binary in a relay mode, `Launchy --mcp --pane <id>`, like `--peer`. It turns each tool call into one request line on the user-only socket the peer relay already uses and prints the reply. **The relay has no path that reads or acts.** The running Launchy does the work in its own process, under its own Accessibility and Screen Recording, with the code Hey Launchy points with: `ScreenReader`, `ScreenText` and `ArrowOverlay`. Hey Launchy's text step is a function both use.

The user accepted this on 2026-10-09, narrower than first written: look, point and click now, one implementation on Launchy's socket, and permissioning later. The problem and its options are in `docs/problems/sessions-cant-see-or-act-on-the-screen/`; this records option 01.

This amends ADR 0019 and 0021. Launchy now reads, points and clicks for sessions as well as for spoken requests. "Nothing is opened, clicked or focused" stays true of a spoken request, which still only points.

## Clicks happen without asking

- **No approval prompt.** The Arrow on the target for a second is a signal, not a gate: the user can't stop a click in that second.
- **A session started with Skip permissions clicks with no prompt at all.** One without gets Claude Code's own prompt before an MCP tool call the user hasn't allowed, and Claude Code's per-tool rules can allow `look` and `point` while still asking for `click`. Inferred, not checked.
- **There is no `type`,** no named keys or shortcuts, no drag and no scroll.
- **One click at a time across all sessions.** A second waits for the first.
- **Another Mac's session.** While another Mac or a device is in control of a session, its calls are refused: the Arrow would show where nobody is looking.
- **Never Launchy's own window.** A target in Launchy's process is refused, and so is a posted click at a point that a visible window of Launchy's has its frame over, checked right before the click is posted (the Arrow's panel, which covers the display, is not counted).
- **A stale or replaced click does not fire.** A click that waited too long for its turn, or whose Arrow was replaced during its second, is refused with "Nothing was clicked".

## What a session is shown goes to Anthropic

A window's title, its controls' names and visible text, and short lines read from a picture of the window go to Anthropic with the session's context, and stay in its transcript on this Mac. Those lines may include short text typed in a field Launchy can't place, as ADR 0021 accepted for TypeSafe. **Nothing on this path goes to TypeSafe,** and Gemma isn't involved. The switch is the user's consent, and its detail says this, as the README and SECURITY.md do.

## The switch

- **Kept,** though it is not a permission. It is the consent to what goes to Anthropic, it keeps the tools out of every session's context and process list until wanted, and it is read at every call, so turning it off stops running sessions at once. That is the one stop there is while nothing asks.
- **Independent of Point at the screen,** Hey Launchy and the TypeSafe gate.
- **A session gains the tools at its start,** since Claude Code reads `--mcp-config` at launch. A pane started before the switch was turned on gains them with Restart.

## Permissioning is deferred

Every process in a Launchy pane gets Launchy's grants (the correction in ADR 0019). So whenever Launchy holds Accessibility and Screen Recording, any session can act directly, through `osascript`, `screencapture` or its own code, and an approval prompt would gate only the polite path: a pane process could click Allow in Launchy's own prompt. The per-pane switch, approval, deny list, indicator, per-pane record and a check of the caller's ancestry come back once pane processes no longer get Launchy's grants (`panes-share-launchys-permissions`, option 01: a disclaimed spawn, measured on 2026-10-09). At that point Launchy's command-line modes that read or act (`--ask --app`, `--draw`) must not do so for a caller either.

## The socket request

- **It has no `op`.** A line with a `screen` key holding the request's own version, the pane id, the tool and its arguments is told apart in the app's handler, before any peer check, only by having no `op`. A line with an `op` is a peer's request whatever else it holds.
- **No peer can send one.** The peer relay refuses any line without a known `op`, and every line it passes to the app carries one. So neither a paired Mac nor a device can send a screen request, and `PeerProtocol.version` doesn't change.
- **A server from an older launch** is answered "Restart this session to update Launchy's tools".

## Considered Options

- **Look and point only (option 02).** Rejected: option 01 includes it and adds click, by the user's choice.
- **Grant Launchy and let every pane inherit (option 03).** Today's state, not an answer; the planned end is that panes stop getting the grants.
- **The broker as a command line, `launchy-screen` (option 04).** Not built. It would reach any agent, but Claude reaches it through Bash, whose only gate a Skip-permissions session never shows. It could sit on the same socket requests later.
- **Start the chosen session outside zmx (option 05).** Rejected: every pane process is attributed to Launchy, zmx-hosted or not.
- **A disclaimed spawn first.** It makes permissioning real, but it is a problem of its own (`panes-share-launchys-permissions`) and the user chose to ship the tools now.

## Consequences

- **A session on this Mac can look at, point at and click on this Mac's screen.** Until panes stop sharing Launchy's grants it could do the same with its own tools; what Launchy adds is the Arrow before a click, the switch and one implementation.
- **A click that lands on another app moves focus to it.** Launchy's panel hides when it loses key, unless it is pinned. A click at a point also moves the pointer there. A press through Accessibility usually leaves focus alone (inferred).
- **Nothing is logged but the tool, the outcome's kind, durations and counts.** Never a label, note, window title, app name or session name.
- **Changing what `look` returns is a privacy change,** needing this ADR, the README, SECURITY.md and the switch's detail amended, as for ADR 0019.
- **The tools' text is Hey Launchy's:** `ScreenElement.description`, the 255-element cap, the "dimmed" and "under the pointer" marks, no field's value and nothing of a secure field. A fix to the read is a fix to both.
