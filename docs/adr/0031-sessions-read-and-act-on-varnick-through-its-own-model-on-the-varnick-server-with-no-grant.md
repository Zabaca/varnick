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
- **Bounded.** 400 rows then "N more: read at oX", a total of about 60,000 characters, a bullet's text cut at 500 characters and a note at 30 lines.
- **`panel` and `show`** say the Outline's zoom, filter and caret; the log holds none of it (the tool, a kind, a count of lines).
- **It amends ADR 0030:** the Outline's bullets were "local only", kept in a file on this Mac and nowhere else. With Panel access on, a session that reads them sends them to Anthropic with its context, and they stay in its transcript on this Mac. The file itself, its format and the rule that it is never written over when unreadable are unchanged. Nothing reaches a paired Mac, the phone or TypeSafe.

## It amends ADR 0023

ADR 0023 says "Never Varnick's own window" and gives no reason. The reason, found in the history of the option (the problem's Today):

- It was recorded when each click and type was to be approved in a prompt in Varnick's own panel. A session that could click the panel could approve its own actions, and Settings, in the same panel, holds the Screen access switch (the one stop for running sessions), Skip permissions and the Grant buttons.
- The reason was lost when approval was deferred with all permissioning, and the refusal stayed.
- `type`'s and `look`'s rules share the root: while the user talks to a session the panel is usually key, so keys meant for the app behind would land in a pane of the panel.

**The screen tools' own-process rule stands, with that reason.** Panel access does not let the screen tools into the panel, and it gives nothing in Settings: Settings never adopts the protocol, so the controls that govern sessions stay out of the tools. Today the rule is not a boundary, since every pane process has Varnick's grants; it keeps the tools Varnick offers off Varnick's controls until permissioning makes them the only way in.

## Considered Options

- **Send keys through the panel's own key path (option 02, accepted to follow).** It tests key handling and focus, which these tools do not. It needs its own decision about posting events, so it is not part of this one.
- **Let the screen tools into the panel (option 03).** Rejected: it would put Settings within the tools' reach and needs Accessibility.
- **A command line on the same requests (option 04).** Kept for later.
- **A second MCP server for these tools.** Rejected: a second process per pane and a second entry on the command line, on the same socket.
- **Hand-listing each view's tools in the server, as the screen tools are.** Rejected: each new view would mean a change to the relay. The registry lists them from the views' own static specs.
- **Sharing Screen access's switch.** Rejected by the user: a switch of its own costs one key and one row, and lets the user give sessions Varnick without giving them the screen.

## Consequences

- **One more switch, one more server argument.** A session started with only Panel access on lists `panel` and nothing of the screen tools; with both on, both sets.
- **A hand test through these tools checks the model, not the key path.** How it looks is still a screen picture's job.
- **Adding a view's tools is adopting `PanelAccessView` and one line in the registry.** The router keeps the switch, the pane, the ids, the refusals, the log and the reply.
- **The Outline's reading has shipped** (`outline_read`, above). **Not decided here, and amended when it ships:** the Outline's edits (`outline_act`), including an edit that lands in the bullet being typed in.
