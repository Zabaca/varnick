---
problem: sessions-cant-read-or-drive-varnick
title: Panel access, Varnick's own tools on the `varnick` server, that read and act through each view's model
summary: Accepted on 2026-10-11 (the user's decision, relayed by the coordinator). A new switch beside Screen access, Panel access, is in Settings › Claude and off by default. Claude sessions started while it is on get tools for Varnick itself, on the same `varnick` MCP server. `panel` says what the panel shows and where the focus and the caret are. `show` opens a view or runs a `!` Command, never `!listen`, without bringing the panel up. Each view that adopts a small protocol gets a `<view>_read` tool, and a `<view>_act` tool if it has actions, both listed from one registry. The Session board reads its cards, and `pane_read` gives any pane's terminal screen as text. The Outline reads its tree, or the rows as the user sees them. It edits bullets through its own edits and undo stack, including the bullet the user is typing in: that change goes into the text view as a key would, around the user's caret. Nothing goes through Accessibility, no event is posted, and no grant is needed. The Outline's parts wait for the Outline to merge.
status: accepted
---

## Solution

**Panel access** is a switch in Settings › Claude, under Screen access, off by default. A Claude pane started or restarted while it is on runs the same `Varnick --mcp` server as Screen access, and the server lists Panel access's tools. With both switches on, it lists both sets. Each call is one line on the user-only socket, and the running Varnick answers on the main actor from its own model. Nothing is read through Accessibility, no event is posted, and neither Accessibility nor Screen Recording is needed.

| Tool | Arguments | What it does |
|---|---|---|
| `panel` | none | Says whether the panel is visible, key and pinned, and what it shows: search (its mode, never its text), a tab (its panes and the focused one), the board, the Outline or Settings. Says where the keyboard focus and the Outline's caret are. |
| `show` | `view`, `command` or `pane` | Shows the search, the board, the Problems tab, the Outline or a pane's tab. Or runs a `!` Command as ↩ on its row would. It changes what the panel shows, never whether it shows. |
| `board_read` | `tab` | The Session board's cards by column, as the board shows them, or the Problems tab's. |
| `pane_read` | `id` | A pane's kind and title, and for a terminal the text its screen shows now. |
| `outline_read` | `at`, `depth`, `as_shown`, `after` | The Outline's bullets as indented lines with ids, from Home or from a bullet. With `as_shown`, the rows exactly as the user sees them, with the zoom, the filter and the caret. With `after`, the read that a capped one names continues from the row after that id. |
| `outline_act` | `action`, then its arguments | One edit, through the Outline's own edits and undo stack: `add`, `set_text`, `set_note`, `complete`, `delete`, `move`, `indent`, `outdent`, `collapse` or `mirror`. |

`panel` and `show` belong to the panel. The other four come from the first three views that adopt the protocol: the board, the panes and the Outline. A view added later gets its own `<view>_read`, and `<view>_act` if it has actions, without a change to the relay.

## Trade-offs

- **It speaks Varnick's model, not pixels.**
  - A session reads what the model holds, with ids. Text that a picture or the Accessibility tree couldn't give comes through: a bullet's text sits in a text view, `look` never reads a field's value, and a terminal exposes no Accessibility text.
  - Actions run the same functions the keys call, so a fix to one is a fix to both.
  - The cost: a hand test through these tools checks the model, not the key path. Key handling, caret movement and focus are option 02's. How it looks is still a screen picture's job (Screen access, option 08).
- **No grant, and nothing to race on the screen.** Nothing is posted and nothing comes to the front. Edits to the Outline land in the tree, and the user sees them in the rows.
- **An edit can land in the bullet the user is typing in,** by the user's choice. It goes through the text view the way a key does, so the user's typing and the session's edit share one text and one undo stack and neither is lost. The caret stays at the user's place in the text.
- **The exclusion from the screen tools stays.** It now has its reason written down (the problem's Today). Panel access doesn't let the screen tools into the panel, and it gives nothing in Settings, so the controls that govern sessions stay out of the tools.
- **What a session reads goes to Anthropic** with its context, and stays in its transcript on this Mac:
  - the panel's state;
  - for other sessions, what their board card shows, and the text on their terminal screen;
  - the Outline's bullets, which until now were "kept in a file on this Mac and nowhere else".

  A terminal screen holds whatever is on it: a session's latest exchange, or a shell's output, secrets included. The switch is the user's consent, and its detail says this. Nothing on this path goes to TypeSafe.
- **Edits happen without asking,** as screen actions do. Claude Code's per-tool rules can allow the `_read` tools and ask before `outline_act` (inferred, as for `click`). Every edit is on the user's undo stack.
- **One server, one more switch.** One server and one relay mean one protocol subset and one line on the command line. A switch of its own costs one key and one row, and lets the user give sessions Varnick without giving them the screen.
- **A session gains the tools at its start,** as with Screen access: Claude Code reads `--mcp-config` at launch, so a session gets the tools at its next start or with Restart.

## User Stories

1. As a Varnick user, I want to turn Panel access on once, so that the sessions I start or restart can see what Varnick's panel shows.
2. As a Varnick user, I want a session to read and edit my Outline as a working document while I keep typing, even in the same bullet, without losing my typing or its edit, and with my caret staying where I was in the text.
3. As a Varnick user, I want ⌘Z to undo a session's edit to my Outline as a step of its own.
4. As a Varnick user, I want a session to open the board or the Outline for me, without its bringing the panel up while I'm in another app.
5. As a Varnick user, I want a session to see my other sessions as the board shows them, and what their terminal screens show, so it can tell what they are doing.
6. As someone adding a view to Varnick, I want sessions to get tools for it by adopting one protocol, not by changing the MCP server.
7. As a Varnick user, I want turning Panel access off to stop every session's Varnick tools at once.

## Implementation Decisions

**The switch**
- **Where:** Settings › Claude, under Screen access. Its UserDefaults key is `panelAccess`, a bool, off when missing.
- **Its detail** says:
  - that sessions started or restarted while it is on can read what the panel shows, the board's cards, the terminal screens of every pane and the Outline;
  - that they can change the Outline without asking, even the bullet being typed in, and that ⌘Z undoes their edits too;
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
- **A name,** which names its tools (`board`, `pane`, `outline`).
- **Static specs:** its read arguments, and its actions with their arguments and a line each. The relay lists the tools from these.
- **A read:** the view's state as text, with ids from the pane's table.
- **A perform,** for a view with actions: one action by name, through the same model functions the view's keys call. It returns what was done, or a refusal. Calls may wait, as the Outline's do (below), so perform is async.
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
  - a tab, with its name and its panes by kind and title with their `s` ids, which pane has focus, and "this session" on the caller's own pane;
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
  - within 2 s of a key the user pressed in the panel, since the user is typing there. The panel's key monitor stamps the time of each key it sees;
  - while Settings, the Restart Varnick card or the split picker shows.

**Other sessions** (the user's choice of 2026-10-11)
- **In:**
  - what their board card shows: title, project, host, turn and how long, background work, the card's note, work links;
  - the text their terminal screen shows now (`pane_read`).
- **Out, except as far as the card or the screen already shows them:**
  - their transcripts and prompts. A card's title can be a prompt's first line, and a screen shows Claude's latest exchange; nothing beyond that is read;
  - their scrollback;
  - a page's or a file's contents.
- **Never:** the search field's text.

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

**The panes: `pane_read`**
- **`id`:** an `s` id from `panel` or `board_read`. The caller's own pane is allowed.
- **A terminal pane on this Mac** (a Claude pane or a shell): its kind, its title, and the rows its terminal shows now as text, read from the pane's terminal on the main actor. Trailing blanks and empty rows at the end are trimmed. Never the scrollback.
- **A pane showing a card,** because another Mac or a device is in control or the host can't be reached: the live or frozen screen the card holds, marked "Last screen at HH:MM" when frozen, else that it has none.
- **A pane not started yet** (a restored tab never shown): "not started".
- **A page, a file, a custom app or the live Transcript:** its kind and title only.
- **A paired Mac's session with no pane here:** no screen. Its live screen is sent only while its card shows.

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
- **Undo is one stack.** ⌘Z undoes the last edit, whoever made it, within the launch as now. Sessions get no undo action.

**The Outline: the bullet the user is typing in** (the user's choice of 2026-10-11: allow)
- **The rule stands:** the Outline never sets the text of the view that has the caret, since the user's next key writes that view's text back into the tree.
- **An edit to the text or note under the caret goes into that view as a key does.** That is a `set_text` or `set_note` on the bullet whose text view (or note view) has the caret, through any placement of it, since a mirror shares its text. In order:
  1. **Wait while an input method is composing** (`hasMarkedText`), checked each main-queue turn, for up to 3 s. If it is still composing then, the edit is refused: "The user is composing text in that bullet: try again".
  2. **Find the smallest change:** the common start and end of the view's text and the new text (UTF-16) are kept, and only the part between them is replaced.
  3. **Ask the view first,** with `shouldChangeText(in:replacementString:)`. Its delegate's rules apply, as for a key: no line break in a bullet's text, and the selection noted where an undo puts the caret back.
  4. **Replace only that range** in the view's text storage.
  5. **Set the selection again around the change.**
     - A selection wholly before the range stays.
     - One wholly after it moves by the change in length.
     - One that overlaps the range becomes a caret at the end of the new text.
  6. **Call `didChangeText()`.** Tags are coloured again, and the delegate's `textDidChange` reaches `Outline.textChanged`, which applies the view's text to the tree through `apply`, as typing does. The tree gets the text from the view, never the other way round.
  7. **Record it as a session's edit.** `Outline` marks the change while it runs, so `textChanged` records an undo step of its own rather than joining the typing run, and the user's next key starts a new step. The step keeps the user's caret, so ⌘Z puts back the text and the caret together.
- **Every other placement** of that bullet takes the new text from the tree, as now: their views don't have the caret.
- **A structural edit that moves the caret's row** (`move`, `indent` or `outdent` of it or of a row above it on its path): the caret follows the row to its new path, at the same field and offset, as the keys' own moves do.
- **A structural edit that hides or removes the caret's row:**
  - `complete` with Show completed off, or `delete`, of the caret's own row: the caret goes where the same key would put it (the edit's own caret).
  - `delete` or `collapse` of a row above it: the caret goes to the nearest row still showing on its path (`restoreCaret`).
  - Keys typed meanwhile are queued and sent again once the caret lands (`queuedEvents`), as now.
- **While the caret is on its way to a row** (`pending`), an edit waits for it to land, a few main-queue turns at most, then applies.
- **Otherwise an edit never moves the caret,** scrolls, opens a note or keeps its bullet in view under the filter. `apply` takes whether to follow the edit's caret: the keys' calls do, and `outline_act` follows only as above.

**Refusals,** each with a sentence the session can act on:
- the switch is off;
- Varnick is still starting;
- no Claude pane on this Mac has the pane id, or another Mac or a device is in control of it;
- the request's version differs ("Restart this session…");
- `show`'s refusals above;
- the Outline file can't be read, or an input method is still composing after 3 s;
- an unknown, gone or wrong-kind id.

**The log**
- One `NSLog` line per call: the tool, the action, the outcome's kind, durations and counts.
- Never a bullet's text, a screen's text, a title, a name or a filter word (ADR 0030 says the same of bullets).

**Docs the builder updates with the code**
- `CONTEXT.md`: **Panel access** (Further Notes).
- An ADR, 0031, since 0030 is the Outline's. It records that sessions read and act on Varnick through its model, on the `varnick` server, with no grant.
  - It amends ADR 0023: the screen tools' own-process rule stands, now with its reason.
  - It amends ADR 0030: bullets go to Anthropic with a session that reads them while the switch is on, and a session's edit can land in the bullet being typed in.
- `docs/privacy-and-security.md`, the README and the guide: what a session reads (other panes' terminal screens included), and that its Outline edits happen without asking.
- `docs/agents/where-it-breaks.md`:
  - a Panel access section, with the items below;
  - the Outline's text-view rule. Its sentence "the outline never sets the text of the view that has the caret" gains: "A session's edit to that bullet's text or note (Panel access) goes into that view as a key does: `shouldChangeText`, only the changed range replaced in its text storage, the selection set again around it, then `didChangeText`, so `textChanged` applies it as an undo step of its own. It waits while the view has marked text. Any other change to the caret's bullet from outside is lost at the user's next key."

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
- **Focus and keys:** a view changes only through `activate`, `showBoard`, `showOutline` and `showSearch`. The board and the Outline never show together. A tab under them is activated without focus. The key monitor's new stamp must not change what it returns for any key.
- **Panel size:** `panelHeight` follows only through those functions.
- **The Outline:**
  - the view with the caret is changed only as a key changes it (above);
  - every edit goes through `apply`;
  - a bullet inside itself is the tree's check alone;
  - the file is never written when unreadable or newer;
  - a bullet's text is never logged;
  - the rows are `refreshRows()`' alone;
  - the caret's moves go through `moveCaret`, with keys queued meanwhile.
- **Sessions and tabs, the board:**
  - the board's read stays a stat on the main actor;
  - the Problems tab stays behind its switch;
  - the paired Macs are asked only while the board shows;
  - a pane's terminal is read, never resized or written.
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
  - `board_read` matches the board, with this session marked;
  - `pane_read` on another Claude pane gives its screen's text, on a card its frozen screen, and on a page its title only;
  - `outline_read` gives the tree, and `as_shown` matches the screen under a zoom and a filter;
  - `outline_act add` lands while the user types in another bullet, and the caret and its text are untouched;
  - `set_text` on the bullet being typed in: the text changes in place, the caret stays at its place in the text, the user's next key adds to the new text, and ⌘Z takes back the session's edit alone;
  - the same while composing with an input method (Japanese, say) waits until the composition ends;
  - `indent` of the caret's row: the caret follows, and typing goes on in it;
  - turning the switch off makes the next call fail with no restart;
  - Varnick's log holds kinds and counts only.
- **Seams for a test target later:**
  - the `insert` edit;
  - the smallest-change and selection-shift rules of an edit under the caret, which are pure;
  - the protocol's adopters' read and perform against a model;
  - the router's refusals and the id tables.

## Out of Scope

- **Keys through the panel's own key path,** for hand-testing key handling (option 02).
- **Actions on other sessions** from the board: Done, Restart, End.
- **Other sessions' transcripts, prompts and scrollback,** beyond what the card or the screen shows.
- **Search as a tool:** its results are browser history, bookmarks and sessions, which would go to Anthropic. It can adopt the protocol later.
- **Settings,** to read or to act on.
- **The contents of a page, a file or a custom app.**
- **For sessions in the Outline:** undo, redo, zoom and filter; an absolute move to another parent, which would be a second tree edit asking `contains`; a session's own filter or zoom.
- **A command line on the same requests** (option 04).
- **Sessions on other Macs,** and permissioning, which stays deferred as for Screen access.

## Further Notes

**Decided on 2026-10-11** (the user's decisions, relayed by the coordinator)
- **Accepted,** with option 02 to follow it.
- **The switch:** Panel access has its own, not Screen access's.
- **Other sessions:** the board card and the terminal screen's visible text, beyond the planner's recommendation of the card alone. Never the search field's text. Transcripts and prompts are in only as far as the card or the screen shows them.
- **The bullet being typed in:** an edit to it applies, as a key does in that bullet's own view (above). It is neither refused nor held, apart from the wait while an input method composes.
- **Defaults the user didn't answer, which the user can change:**
  - The build order: the server and router, `panel`, `show`, `board_read` and `pane_read` go on main first, and the Outline's parts after the Outline merges.
  - `keys` (option 02) never brings the panel up.

**Added while building ticket 06 (2026-10-11)**
- **Limits:** `add` takes at most 1000 lines, and its reply lists at most 100 new ids, naming the call that reads the rest.
- **The caret's landing:** an edit that moves the user's caret is refused when the caret hasn't landed within 1 s, so a slow view never leaves an edit half placed.
- **Open:** a session's move, indent or outdent of a row inside the user's whole-bullet selection ends that selection; the caret goes to the nearest row instead of the selection following the rows.

**Considered, not taken**
- **Sessions editing `outline.json` themselves.** ADR 0030 makes Varnick its one writer. A running Varnick saves over the file, and its undo stack would know nothing of the change.
- **A second MCP server for these tools.** It would be a second process per pane and a second entry on the command line, on the same socket.
- **Hand-listing each view's tools in the server, as the screen tools are.** Simple, but each new view would mean a change to the relay. The registry lists them from the views' own specs.
- **Refusing, or holding, an edit to the bullet with the caret.** That was the planner's recommendation; the user chose to allow it.

**Glossary, proposed:** **Panel access**: the setting (Settings › Claude, off by default) that gives the Claude **Session**s in Varnick's panes, started or restarted while it is on, tools for Varnick itself: what the panel shows, opening a view, the **Session board**'s cards, the panes' terminal screens and the **Outline**'s bullets. It works through Varnick's own model, with no permission. _Avoid_: Screen access (any app's window, through Accessibility), API, automation.

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
  - `SessionBoard.Card`'s fields;
  - a pane's terminal view (`getTerminal()`) and a card's frozen screen (`PeerScreen`).
- At 596c761 (the Outline):
  - `Outline.apply` records, saves and moves the caret;
  - `updateNSView` skips the view with the caret, and `syncFromModel` runs when it resigns;
  - the delegate's `shouldChangeTextIn` notes the selection and refuses line breaks in a bullet, and its `textDidChange` calls `Outline.textChanged`;
  - `didChangeText` colours the tags again;
  - restyling waits while there is marked text;
  - the file is read on the first show;
  - one undo stack with typing runs;
  - `OutlineEdit`'s cases;
  - a row is a path;
  - `showOutline` and `Outline.key` are wired into the model and the key monitor.

**Inferred**
- Claude Code's per-tool rules can allow the read tools while asking before `outline_act`.
- The board's `refresh` is cheap enough to run once for a read with the board hidden. It is the tick's own work.
- NSTextView keeps the selection where it is set after a text storage edit, and the Outline's later `apply`, which records the step before the tree changes, doesn't move it.

**Unverified, for the builder to check first**
- That Claude Code shows a server's tools when the list changes between starts, with no prompt.
- How large `outline_read` is for a real outline at depth 3: the 400-row cap is a guess.
- SwiftTerm's call for a row's text on screen, and how it treats wide characters.
- Whether an input method's marked text can start between the check in step 1 and the replace in step 4. Both run on the main actor in one turn, so it shouldn't.
