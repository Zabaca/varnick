---
problem: panes-open-only-by-hand-at-a-mac
title: A session opens panes beside its own with `pane_open`, and closes the ones it opened with `pane_close`, on this Mac
summary: Two tools on the `varnick` server, behind a switch of their own under Panel access. `pane_open` adds a terminal, a Claude session with a starting prompt, a custom app such as Scratch, a page or a file beside the calling pane, in its own tab. Focus stays where it is, the panel is never brought up, and a tab holds at most four panes after an open. A new Claude pane starts at once, following Varnick's Skip permissions setting, and never skips when the caller doesn't. `pane_close` closes a pane the same session opened, until the user has focused it. This Mac's own tabs only, while no other machine controls them.
status: proposed
---

## Solution

**Two tools and a switch.** `pane_open` and `pane_close`, a set of their own on the `varnick` server. A Claude pane lists them when it starts or restarts while the switch is on, as the task tools are listed while Tasks is on. The switch is "Sessions can open panes" in Settings › Claude, under Panel access, off by default. It needs Panel access on, since the ids the tools give and take, and `pane_read` and `board_read`, are Panel access's. Both switches are read at every call, so turning either off stops the next call with no restart.

**`pane_open`** takes a `kind` and that kind's fields:

| Kind | Fields | Opens |
|---|---|---|
| `terminal` | `folder` | The account's login shell in the folder, as the picker's Terminal does. Nothing is typed into it. |
| `claude` | `prompt`, `agent`, `folder` | A Claude session started at once, the prompt as its first message (none: it waits, as a fresh split does). The agent must be one found in the folder. |
| `app` | `app` | A custom app the split picker would list from the caller's folder, by name or folder name. It is told it was split from the calling pane, so Scratch serves the caller's area. |
| `page` | `url` | A Browser pane at an http or https address. |
| `file` | `path` | A file pane, for a file inside the caller's project. |

- `folder` defaults to the caller's. One given must be the caller's project or inside it, a worktree under it included.
- `place` is `beside` (the default) or `below`.
- The reply gives the new pane's id (the `s…` id that `pane_read`, `show` and `board_read` use), its kind, and that it is not focused. A refusal says what to change: an unknown app lists the apps there are, a full tab gives the cap.

**Placement.** The new pane goes beside the calling pane, not the focused one, and takes half of the caller's place, as a split does. Focus stays on whichever pane had it. The panel is never shown, hidden, pinned or made key, and the tab is never brought up. A tab that isn't on screen changes where it is, and the user sees the pane when they open it. A tab may hold at most four panes after a session's open; the user's own splits stay unlimited.

**A Claude pane is an ordinary pane.** It is saved, restored and on the board, raises notices, takes part in Done, and lists the same tools, so a helper may open panes too, within the tab's cap. It skips permission checks only while Varnick's Skip permissions setting is on and the calling session itself was started skipping them.

**`pane_close`** takes an id. It closes a pane the calling session opened, as ⌘W would: a Claude pane's conversation goes to the tab's history, and a terminal ends. The first time the user focuses a pane a session opened, the pane is the user's, and `pane_close` refuses it. It refuses the caller's own pane and every pane it didn't open.

**Where it works.** In the calling pane's own tab on this Mac, while no other Mac or device controls that tab: the rule every pane tool uses. A hidden tab (the voice session's) is refused, and the voice session isn't listed the tools at all.

## Trade-offs

- **Both uses in one tool:** showing the user something beside the session (Scratch, a page, a file, a shell), and a helper session the user can watch, type into and close.
- **Built from what exists.** The request rides Panel access's line on the user-only socket and its router; the pane is added the way a peer's split of this Mac's tab adds one. No new request type, no protocol change.
- **One more switch.** Panel access was built to read and show, and its `keys` refuses starting a session: starting processes and Claude sessions gets its own consent.
- **Nothing asks before a Claude pane starts.** In a session that skips permissions, a helper is no more than its Bash could start already, only visible. In one that doesn't, Claude Code asks before the call, and the helper doesn't skip either.
- **Helpers cost.** Each draws on the user's Claude subscription and memory, and its turns raise notices like any pane's.
- **The user's pane shrinks** by half when the tab is on screen, as with a split from the picker.
- **A terminal opens empty.** A command typed into it would run outside Claude Code's permission checks, so Claude still runs its commands in its own Bash.
- **This Mac only.** A session in a tab another machine controls, or on a headless host, opens nothing (option 02).
- **Half of orchestration's need.** `orchestration-lives-in-one-session` option 04 can open its agents' panes with this; when a helper is waiting or done comes from `board_read`'s turns, not a result file.

## User Stories

1. As the user, I want Claude to open Scratch beside its pane when I ask for a picture, so that I don't split and pick it myself.
2. As the user, I want Claude to open a shell, a page or a file beside its pane, so that I can look at what it is talking about.
3. As the user, I want Claude to start a helper Claude session in a pane beside it with a prompt, so that I can watch the helper and type into it.
4. As the user, I want a pane Claude opens to leave my focus and my panel alone, so that I keep typing where I was.
5. As the user, I want a tab to stay usable however many panes Claude opens, so that my own pane never becomes a sliver.
6. As the user, I want a helper never to skip permission checks that the session that started it doesn't skip, so that opening a pane gives no more power than the caller has.
7. As the user, I want Claude to close the panes it opened when it is done with them, and never one I have taken up or opened myself.
8. As the user, I want to turn this off in Settings and have it stop at once, so that I decide whether sessions change my tabs.
9. As the user, I want a pane Claude opened to come back after a restart like any pane, still known as Claude's to close.
10. As a session, I want the new pane's id in the reply, so that I can read its screen with `pane_read` and follow its turn with `board_read`.
11. As a session, I want a refusal to say what to change, so that I can call again correctly or tell the user why not.

## Implementation Decisions

- **The sibling** is the split picker's split of this Mac's tab, with the call that adds a pane beside a given one without moving focus, and the start a peer's split does at once, rather than waiting for the view to start it.
- **The request** is the Panel access request with the new tool names, answered by its router after its own checks (the version, Panel access, Varnick starting, the calling pane), then this switch, the tab's lock, the hidden tab and the cap. The request's version stays as it is, since only tool names are new (inferred). The server lists the set under a new argument, as it does the task tools.
- **The caller's permission mode** is remembered per pane, in memory, as its claude was started; the new pane's record carries the result, as a peer's start does.
- **Saved state:** one optional field on the session record, the pane that opened it, cleared the first time the user focuses the pane. Older files load; an older build ignores it. One new settings key for the switch, off by default.
- **`panel`** marks a pane "opened by this session" while that field names the caller.
- **The log** holds the tool, the kind, the outcome and the time, never a prompt, an address, a path or an app's name.
- **The descriptions** say to open only what the user asked for or what the work plainly needs, that a helper draws on the user's subscription, and that nothing new is read.
- **Docs:** an amendment to ADR 0031 (sessions now change a tab's layout), where-it-breaks › Panel access, the Scratch skill's step 4 (open Scratch with `pane_open` when the switch is on, else ask), CONTEXT.md's Panel access entry, the guide and the privacy doc's line on what sessions may do.

## Testing Decisions

- **No test target yet.** Where tests would go: the rule for the new pane's permissions (setting × caller), the cap, which panes `pane_close` takes, and the folder check. `make check-mcp` gains the new names, with no clash and listed only under the new argument.
- **Build:** `make build`.
- **By hand, after the user restarts Varnick,** in a session restarted with both switches on:
  - each kind opens beside the calling pane, with focus and the panel unchanged, typing in the caller's pane carrying on;
  - with the caller's tab not on screen, and with the panel hidden, the pane is there when the user opens it, and no other terminal changes size (`VARNICK_LOG_RESIZE=1`);
  - a Claude pane with a prompt starts working; with Skip permissions off, or a caller that doesn't skip, it asks;
  - Scratch opened this way serves the caller's area;
  - the fifth pane is refused; `pane_close` closes an opened pane, and refuses it once the user has focused it, and after a restart still closes one the user never focused;
  - turning the switch off refuses the next call; the voice session's `/mcp` lists neither tool.

## Out of Scope

- Typing into another pane, or running a command in an opened terminal.
- Learning when a helper is done beyond its turn on the board (`orchestration-lives-in-one-session` option 04's result files).
- Opening a new tab, or a pane in another tab.
- Tabs another machine controls, and headless hosts (option 02).
- The phone (option 03).

## Further Notes

- **Verified in the code at 11762e0:** adding a pane beside a given one leaves focus where it was, while a split focuses the new pane; a peer's split of this Mac's tab starts its pane at once in a tab not on screen; no pane limit exists; a custom app is handed the pane it was split from; a session on a headless host gets `notify` alone; the voice session's record skips permissions and isn't a run, so it gets a pane's full set.
- **Unverified:** that the focused terminal keeps the keyboard when its place becomes a split with no focus call. Moving panes re-focuses the same pane a turn later; this may need the same, which must not make the panel key.
- **Combines with** `sessions-cant-read-or-drive-varnick` option 04 (Panel access's requests as a command line): if built, scripts and shells could open panes too.
- **Open questions,** the recommendation first:
  1. **Kinds.** Recommended: all five. Otherwise all but Claude, leaving helper sessions to `orchestration-lives-in-one-session` option 04.
  2. **Placement.** Recommended: beside the caller at half its place, `beside` or `below`, never focused, at most four panes in a tab after an open (four is a guess at what a 13-inch panel holds side by side). Otherwise a size argument, or a cap per session in place of the tab's.
  3. **The user's OK for a Claude pane.** Recommended: none; the pane follows the setting, capped by the caller. Otherwise the pane opens on a card showing the prompt, with Start; or a card only when the pane would skip permissions. A card holds back a helper the user isn't there to start.
  4. **Closing.** Recommended: only panes it opened that the user hasn't focused. Otherwise any pane it opened, or none.
  5. **The switch and the tools' shape.** Recommended: a switch of its own under Panel access, with `pane_open` and `pane_close`, since Panel access refuses starting a session today. Otherwise Panel access alone, with one `pane_act` (`open`, `close`) on the pane view: the registry's way, with no new switch.
  6. **Reach.** Recommended: this Mac's own tabs only. Otherwise every host, whoever is in control (option 02).
  7. **The voice session.** Recommended: not listed. Otherwise it opens a pane in a new tab of its own, shown in the strip.
