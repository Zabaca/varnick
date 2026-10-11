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

## What a session is shown goes to Anthropic

What a session reads goes to Anthropic with its context and stays in its transcript on this Mac: the panel's state, names and titles of tabs and panes included. Nothing on this path goes to TypeSafe. The search field's text is never read, only its mode. The switch is the user's consent, and its detail says so, as the README and `docs/privacy-and-security.md` do. Each later tool that reads more says so in the same places before it ships.

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
- **Not decided here, and amended when they ship:** the Outline's part (it waits for the Outline to merge, and amends ADR 0030: its bullets go to Anthropic with a session that reads them, and a session's edit can land in the bullet being typed in).
