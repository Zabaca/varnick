---
problem: sessions-cant-see-or-act-on-the-screen
title: Launchy brokers look, point and click for sessions through an MCP server on its socket, with permissioning deferred
summary: Accepted on 2026-10-09, narrower than first written. A Settings switch, Screen access, is off by default. Each Claude pane started while it is on gets a stdio MCP server, `Launchy --mcp`, with three tools. `look` lists a window's controls through Hey Launchy's Accessibility read, plus text read from a picture of the window where the app exposes none. `point` draws the Arrow, with the session's note, at a control from `look` or at a rectangle. `click` presses a control or clicks at a point, after showing the Arrow on the target for a second. The server only relays. Each call is one request on Launchy's existing socket, and the running Launchy does the work with Hey Launchy's code, under its own grants. There is no `type`, no per-click approval and no per-pane switch. Permissioning is deferred because every pane process already gets Launchy's grants and could act around an approval (`panes-share-launchys-permissions`). It comes after that problem's option 01 makes Launchy the only way to the screen.
status: accepted
---

## Solution

**Screen access** is a switch in Settings › Claude, off by default. A Claude pane started or restarted while it is on runs claude with one more MCP server, `launchy`, passed inline with `--mcp-config`. The server is Launchy's own binary in a relay mode, `Launchy --mcp`. It turns each tool call into one request line on the socket the peer relay already uses, and prints the reply. The running Launchy checks the switch and does the work in its own process with the code Hey Launchy points with: `ScreenReader`, `ScreenText` and `ArrowOverlay`.

| Tool | Arguments | What it does |
|---|---|---|
| `look` | `app` (optional), `text` (optional) | Reads the focused window of the named app, or of the app in front other than Launchy. Returns its title, its frame and its controls in Hey Launchy's description, each with an id (`e1`, `e2`…). Where the window lists nothing, or Chrome hides its page, it adds the short lines of text read from a picture of the window on this Mac (`t1`, `t2`…). `text` asks for those lines anyway. |
| `point` | `id` or `rect`, and `note` | Draws the Arrow at that control or rectangle. The sign shows the session's name and the note. It stays 8 s, or until the next `point` or `click`. |
| `click` | `id` or `at` | Shows the Arrow on the target for 1 s. Then it presses the control through Accessibility, or clicks at the control's centre when the control has no press action, or left-clicks at the point given. |

Nothing asks before a click. The Arrow on the target is how the user sees what is about to be clicked.

## Trade-offs

- **One implementation.**
  - Hey Launchy and the sessions read, recognise and draw with the same code, so a fix to one is a fix to both.
  - Only the running Launchy reads or acts. The MCP server is a relay with no path that reads or acts, like `--peer`.
- **Clicks without approval.**
  - The Arrow before a click is a signal, not a gate. The user can't stop a click in the second it shows.
  - A session started with Skip permissions clicks without any prompt.
  - A session without Skip permissions gets Claude Code's own prompt before a tool call the user hasn't allowed, as for any MCP tool. Claude Code's per-tool rules can allow `look` and `point` while still asking for `click` (`mcp__launchy__click`). Inferred, not checked.
- **Permissioning deferred, because today it would buy little.**
  - macOS attributes every pane process to Launchy, zmx-hosted ones included. So whenever Launchy holds Accessibility and Screen Recording, any session can act directly, through `osascript`, `screencapture` or its own code (measured 2026-10-09; the problem's Today, `panes-share-launchys-permissions`).
  - An approval prompt would gate only the polite path. A pane process could also click Allow in Launchy's own prompt.
  - The per-pane switch, approval, deny list, indicator and record return once pane processes no longer get Launchy's grants (Further Notes).
- **What a session is shown goes to Anthropic,** with the session's context, and stays in its transcript on this Mac. That covers:
  - a window's title and its controls' labels;
  - the visible text beside those controls;
  - short lines read from a picture of the window.

  Those lines may include short text typed in a field Launchy can't place, as ADR 0021 accepted for TypeSafe. Nothing goes to TypeSafe on this path. The switch is the user's consent, and its detail says this.
- **MCP rather than a command line.**
  - Claude Code lists the tools by name and can allow or ask per tool.
  - Option 04's command line would reach other agents too, and could sit on the same socket requests later.
- **A session gains the tools at its start.** Claude Code reads `--mcp-config` at launch. A pane started before the switch was turned on gains the tools at its next start, or with Restart (⌘⌥R).
- **A click that lands on another app moves focus to it.**
  - Launchy's panel hides when it loses key, unless it is pinned, as it does when the user clicks elsewhere.
  - A click at a point also moves the pointer there.
  - A press through Accessibility usually leaves focus where it was. Inferred.
- **A session on this Mac acts on this Mac's screen only.** While another Mac or a device is in control of the session, its calls are refused: the Arrow would show where nobody is looking.

## User Stories

1. As a Launchy user, I want to turn Screen access on once, so that the sessions I start or restart can see the window I'm working in.
2. As a Launchy user, I want a session to show me where to click with the Arrow, signed with its name.
3. As a Launchy user, I want a session to click for me, and to see the Arrow on what it is about to click first.
4. As a Launchy user, I want to turn Screen access off and have every session's tools stop at once, without restarting them.
5. As a Launchy user, I want a session to read a Chrome page's or a canvas app's text when the app exposes no controls.
6. As a Launchy user, I want my sessions' look, point and click to behave like Hey Launchy's, since they share its code.

## Implementation Decisions

**The switch**
- **Where:** Settings › Claude, under Skip permissions. Its UserDefaults key is `screenAccess`, a bool, off when missing.
- **Its detail** says:
  - that sessions started or restarted while it is on get look, point and click;
  - that what they are shown goes to Anthropic with the session;
  - that clicks happen without asking, with the Arrow on the target first;
  - that every pane already has Launchy's permissions (SECURITY.md).
- **Its row** shows Accessibility and Screen Recording, with their Grant buttons, as Point at the screen's row does. It uses one view shared by both rows, not a copy.
- **What it is independent of:** Point at the screen, Hey Launchy and the TypeSafe gate. Nothing here goes to TypeSafe, and Gemma isn't involved.

**The server**
- **The mode:** `Launchy --mcp --pane <pane id>`, run before anything of the app starts, as `--peer` is.
  - It speaks newline-delimited JSON-RPC on standard input and output.
  - It answers `initialize`, `tools/list`, `tools/call` and `ping`, and ignores notifications.
  - It exits when its input ends.
- **No MCP library.** The protocol subset is small, and the tool list and schemas are fixed in the binary.
- **No reading or acting.** Each `tools/call` sends one line on the socket and waits up to 15 s. The reply becomes the call's text content, with `isError` set on a refusal. With no socket, the result is "Launchy isn't running".
- **The command line.** `ClaudeSession.launchClaude` puts `--mcp-config` and a JSON string first, before `--settings`, only for a Claude pane on this Mac with the switch on.
  - The JSON names one server, `launchy`, whose command is the peer link in Application Support (`PeerLink`). The link points at this launch's snapshot, so a session's server is the build that was running when it started. `make run`'s kill pattern matches only the bare binary with no arguments, so a restart doesn't end the server.
  - The arguments are `--mcp`, `--pane` and the pane's id. The id is passed as an argument, so nothing depends on claude passing its environment on.
  - `--mcp-config` takes several values and stops at `--settings`, the next option.
  - No file is written.
  - `ClaudeCommand.arguments` and the headless relay's launch are unchanged, so `LaunchyPeer` needs no Linux build.

**The socket request**
- **The line:** a JSON object with a `screen` key holding the request's own version, the pane id, the tool and its arguments. It never has an `op`.
- **Telling it apart:** the app's handler tells a screen request from a peer request before the peer version check. A line with an `op` is always a peer request, whatever else it holds.
- **Why no peer can send one:** the relay refuses any line without a known `op`, and every line it passes to the app carries one. It forwards `start`, `resume`, `end`, `projects` and `agents`, and passes `hello`, `upgrade` and `restart` for the app's part of their answers. So neither a paired Mac nor a device can send a screen request.
- **Versions:** `PeerProtocol.version` doesn't change. A screen request whose own version differs (a server from an older launch) is answered "Restart this session (⌘⌥R) to update Launchy's tools".
- **Where it is answered:** on the main actor, by a new type that owns the tools. Reads, presses and posted events run off the main actor, as `ScreenReader.read` does.

**`look`**
- **Which app.**
  - With `app`, it is matched as `--ask --app` matches it (`ScreenReader.application(named:)`).
  - Without it, the app with focus other than Launchy, else the frontmost window's app (`ScreenReader.focusedApplication`).
  - Both skip Launchy's own process, so Launchy's panel is never read.
- **The read** is `ScreenReader.read` unchanged:
  - the focused window, within the walk's limits;
  - the 255-element cap;
  - "dimmed" and "under the pointer" marked;
  - no field's value, and nothing of a secure field.
- **The text.** Hey Launchy's text step is a function both use, lifted out of `SpokenPipeline.lookAtScreen` with Hey Launchy's behaviour unchanged.
  - It captures that window alone and recognises it on this Mac.
  - It keeps only label-shaped lines outside the fields the walk met.
  - On a hidden Chrome page, it keeps only lines in the empty web area.
  - It runs when the window lists nothing, when Chrome hides its page, or when `text` is set.
  - Without Screen Recording the reply says so. The picture is never kept, returned or sent.
- **The reply** is text, not JSON:
  - a line with the app's name, the window's title and its frame;
  - one line per control: its id, `ScreenElement.description` and its frame;
  - one line per recognised line: its id, its words and its box;
  - a note when the cap was reached or the text step was skipped, and why.
- **Frames and points** are Accessibility's: points, with the origin at the top left of the main display, the space `point` and `click` take.

**Ids**
- Each pane keeps the targets of its last `look`, each a `ScreenTarget` (an element reference, or a recognised box with its window and the window's frame then).
- The table is replaced at the pane's next `look`, dropped when the pane closes, and held in memory only.
- An id the table lacks is answered "look first".

**`point`**
- **`id`:** the frame is read again (`ScreenReader.currentFrame`), so a control that moved is followed. A gone one is answered "gone: look again", and recognised text follows its window as Hey Launchy's does.
- **`rect`:** used as given.
- **The sign:** the session's name, as its board card names it and cut to 30 characters, then the note, cut to 120.
- **Showing it:** it is drawn with `ArrowOverlay.shared.show` and hidden after `ArrowOverlay.lingers`.
- **One Arrow at a time.** A later `point`, a `click` or a spoken request replaces it, and Hey Launchy's own hiding (a new request, a cancel, its switch off) removes it too.

**`click`**
- **`id`:** the frame is read again, and a gone control is refused.
  - If the element lists Accessibility's press action, it is pressed.
  - Otherwise it gets a left click at its frame's centre, and recognised text gets a click at its box's centre.
- **`at`:** refused when it is on no display, or when the element there (a system-wide Accessibility hit test) belongs to Launchy's own process. The check runs before the Arrow is drawn, since the Arrow's panel is Launchy's own.
- **The order:**
  1. the Arrow, with the session's name and what it is about to click;
  2. 1 s (`clickLead`);
  3. the press or click;
  4. the Arrow stays 2 s more, then fades.
- **The click itself:** a left mouse-down and mouse-up posted at the HID level, after `CGPreflightPostEventAccess`. The pointer moves to the point and stays there.
- **A press that blocks:** the press has its own messaging timeout of 1 s, longer than the walk's 0.25 s, since a press that opens a dialog can block. A timeout is answered "sent; look to see what happened".
- **One click at a time, across all sessions.** A second waits for the first to finish.
- **The reply** says what was done ("pressed e4", "clicked at 812, 340"), never that it worked. The session looks again to see.

**Refusals, for every call, each with a sentence the session can act on**
- the switch is off: "Screen access is off in Launchy's Settings › Claude";
- Accessibility isn't granted: ask the user to grant it in Launchy's Settings;
- Launchy is still starting;
- no Claude pane on this Mac has the pane id;
- the pane shows a card because another Mac or a device is in control;
- the target is in Launchy's own process (`ScreenReader.isLaunchy` for an id, the hit test for a point);
- the screen request's version differs.

**The log**
- One `NSLog` line per call: the tool, the outcome's kind, durations and counts.
- Never a label, note, window title, app name or session name, as for spoken requests.

**Docs the builder updates with the code**
- SECURITY.md and the README: what a session is shown goes to Anthropic, clicks happen without approval, and the Arrow shows first.
- `docs/agents/where-it-breaks.md`:
  - a screen request has no `op`, and the relay never forwards a line without a known one;
  - `--mcp` never reads or acts;
  - `--mcp-config` sits before `--settings`;
  - a point click's own-process check runs before the Arrow is drawn.
- `CONTEXT.md`: **Screen access** (below).
- The ADR (below).
- ADR 0019's and CONTEXT's "nothing is opened, clicked or focused" stays true of spoken requests.

**State**
- One UserDefaults key, `screenAccess`.
- No change to `sessions.json`.
- No MCP config file.
- The id tables live in memory only.

## Testing Decisions

- **No test target yet.** Verification is `make build`, then hand checks after the user restarts Launchy. The user runs the checks that point or click, or a builder runs them only with the user's go-ahead: agents don't drive the user's screen.
- **`Launchy --mcp` on its own, with stdin from a file:**
  - `initialize` then `tools/list` lists `look`, `point` and `click` with their schemas, and the process exits at the end of its input;
  - with Launchy quit, a `tools/call` answers "Launchy isn't running";
  - with the switch off, it answers the switch's refusal.
- **The relay:**
  - `Launchy --peer` with a line holding `screen` and no `op` answers "Unknown request";
  - a line with `op: projects` and a `screen` key is answered as `projects`. Reading the dispatch is enough for this one.
- **In a session restarted with the switch on:**
  - `/mcp` lists `launchy` with three tools;
  - `look` with System Settings behind the panel lists its controls with ids, and no field's typed value;
  - `look` on a Chrome page lists the page's text lines with Screen Recording granted, and says it lacks it without;
  - `point` at an id and at a rect draws the Arrow, signed with the session's name, gone after 8 s;
  - `click` on a harmless control, such as a sidebar item in System Settings, shows the Arrow for about a second, then selects it;
  - `click` at a point on Launchy's panel is refused, and nothing is clicked;
  - turning the switch off makes the next call fail with no restart;
  - Launchy's log holds kinds and durations only.
- **Seams for a test target later:**
  - the JSON-RPC framing;
  - the id table;
  - the refusal rules;
  - the reply's text.

## Out of Scope

- **`type`,** named keys and shortcuts; drag and scroll.
- **A picture in `look`,** an image the model sees.
- **`point` by description, resolved by Jev (`ScreenPicker`),** as Hey Launchy does. Later, because it isn't cheap:
  - it needs the TypeSafe gate, so it wouldn't work On this Mac;
  - it would send a session's words to TypeSafe, a new kind of data needing ADR 0019, the README and SECURITY.md amended;
  - Jev's wording was measured on requests said aloud, not on a session's descriptions;
  - the pick lives inside the spoken pipeline's run;
  - a session already picks from `look`'s list, at the cost of one more call.
- **Permissioning** (deferred, Further Notes): a per-pane switch, approval before a click, a deny list of apps, an indicator while a session looks, a per-pane record, and checking the caller's process ancestry.
- **Reading Launchy's own panel.**
- **Agents other than Claude Code** (option 04).
- **A session on another Mac acting on this Mac's screen.**

## Further Notes

- **Accepted by the user on 2026-10-09,** relayed by the coordinator, with a narrower scope:
  - option 01's broker over MCP, with point and click now;
  - one implementation on Launchy's socket;
  - permissioning later.

  First written with four tools (`type` too), a per-pane switch, approval in Launchy's panel (once or for 10 minutes), a deny list, an indicator, a per-pane `screen-log` and a check of the caller's ancestry. The whole option waited on `panes-share-launchys-permissions`, and git has that version. Those parts come back with permissioning.
- **Permissioning, the planned follow-up.**
  - A process started with `posix_spawn` and the private `responsibility_spawnattrs_setdisclaim` is no longer attributed to Launchy. This was measured from a pane on 2026-10-09; `panes-share-launchys-permissions` option 01 has the figures and the plan.
  - Once panes start that way, Launchy's tools are the only way a session reaches the screen, and approval, the per-pane switch and the record become real gates.
  - At that point Launchy's command-line modes that read or act (`--ask --app` and its `--draw`) must not do so for a caller. A disclaimed process running Launchy's own binary is very likely still checked as Launchy. Inferred.
- **Decided while planning:**
  - **The switch is kept.** It is the user's consent to what goes to Anthropic, and it keeps the tools out of every session's context and process list until wanted. Read at every call, it is also the one stop that works on running sessions while there is no approval. It costs one key and one row.
  - **Description pointing waits** (Out of Scope).
  - **The 1 s lead before a click.** It is long enough to see the Arrow fade in (0.2 s) and read the sign, and short enough not to slow a setup.
  - **Ids carry their kind** (`e` for a tree element, `t` for recognised text), so a session knows which ones came from a picture.
  - **Replies are text,** shorter in the session's context than JSON.
- **ADR, on acceptance, not yet written** (the planner writes only problems):
  - Sessions reach the screen through Launchy: `Launchy --mcp` relays look, point and click over the user-only socket, and the running Launchy reads and acts under its own grants with Hey Launchy's code.
  - The relay has no path that reads or acts.
  - Permissioning is deferred while pane processes still get Launchy's grants (ADR 0019's correction).
  - It amends ADR 0019 and 0021: Launchy now reads, points and clicks for sessions too, not only for spoken requests.
- **Glossary, proposed:** **Screen access**: the setting that gives Claude sessions in Launchy's panes Launchy's look, point and click tools. _Avoid_: computer use, remote control.
- **Verified in the code at 9f24a4e:**
  - The relay's dispatch and the app handler's first read, as "The socket request" states them.
  - `focusedApplication` and `application(named:)` both skip Launchy's own process.
  - `ArrowOverlay` is one shared panel that ignores the mouse and is shown without activating anything.
  - Hey Launchy's text step is a closure inside `lookAtScreen`.
  - Every Claude pane's environment carries `LAUNCHY_PANE_ID`.
  - `make run`'s kill pattern matches only the bare binary path with no arguments.
  - Nothing in Launchy posts events or performs an Accessibility action today.
  - Claude Code 2.1.296 takes `--mcp-config <configs...>` as files or JSON strings.
- **Inferred:**
  - Claude Code asks before an MCP tool call unless it is allowed.
  - A press through Accessibility usually leaves focus alone.
  - Accessibility's coordinates are the global space CGEvent posts in.
- **Unverified, for the builder to check first:**
  - that Claude Code trusts a server from `--mcp-config` without asking;
  - which MCP protocol version it asks for in `initialize`;
  - that a system-wide hit test at a point skips the Arrow's panel, which is why the check runs before the Arrow;
  - that posting a click needs nothing beyond Accessibility under the hardened runtime (ADR 0022 adds an entitlement only for a failure a check showed);
  - how the pane's card state follows a takeover.
