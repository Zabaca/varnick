---
problem: sessions-cant-read-or-drive-varnick
title: Panel access, Varnick's own tools on the `varnick` server, that read and act through each view's model
summary: A new switch beside Screen access, Panel access, is in Settings › Claude and off by default. Claude sessions started while it is on get tools for Varnick itself, on the same `varnick` MCP server. `panel` says what the panel shows and where the focus and the caret are. `show` opens a view or runs a `!` Command, never `!listen`, without bringing the panel up. Each view that adopts a small protocol gets a `<view>_read` tool, and a `<view>_act` tool if it has actions, both listed from one registry. The Outline reads its tree, or the rows as the user sees them. It adds, rewrites, notes, completes, deletes, moves, indents, collapses and mirrors bullets through its own edits and undo stack, never in the bullet that has the caret, and never moving the caret. The Session board reads its cards. Nothing goes through Accessibility, no event is posted, and no grant is needed. The Outline's part waits for the Outline to merge.
status: proposed
---

## Solution

**Panel access** is a switch in Settings › Claude, under Screen access, off by default. A Claude pane started or restarted while it is on runs the same `Varnick --mcp` server as Screen access, and the server lists Panel access's tools. With both switches on, it lists both sets. Each call is one line on the user-only socket, and the running Varnick answers on the main actor from its own model. Nothing is read through Accessibility, no event is posted, and neither Accessibility nor Screen Recording is needed.

| Tool | Arguments | What it does |
|---|---|---|
| `panel` | none | Says whether the panel is visible, key and pinned, and what it shows: search (its mode, never its text), a tab (its panes and the focused one), the board, the Outline or Settings. Says where the keyboard focus and the Outline's caret are. |
| `show` | `view`, `command` or `pane` | Shows the search, the board, the Problems tab, the Outline or a pane's tab. Or runs a `!` Command as ↩ on its row would. It changes what the panel shows, never whether it shows. |
| `outline_read` | `at`, `depth`, `as_shown` | The Outline's bullets as indented lines with ids, from Home or from a bullet. With `as_shown`, the rows exactly as the user sees them, with the zoom, the filter and the caret. |
| `outline_act` | `action`, then its arguments | One edit, through the Outline's own edits and undo stack: `add`, `set_text`, `set_note`, `complete`, `delete`, `move`, `indent`, `outdent`, `collapse` or `mirror`. |
| `board_read` | `tab` | The Session board's cards by column, as the board shows them, or the Problems tab's. |

`panel` and `show` belong to the panel. The other three come from the first two views that adopt the protocol. A view added later gets its own `<view>_read`, and `<view>_act` if it has actions, without a change to the relay.

## Trade-offs

- **It speaks Varnick's model, not pixels.**
  - A session reads what the model holds, with ids. Text that a picture or the Accessibility tree couldn't give comes through: a bullet's text sits in a text view, and `look` never reads a field's value.
  - Actions run the same functions the keys call, so a fix to one is a fix to both.
  - The cost: a hand test through these tools checks the model, not the key path. Key handling, caret movement and focus are option 02's. How it looks is still a screen picture's job (Screen access, option 08).
- **No grant, and nothing to race on the screen.** Nothing is posted and nothing comes to the front. Edits to the Outline land in the tree, and the user sees them in the rows. The one race is with the user's typing in the Outline, handled below.
- **The exclusion from the screen tools stays.** It now has its reason written down (the problem's Today). Panel access doesn't let the screen tools into the panel, and it gives nothing in Settings, so the controls that govern sessions stay out of the tools.
- **What a session reads goes to Anthropic** with its context, and stays in its transcript on this Mac:
  - the panel's state;
  - for other sessions, what a board card shows of them;
  - the Outline's bullets, which until now were "kept in a file on this Mac and nowhere else".

  The switch is the user's consent, and its detail says this. Nothing on this path goes to TypeSafe.
- **Edits happen without asking,** as screen actions do. Claude Code's per-tool rules can allow the `_read` tools and ask before `outline_act` (inferred, as for `click`). Every edit is on the user's undo stack.
- **One server, one more switch.** One server and one relay mean one protocol subset and one line on the command line. A switch of its own costs one key and one row, and lets the user give sessions the Outline without giving them the screen (Further Notes, question 1).
- **A session gains the tools at its start,** as with Screen access: Claude Code reads `--mcp-config` at launch, so a session gets the tools at its next start or with Restart.

## User Stories

1. As a Varnick user, I want to turn Panel access on once, so that the sessions I start or restart can see what Varnick's panel shows.
2. As a Varnick user, I want a session to read and edit my Outline as a working document while I keep typing in another bullet, without its edits moving my caret or being lost under my typing.
3. As a Varnick user, I want ⌘Z to undo a session's edit to my Outline as it undoes mine.
4. As a Varnick user, I want a session to open the board or the Outline for me, without its bringing the panel up while I'm in another app.
5. As a Varnick user, I want a session to see my other sessions as the board shows them (title, project, turn, work link), and nothing of what they contain.
6. As someone adding a view to Varnick, I want sessions to get tools for it by adopting one protocol, not by changing the MCP server.
7. As a Varnick user, I want turning Panel access off to stop every session's Varnick tools at once.

## Implementation Decisions

**The switch**
- **Where:** Settings › Claude, under Screen access. Its UserDefaults key is `panelAccess`, a bool, off when missing.
- **Its detail** says:
  - that sessions started or restarted while it is on can read what the panel shows, the board's cards and the Outline;
  - that they can change the Outline without asking, and that ⌘Z undoes their edits too;
  - that what they read goes to Anthropic with the session.
- **Read at every call,** so turning it off stops running sessions at once.
- **What it is independent of:** Screen access, Accessibility and Screen Recording. No grant row.

**The server**
- **The same mode, `Varnick --mcp --pane <id>`,** with an argument for each set it lists: the screen tools, Panel access's tools, or both.
  - `ClaudeSession.launchClaude` passes `--mcp-config` when either switch is on at the start. `ScreenMCP.configuration` takes the two switches.
  - With no set named, the server lists the screen tools, as an older launch does, so a session started before the build keeps what it had.
- **The tool list.** Screen's fixed list, then `panel` and `show`, then each registered view's tools, built from its static specs. These are nonisolated constants, as the server already reads from `ScreenAccess`. The server still never reads or acts.
- **Names.** No new tool name clashes with a screen tool's.

**The socket request**
- **Its own key, `panel`,** with its own version and no `op`. `PeerManager.handle` tells it apart beside the screen request and before any peer check.
- **The relay is unchanged:** it refuses any line without a known `op`, so no paired Mac or device can send one. `PeerProtocol.version` and the screen request's version are unchanged.
- **Answered on the main actor** by `PanelAccess`, a new type and sibling of `ScreenAccess`. In order:
  1. the request's version;
  2. the switch;
  3. Varnick still starting;
  4. the pane, which must be a Claude pane on this Mac and not controlled from elsewhere (the rule `ScreenAccess` uses, shared rather than copied);
  5. then the tool.

  It never checks Accessibility.

**The protocol each view adopts (`PanelAccessView`)**
- **A name,** which names its tools (`outline`, `board`).
- **Static specs:** its read arguments, and its actions with their arguments and a line each. The relay lists the tools from these.
- **A read:** the view's state as text, with ids from the pane's table.
- **A perform:** one action by name, through the same model functions the view's keys call. It returns what was done, or a refusal.
- **Everything else is the router's (`PanelAccess`):** the switch, the pane, the id tables, refusals, the log and the reply. An adopter is a thin layer over its view's model.
- **One registry** lists the adopters. A view joins by adopting the protocol and being added there.
- **Settings never adopts:** its switches govern sessions.

**Ids**
- **Short, typed by kind,** like `look`'s: `o` for an Outline row and `s` for a pane, whether it comes from `panel` or a board card.
- **Kept for the pane's life:** the same row or pane gets the same id at every read, and a new one gets the next number. They are held in memory, and dropped once the pane has gone.
  - `look` replaces its ids at each look, because an Accessibility element doesn't outlive a change. A row's path and a pane's id do.
- **A gone id** is answered "gone: read again".

**`panel`**
- **The panel:** visible or hidden, key or not, pinned or not.
- **What shows:**
  - search, with its mode (the session list, a prompt, `?` search, `!` commands) and whether the field is empty, never its text, as `look` never gives a field's value;
  - a tab, with its name and its panes by kind and title, which pane has focus, and "this session" on the caller's own pane;
  - the board, with its tab and the selected card;
  - the Outline, with the zoom's crumbs, the filter's words and the caret (its row, text or note, and its offset);
  - Settings, the Restart Varnick card or the split picker.
- **Focus:** which of those has the keyboard.

**`show`**
- **`view`:** search, board, problems or outline. **`pane`:** an `s` id, which shows that pane's tab, focused (`showPane`).
- **`command`:** a Command's name, run as ↩ on its row would run it. One function does it, and `runCommand` calls that function too.
  - `listen` is refused: it turns on the microphone.
  - `problems` works only while the Problems board switch is on, as `!problems` does.
- **Through the model's own functions** (`showBoard`, `showOutline`, `activate`, `showSearch`), so the panel's height, focus and "never the board and the Outline together" follow their own rules.
- **Never shows, hides, pins or activates the panel.** When the panel is hidden, the view is there the next time the user opens it, and the reply says so.
- **Refused:**
  - within 2 s of a key the user pressed in the panel, since the user is typing there;
  - while Settings, the Restart Varnick card or the split picker shows.

**The Outline: reading** (needs the Outline merged)
- **The default:** the tree from Home, or from `at`, to `depth` (3 by default, 0 for all). The user's zoom and filter don't apply.
  - One line per bullet, indented by depth: its id and text, `[done]` when completed, and whether the user's view hides it (Show completed off).
  - `(collapsed)` on a bullet that is, with a count of what is nested in it past the depth.
  - `(mirror, N places)` on a bullet with more than one placement.
  - The note's lines under the bullet.
- **`as_shown`:** the rows exactly as the user sees them, for a hand test.
  - The zoom's crumbs, the filter's words and Show completed come first.
  - Each row is described as above.
  - The caret: its row, text or note, and its offset in the text view's own count (UTF-16).
- **A cap of 400 rows,** then "N more: read at o12".
- **The file.** The first call in a launch reads the file, as showing the Outline would, off the main actor, without showing it or moving focus. If the file is unreadable or newer, every Outline call is refused with the Outline's own words, and the file is never written (ADR 0030).

**The Outline: acting** (needs the Outline merged)
- **Every action is one undo step, through `Outline.apply`.**
- **`add`:**
  - `text`: one line, or several. Two leading spaces or a tab nest a line under the one above, and a leading "- " is dropped.
  - `under`: an id, or Home when it is left out.
  - Where: `after` an id, or `first`; last by default.
  - It is one new tree edit, `insert`, and the only change to `OutlineTree`'s rules. A bullet it adds is new, so it can't end up inside itself.
  - The reply gives the new rows' ids.
- **The keys' own edits:**
  - `set_text`: one line;
  - `set_note`: empty removes the note;
  - `complete`, with `done` true or false. The edit toggles, so it runs only when the state differs;
  - `delete`: this placement and everything nested under it, as ⌘⇧⌫;
  - `move`, by -1 or 1;
  - `indent` and `outdent`;
  - `collapse`, true or false;
  - `mirror`: `id`'s bullet placed after `after`.

  Being the keys' edits, the tree's refusals hold: inside itself, first or last, nothing nested.
- **Indent and move use the user's Show completed and no filter:** they step over hidden completed bullets as the keys do.
- **Not in the user's way:**
  - **Refused: anything in the bullet that has the caret.** That is `set_text`, `set_note` and `complete` on any placement of it, since a mirror shares its text. The view with the caret keeps its own text, and the user's next key would write over the change.
  - **Refused: anything that moves or removes the caret's row, or a row it is nested under.** That is `delete`, `move`, `indent` and `outdent` of either, and `collapse` of an ancestor.
  - **Refused: every edit while the caret is on its way to a row,** with keys queued.
  - The words for all three: "The user is typing there: try again when the caret has moved on".
  - **An agent's edit never moves the caret,** scrolls, opens a note or keeps its bullet in view under the filter. `apply` takes whether to follow the edit's caret: the keys' calls do, `outline_act` doesn't.
  - **It ends the user's typing run,** so it is a step of its own. The step keeps the user's caret, so ⌘Z puts the caret back where the user was.
- **Undo is one stack.** ⌘Z undoes the last edit, whoever made it, within the launch as now. Sessions get no undo action.

**The Session board: `board_read`**
- **The cards by column** (Running, Stopped, Completed). For each card:
  - its `s` id, title, project and host;
  - the turn and how long, and the background work's count;
  - its note ("Controlled on…");
  - its work link;
  - "this session" on the caller's own card.
- **`tab: problems`:** the Problems tab's cards (stage, title, project and the chips' `s` ids), only while that switch is on.
- **When the board isn't shown,** a read runs one `refresh`: a stat of each pane's turn file, on the main actor, as the board's tick does. It uses the paired Macs' cards as last fetched. It never starts the tick, a zmx check or an ask to a paired Mac.
- **No actions:** Done, Restart and End act on other sessions (Out of Scope). Opening a card is `show` with its id.

**Other sessions**
- A session reads what a board card shows of them, and the panel's tab list: titles, projects, turns, hosts and work links.
- It never reads their transcript, prompt, terminal screen or web page, or the search field's text.

**Refusals,** each with a sentence the session can act on:
- the switch is off;
- Varnick is still starting;
- no Claude pane on this Mac has the pane id, or another Mac or a device is in control of it;
- the request's version differs ("Restart this session…");
- `show`'s and the Outline's refusals above;
- the Outline file can't be read;
- an unknown, gone or wrong-kind id.

**The log**
- One `NSLog` line per call: the tool, the action, the outcome's kind, durations and counts.
- Never a bullet's text, a title, a name or a filter word (ADR 0030 says the same of bullets).

**Docs the builder updates with the code**
- `CONTEXT.md`: **Panel access** (Further Notes).
- An ADR, the next free number (0030 is the Outline's): sessions read and act on Varnick through its model, on the `varnick` server, with no grant. It amends ADR 0023: the screen tools' own-process rule stands, now with its reason. It amends ADR 0030: bullets go to Anthropic with a session that reads them, while the switch is on.
- `docs/privacy-and-security.md`, the README and the guide: what a session reads, and that its Outline edits happen without asking.
- `docs/agents/where-it-breaks.md`: a Panel access section (below).

**State**
- One UserDefaults key, `panelAccess`.
- No change to `sessions.json` or to `outline.json`'s shape.
- The id tables live in memory only.

**Where it breaks.** The items of `docs/agents/where-it-breaks.md` this touches:
- **Screen access:**
  - a request with no `op`, which the relay never forwards;
  - `--mcp` never reads or acts, and its standard output is the protocol;
  - `--mcp-config` goes first;
  - the switch is read at every call;
  - the screen tools' own-process refusals, which stay as they are.
- **Focus and keys:** a view changes only through `activate`, `showBoard`, `showOutline` and `showSearch`. The board and the Outline never show together. A tab under them is activated without focus.
- **Panel size:** `panelHeight` follows only through those functions.
- **The Outline:**
  - the view with the caret is never set;
  - every edit goes through `apply`;
  - a bullet inside itself is the tree's check alone;
  - the file is never written when unreadable or newer;
  - a bullet's text is never logged;
  - the rows are `refreshRows()`' alone.
- **Sessions and tabs, the board:**
  - the board's read stays a stat on the main actor;
  - the Problems tab stays behind its switch;
  - the paired Macs are asked only while the board shows.
- **Pointing at the screen:** nothing here reads Varnick through Accessibility. A later adopter that did would have to keep the read detached.

## Testing Decisions

- **No test target yet.** Verification is `make build`, then hand checks after the user restarts Varnick. A check that edits the user's real Outline runs only with the user's go-ahead, or on an outline they don't mind changing.
- **`Varnick --mcp` on its own, with standard input from a file:**
  - `tools/list` lists the screen tools alone with no set named, Panel access's alone, and both;
  - with Varnick quit, a call answers "Varnick isn't running".
- **`--outline-check`** runs `insert` on a copy: nesting from indented lines, the new ids, and an undo of it.
- **In a session restarted with Panel access on:**
  - `/mcp` lists the new tools;
  - `panel` is right on search, on a tab (with this session marked), on the board and on the Outline with its caret;
  - `show outline` with the panel hidden shows nothing until the user opens it, and then the Outline is there;
  - `show` within 2 s of typing in the panel is refused;
  - `show command: "listen"` is refused;
  - `outline_read` gives the tree, and `as_shown` matches the screen under a zoom and a filter;
  - `outline_act add` lands while the user types in another bullet, and the caret and its text are untouched;
  - an edit to the bullet with the caret, or to a mirror of it, is refused;
  - ⌘Z undoes the session's edit and puts the caret back where the user was;
  - `board_read` matches the board, with this session marked;
  - turning the switch off makes the next call fail with no restart;
  - Varnick's log holds kinds and counts only.
- **Seams for a test target later:** the `insert` edit, the protocol's adopters' read and perform against a model, the router's refusals, and the id tables.

## Out of Scope

- **Keys through the panel's own key path,** for hand-testing key handling (option 02).
- **Actions on other sessions** from the board: Done, Restart, End.
- **Search as a tool:** its results are browser history, bookmarks and sessions, which would go to Anthropic. It can adopt the protocol later.
- **Settings,** to read or to act on.
- **The contents of any pane:** a terminal's screen, a page or a file.
- **For sessions in the Outline:** undo, redo, zoom and filter; an absolute move to another parent, which would be a second tree edit asking `contains`; a session's own filter or zoom.
- **A command line on the same requests** (option 04).
- **Sessions on other Macs,** and permissioning, which stays deferred as for Screen access.

## Further Notes

**Open questions, with the planner's recommendation**
1. **One server with its own switch, or under Screen access's switch?** Recommended: the same `varnick` server, with its own switch. The tools need no grant and send other things to Anthropic, and a user who wants sessions in the Outline needn't give them the screen. The alternative saves a row and a key.
2. **What may a session read about other sessions?** Recommended: what a board card shows (title, project, turn, host, work link), and never a transcript, prompt, terminal screen or the search field's text.
3. **An edit to the bullet the user is typing in: refuse, or hold it until the caret leaves?** Recommended: refuse. A held edit lands later than the session believes, and needs a queue that survives the caret's moves.
4. **Build order.** Recommended: the router, `panel`, `show` and `board_read` on main now, and the Outline's adopter once the Outline merges.

**Considered, not proposed**
- **Sessions editing `outline.json` themselves.** ADR 0030 makes Varnick its one writer. A running Varnick saves over the file, and its undo stack would know nothing of the change.
- **A second MCP server for these tools.** It would be a second process per pane and a second entry on the command line, on the same socket.
- **Hand-listing each view's tools in the server, as the screen tools are.** Simple, but each new view would mean a change to the relay. The registry lists them from the views' own specs.

**Glossary, proposed:** **Panel access**: the setting (Settings › Claude, off by default) that gives the Claude **Session**s in Varnick's panes, started or restarted while it is on, tools for Varnick itself: what the panel shows, opening a view, the **Outline**'s bullets and the **Session board**'s cards. It works through Varnick's own model, with no permission. _Avoid_: Screen access (any app's window, through Accessibility), API, automation.

**Verified in the code**
- At d24ce5b:
  - the screen tools' exclusions and their history (the problem's Today);
  - the server's fixed tool list;
  - `ScreenAccess` checking the switch, then Accessibility, then the pane;
  - `PeerManager.handle` telling a request with no `op` apart;
  - `launchClaude` passing `--mcp-config` only with Screen access on;
  - the key monitor's order;
  - `LauncherCommand` and `runCommand`;
  - `showBoard`, `activate` and `showPane`;
  - `SessionBoard.Card`'s fields.
- At 596c761 (the Outline):
  - `Outline.apply` records, saves and moves the caret;
  - `updateNSView` skips the view with the caret, and `syncFromModel` runs when it resigns;
  - the file is read on the first show;
  - one undo stack with typing runs;
  - `OutlineEdit`'s cases;
  - a row is a path;
  - `showOutline` and `Outline.key` are wired into the model and the key monitor.

**Inferred**
- Claude Code's per-tool rules can allow the read tools while asking before `outline_act`.
- The board's `refresh` is cheap enough to run once for a read with the board hidden. It is the tick's own work.

**Unverified, for the builder to check first**
- That Claude Code shows a server's tools when the list changes between starts, with no prompt.
- How large `outline_read` is for a real outline at depth 3: the 400-row cap is a guess.
