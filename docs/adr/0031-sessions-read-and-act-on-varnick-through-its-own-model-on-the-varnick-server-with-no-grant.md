# Sessions read and act on Varnick through its own model, on the `varnick` server, with no grant

With **Panel access** on (Settings › Claude, under Screen access, off by default), a Claude session started or restarted in a Varnick pane has tools for Varnick itself, on the same `varnick` MCP server as the screen tools. `Varnick --mcp --pane <id>` takes an argument for each set it lists (`--screen`, `--panel`); with none named it lists the screen tools, so a session started before this build keeps what it had. The first tool is **`panel`**, which says what the panel shows and where the keyboard focus is. Later tools come from the views, each adopting one small protocol and listed from one registry (`PanelViews`), so a view added later gets `<view>_read`, and `<view>_act` if it has actions, with no change to the server or the socket request.

A session speaks to Varnick's **model**, not to pixels: the running Varnick answers on the main actor from its own state, with ids. **Nothing is read through Accessibility, no event is posted, and no macOS permission is needed.** The problem and its options are in `docs/problems/sessions-cant-read-or-drive-varnick/`; this records option 01.

## The request

- **Its own key.** One line on the user-only socket with a `panel` key holding the request's own version, the pane id, the tool and its arguments, and **no `op`**. `PeerManager.handle` tells it apart from a screen request (`screen` key) and from a peer's, before any peer check.
- **No peer can send one,** for the reason ADR 0023 gives: the peer relay refuses any line without a known `op`. `PeerProtocol.version` and the screen request's version are unchanged.
- **Answered by `PanelAccess` on the main actor.** In order: the version, the switch, Varnick starting, the pane, the tool. The pane must be a Claude pane on this Mac that no other Mac or device controls, the rule `ScreenAccess` uses, shared and not copied (`CallingPane`). It never checks Accessibility.
- **The switch is read at every call,** so turning it off stops running sessions at once, with no restart. A session gains the tools at its start, as with Screen access.
- **Ids.** A pane is `s1`, `s2`…, kept per calling pane for that pane's life, held in memory, dropped when the pane has gone or the switch is off.
- **The log** holds the tool, the outcome's kind, a count of lines and the duration. Never a title, a name or any text of a reply.

## `show` changes what the panel shows, never whether it shows

- **Through the model's own functions** (`showSearch`, `showBoard`, `showOutline`, `showPane`, and the one function that runs a `!` Command, which `runCommand` calls too), so the panel's height, the focus and "never the board and a tab together" follow their own rules. The same changes the keys make, with no key sent and no event posted.
- **It never shows, hides, pins or activates the panel.** With the panel hidden, the view is there the next time the user opens it, and the reply says so. A session must not bring Varnick up in front of an app the user is working in.
- **The Outline** is shown by `view: outline` and `command: outline` (or `wf`) through `showOutline(focusing:)`. The caret goes into a bullet only if the panel is key and Varnick is the active app, the rule `showSearch(focusing:)` follows; otherwise the Outline appears with no caret, and the file's arrival places none. It shows over the search, a board or a tab as the board does, and a hidden panel gets it for the next time like any view.
- **It takes no keyboard and clears nothing the user typed.** A pinned panel behind another app stays behind it, and a half-typed query survives. With the panel hidden, a tab is not swapped in or out (a pane's tab, `!transcript`, or any call while a terminal is on screen): that is not proven to leave every terminal's size alone.
- **`!listen` is refused:** it turns on the microphone. `!problems` works only while the Problems board switch is on, as the key does.
- **The user's own state wins.** It is refused while Settings, the Restart Varnick card or the split picker shows, and for two seconds after a key the user pressed in the panel (the key monitor stamps the time and returns what it did before). Settings is where the controls that govern sessions are, so a session can neither open it nor change it.

## What a session is shown goes to Anthropic

What a session reads goes to Anthropic with its context and stays in its transcript on this Mac:
- the panel's state, names and titles of tabs and panes included (`panel`);
- for other sessions, what their board card shows: title, folder, Mac, turn and how long, background work, the card's note and work link (`board_read`);
- **the text on the screen of any terminal pane, other sessions' and shells' included** (`pane_read`). The user chose this on 2026-10-11, beyond the card alone. A screen holds whatever is on it, a session's latest exchange or a shell's output, secrets included. A card's title can be a prompt's first line and a screen shows Claude's latest exchange; nothing beyond that is read: not the scrollback, not a transcript or a prompt that neither the card nor the screen shows, not a page's or a file's contents.

- **the Outline's bullets and notes** (`outline_read`, below), which ADR 0030 had as "on this Mac only".

Nothing on this path goes to TypeSafe. The search field's text is never read, only its mode. The switch is the user's consent, and its detail says so, as the README and `docs/privacy-and-security.md` do. Each later tool that reads more says so in the same places before it ships.

## `outline_read` reads the Outline's model, and amends ADR 0030

- **What it reads.** The tree from Home or from a bullet, `depth` levels down (3 by default, 0 for all), or with `as_shown` the rows as the user sees them (the zoom's crumbs, the filter's words, Show completed, each row's depth and path, the caret as a row, text or note and a UTF-16 offset, the selected bullets). It reads `Outline`'s model and the tree, never a text view, so the caret is the model's record of it.
- **Whether or not the Outline shows.** The first call in a launch reads `outline.json` as showing the Outline would, off the main actor, with no panel and no focus; a call that arrives while it loads waits for it. While the file is unreadable or from a newer Varnick every call is refused with the Outline's own reason, and the file is never written: reading calls nothing that saves.
- **Ids.** `o1`, `o2`…, per calling pane and in memory like `s` ids, one for each row path, so a row keeps its id from read to read; a path that has left the tree is "gone: read again". An edit that moves a row changes its path, so it gets a new id.
- **Bounded, and continued.** 400 rows a call, about 60,000 characters, a bullet's text cut at 500 characters, a note at 30 lines of 300, at most 10 tags of 40 characters (taken from the cut text, not the whole), and a "nested" count that stops at "1000+". A read that stops at the cap ends with the exact call that continues it, "N more: call outline_read with after: o12" (and the same `at` and `depth`, or `as_shown: true`): `after` takes a row id and continues the same walk from the row after it, for the tree read and for the rows as shown, so every row can be reached. The `as_shown` hint never points at the default read, which ignores the zoom and the filter. An `after` that is no row of the read (it left the tree, or the rows on screen changed) is "gone: read again".
- **`panel` and `show`** say the Outline's zoom, filter and caret; the log holds none of it (the tool, a kind, a count of lines).
- **It amends ADR 0030:** the Outline's bullets were "local only", kept in a file on this Mac and nowhere else. With Panel access on, a session that reads them sends them to Anthropic with its context, and they stay in its transcript on this Mac. The file itself, its format and the rule that it is never written over when unreadable are unchanged. Nothing reaches a paired Mac or TypeSafe, and a session's read puts nothing on the phone (amended 2026-10-20: the Phone page of that Mac asks for the Outline itself, as a listed device, [ADR 0046](0046-the-phone-page-shows-a-macs-outline-to-its-listed-devices-and-edits-it-through-the-apps-model.md)).

## `outline_act` edits the Outline without asking, and amends ADR 0030

- **The edits.** `add`, `set_text`, `set_note`, `complete`, `delete`, `move`, `indent`, `outdent`, `collapse` and `mirror`, through the tree's own edits and `Outline`'s one undo stack. `add` is `OutlineEdit.insert`, which a paste already used. A refused edit changes nothing and says why; the tree's own refusals, such as a bullet inside itself, hold.
- **Nothing asks.** With Panel access on, a session's edit lands in the user's Outline and is saved with it. Every edit is one undo step, so ⌘Z takes it back, and the user's typing run ends at it.
- **The user's caret.** An edit leaves the caret and the text view that has it alone, unless it moves or removes the caret's row: then the caret follows the row, or goes where the same key would put it, or to the nearest row still showing. **The bullet being typed in** takes a `set_text` or `set_note` on the field the caret is in as a key does, since the user's next key writes that view's text back into the tree: the change goes into the text view around the user's selection, as an undo step of its own, and waits while an input method is composing. The steps and the rule for a caret at the change are in `docs/agents/where-it-breaks.md` (the Outline's text-view rule). ⌘Z takes back the session's edit alone.
- **A stale edit is refused.** `set_text` and `set_note` replace the whole field, so they would delete what the user typed after the session's last read. The router remembers, per calling pane and row, the full text and note that `outline_read` listed (as hashes, kept even where the read cut them), and refuses an edit to a field it never read ("Read it first") or that differs now ("Changed since you read it: read again"), asked right before the edit, after the waits. It applies to every row, not only the caret's. A field the session set itself counts as read, and so do the rows its own `add` lists with their text; a moved, indented, outdented or mirrored row keeps what the session knew of the row it came from.
- **Indent, move and outdent** use Show completed, and neither the filter, the zoom nor collapsed bullets, because a session reads the tree whole and its ids name tree rows.
- **It amends ADR 0030:** the Outline was edited by its own keys alone. With Panel access on, a session also edits it, without asking. The file, its format and the rule that it is never written over when unreadable are unchanged. The log holds the tool and the action, never a bullet's text. Amended 2026-10-20: a listed device's Phone page also edits it, through the same edit and the same undo stack, without asking ([ADR 0046](0046-the-phone-page-shows-a-macs-outline-to-its-listed-devices-and-edits-it-through-the-apps-model.md)).

## `keys` presses keys into the panel's own key path

Option 02, built after option 01 by the user's order. It decides how Varnick may send events to itself.

- **In-process, to the panel's window.** Each character of `text` and each combo is made as a key-down and key-up for the panel's window and handed to `NSApp.sendEvent` on the main actor. That runs the panel's key monitor, the view's handler and the first responder as a user's key does. No `CGEvent` is made, so nothing reaches another app and no permission is involved. `sendEvent`, not `postEvent`, so the gate and the event are one synchronous turn.
- **Gated before every event.** The switch and the pane, the panel visible and key with Varnick active, no key of the user's in the last 2 s, and the view on screen. The first failure stops the call and the reply says how far it got. It never brings the panel up. The user's keys and ours are told apart by a stamp on ours (where-it-breaks, Panel access).
- **Views say what they refuse.** `PanelKeyView`, which `PanelAccessView` refines, has one member, the reason a view refuses a key now, nil to take it; a view without it takes none. Tabs, Settings and the overlays take none. The search, the board and the Outline answer, and some keys are refused in every view: those that end, restart or mark a session, start one, turn on the microphone, quit or paste. The lists, and why each is there, are in where-it-breaks, Panel access.
- **One action at a time** on `ScreenAccess`'s queue, so a screen `type` and `keys` never interleave. The limits are `type`'s. The log holds the tool, the kind and counts, never the keys.

## It amends ADR 0023

ADR 0023 says "Never Varnick's own window" and gives no reason. The reason, found in the history of the option (the problem's Today):

- It was recorded when each click and type was to be approved in a prompt in Varnick's own panel. A session that could click the panel could approve its own actions, and Settings, in the same panel, holds the Screen access switch (the one stop for running sessions), Skip permissions and the Grant buttons.
- The reason was lost when approval was deferred with all permissioning, and the refusal stayed.
- `type`'s and `look`'s rules share the root: while the user talks to a session the panel is usually key, so keys meant for the app behind would land in a pane of the panel.

**The screen tools' own-process rule stands, with that reason.** Panel access does not let the screen tools into the panel, and it gives nothing in Settings: Settings never adopts the protocol, so the controls that govern sessions stay out of the tools. Today the rule is not a boundary, since every pane process has Varnick's grants; it keeps the tools Varnick offers off Varnick's controls until permissioning makes them the only way in.

## Considered Options

- **Send keys through the panel's own key path (option 02).** Built: `keys`, above. It tests key handling and focus, which the other tools do not.
- **Let the screen tools into the panel (option 03).** Rejected: it would put Settings within the tools' reach and needs Accessibility.
- **A command line on the same requests (option 04).** Kept for later.
- **A second MCP server for these tools.** Rejected: a second process per pane and a second entry on the command line, on the same socket.
- **Hand-listing each view's tools in the server, as the screen tools are.** Rejected: each new view would mean a change to the relay. The registry lists them from the views' own static specs.
- **Sharing Screen access's switch.** Rejected by the user: a switch of its own costs one key and one row, and lets the user give sessions Varnick without giving them the screen.

## Consequences

- **One more switch, one more server argument.** A session started with only Panel access on lists `panel` and nothing of the screen tools; with both on, both sets.
- **A hand test through `show`, `outline_act` and the reads checks the model; `keys` checks the key path.** How it looks is still a screen picture's job.
- **Adding a view's tools is adopting `PanelAccessView` and one line in the registry.** The router keeps the switch, the pane, the ids, the refusals, the log and the reply.
- **The Outline's reading and its edits have shipped** (`outline_read` and `outline_act`, above). An edit that lands in the bullet being typed in goes into that text view as a key does (above).

## Amendment: sessions now change a tab's layout (2026-10-17)

Panel access began as read and show: nothing a session called added or closed a pane, and `keys` refused starting one. `pane_open` and `pane_close` (option 01 of `panes-open-only-by-hand-at-a-mac`) are the first tools that change a tab's layout, so they have a switch of their own, **Sessions can open panes** (Settings › Claude, under Panel access, off by default, and needing Panel access on), and a set of their own, `--panes`, listed to a session started or restarted while both are on.

- **What they do.** A session opens a terminal, a Claude session with a first message, a custom app, a page or a file beside its own pane, in its own tab on this Mac, and closes the panes it opened until the user first focuses one. Focus stays where it was, the panel is never raised, and nothing limits how many panes are opened (the user's choices).
- **Same route, no new request.** The calls are Panel access's request with new tool names, answered by its router after its own checks and then the switch of their own, the tab's lock and the hidden tab. Both switches are read at every call.
- **Permissions.** A new Claude pane never skips permission checks when the calling session does not (the rule is in the guide, Panel access). What the tools do not promise, among them that `kind: app` runs a custom app's code outside Claude Code's checks, is in where-it-breaks, Panel access.
- **This Mac's own tabs only.** A tab another Mac or a device controls, a headless host, and the voice session's hidden tab are refused.
- **Privacy.** The tools read nothing that Panel access does not already; the log holds the tool, the kind, the outcome and the time.

## Amendment: the switches are gone (2026-10-17)

At the user's word ("this doesn't need to be a toggle"), **Panel access** and **Sessions can open panes** are no longer settings. This is the one statement of which sessions get which sets (`ClaudeSession.launchClaude` is its code; everything else points here):

- **Every Claude session in a Varnick pane** gets the `--panel` set and the `--panes` set, with `notify`, as `notify` always was.
- **A run of an automation** lists `notify` alone. **A Task step** lists `notify` and, while its folder holds the step's schema, `task_result`.
- **The voice session** gets Panel access's tools but not `pane_open` and `pane_close` (still an open question in option 01 of `panes-open-only-by-hand-at-a-mac`).
- **A headless host's session** lists `notify` alone.
- **Screen access is the one switch left.** It needs a macOS permission and reads the screen, and the user did not name it.
- **A session gains the sets at its start,** so a running session keeps its tools until it restarts.

Where this contradicts the text above (the switch read at every call, the Outline and pane decisions "with the switch on", the `--panes` condition, "one more switch") the amendment wins.

- **What a call is checked against** is unchanged minus the switch: Varnick starting, the pane (a Claude pane on this Mac that nobody else controls), then the tool. The pane tools add the tab's lock and the hidden tab. The refusals inside the tools stand: the 2-second key rule, closing only the panes a session opened, the Problems board and Outline switches in Settings › Experimental.
- **The stored defaults keys** `panelAccess` and `sessionsOpenPanes` are removed at launch, as `voiceSessionOn` was.
- **Privacy.** A session you start can now read every terminal screen and the board, and change your tabs, with no setting to refuse it; docs/privacy-and-security.md says so once.

## Amendment: a tab another machine controls (2026-10-17)

Two rules above no longer refuse a tab of this Mac that the phone or another Mac controls: "The pane must be a Claude pane on this Mac that no other Mac or device controls" (Answered by `PanelAccess`) and "This Mac's own tabs only" (the first amendment), as the second amendment restates them under "What a call is checked against" (option 04 of `panes-open-only-by-hand-at-a-mac`; the layout rule is [ADR 0034](0034-a-tab-lives-on-one-host-which-keeps-its-layout-panes-and-mark-and-other-devices-view-or-take-over-the-tab-whole.md)'s amendment). A headless host and a session in another machine's tab are as before.

Which tools get past the rule, and how the call is checked, is in docs/agents/where-it-breaks.md, Panel access (`PanelAccess.answersControlled`): the pane tools, and at the user's word the reads that only describe. What sends a key or shows a view, and the screen tools, keep the rule.

## Amendment: sessions search sessions, History and bookmarks, read sessions and open what they find (2026-10-20)

At the user's word (option 01 of `sessions-cant-search-sessions`), Panel access gains three tools: `find`, `session_read` and `find_open`. They reverse one line above, "not a transcript or a prompt that neither the card nor the screen shows", for these tools and no others.

- **Which sessions get them.** The `--panel` set lists them after `panel`, `show` and `keys`, so the rule in the amendment of 2026-10-17 (every Claude session in a Varnick pane, the voice session included, and not a run, a Task step or a headless host's session) covers them with no change. A session gains them at its start.
- **What reaches Anthropic.** What `find` answers goes to Anthropic with the calling session and stays in its transcript on this Mac: other sessions' names, folders, Macs, tab names and excerpts of the user's prompts and of Claude's replies; and for pages and bookmarks, up to 40 a call with their addresses, titles, sites, last visits, descriptions and the search terms that led to them. `session_read` sends whole prompts and Claude's whole text, never tool calls, tool output or thinking. The user accepted both on 2026-10-20, browsing history included. Chrome profile names and bookmark folders are not sent. Nothing goes to TypeSafe: pages are ranked by words and meaning on this Mac and never judged for relevance.
- **Same route.** The calls are Panel access's request with new tool names, so the request version stays and no peer protocol changes. `find` and `session_read` only describe, so they are answered in a tab another machine controls (`PanelAccess.answersControlled`); `find_open` keeps that refusal and `show`'s others.
- **`find_open` acts.** It does what Return does on the row, through the same function: it can start Claude on the user's plan and bring a tab up, and it opens a page in the user's default browser with their cookies, behind the app in front. With `place` it opens the result beside the calling pane as `pane_open` places a pane. It never ends, marks or types into a session.
- **Log.** The tool, the outcome's kind, counts and the time, never a word of a query, a name, an address or a conversation id.

What the tools promise and what they do not is in docs/agents/where-it-breaks.md, Panel access; what leaves the Mac is in docs/privacy-and-security.md.
