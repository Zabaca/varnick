---
problem: sessions-cant-see-or-act-on-the-screen
title: Launchy brokers look, point, click and type for a session through an MCP server, per pane, with each control action approved in Launchy
summary: Launchy keeps the grants and acts for the session. Every Claude pane gets a small stdio MCP server, `Launchy --mcp`, which passes tool calls to the running Launchy over its user-only socket. There are four tools. `look` returns a window's elements, optionally with a picture or its recognised text. `point` draws the Arrow. `click` and `type` act on an app. A pane can use them only once the user turns Screen access on for that pane. Each click and type is shown with the Arrow at its target, and waits for the user's Allow in Launchy's own panel, once or for the next 10 minutes. The interim helper's grants are removed. Same-user processes can't be told apart, so the per-pane switch stops accidents, not a determined process. The real gates are the approval, and no other executable a pane can run holding Accessibility.
status: proposed
---

## Solution

**Screen access** is a global switch in Settings, off by default, with a per-pane switch under it. While the global switch is on, every Claude pane's claude starts with one more MCP server, `launchy`, from a config Launchy writes. Each tool call goes to the running Launchy over the user-only socket the relay already uses. Launchy checks that the pane has Screen access on, does the work in its own process under its own grants, and answers.

| Tool | What it does | Approval |
|---|---|---|
| `look` | The elements of the focused window, or of a named app's window, in option 01's listing of ADR 0019, each with an id. On request, also its recognised short lines (ADR 0021) or a picture of that one window. | None: the pane's switch |
| `point` | Draws the Arrow at an element id or a rectangle, with the session's note on the sign, signed with the session's name. | None |
| `click` | Presses an element by id through Accessibility, or clicks at a point in a window. | Each, or for 10 minutes |
| `type` | Types text into the focused field, or into an element by id, and presses a named key (Return, Tab, Escape, a shortcut). | Each, or for 10 minutes |

**Approval** shows Launchy's Arrow at the target and a prompt in Launchy's own nonactivating panel: "Kestrel wants to click Delete in Finder", with Allow, Allow for 10 minutes and Deny. Typing shows the text. Nothing acts until the user clicks or presses a key in that prompt.

## Trade-offs

- **The grant stays in one process, behind Launchy's checks.**
  - Launchy decides what a session sees and does, and refuses its own windows.
  - It asks before acting, records what was done, and shows when a session is looking or acting.
  - Once the interim helper's grants are removed, no executable a session runs holds the grants, so it can't act around the broker: no `osascript`, `screencapture` or synthetic events of its own. Launchy's own binary is the exception (next).
- **The approval is the real gate.**
  - The prompt is Launchy's own window, and no process of the user can click it without Accessibility.
  - So it holds only while no executable a pane can run holds Accessibility. The interim helper is one; it can click Allow.
  - **Launchy's own binary is another.** It is the executable Launchy's grants name, so run from a pane it is probably trusted too (the problem's Today). Its command-line modes must never read or act for a caller, and `Launchy --mcp` only forwards.
  - Without the hardened runtime, a process could probably load its own code into that binary and use its grants anyway. `runs-only-from-a-checkout` option 01 closes that, and this gate is only as strong as it.
  - Hence: the helper goes, `click` and `type` refuse Launchy's own windows, and the prompt can't be answered by anything Launchy posts.
- **Per-pane switch: a guard against accidents, not an identity check.**
  - The MCP server sends its pane id, which any process of the user can read from another's environment and send too.
  - Launchy also checks that the caller descends from that pane's zmx session or from that pane, by the socket peer's pid. That makes pretending deliberate, not impossible, since a process of the user can type into another pane.
  - Written down so nobody mistakes it for a boundary.
- **What a session is shown goes to Anthropic.** Element lists, recognised text and pictures enter the session's context and its transcript.
  - Labels of other apps' windows were sent to TypeSafe only under the gate. Here they go to Claude, whose session already holds the user's code and prompts.
  - A picture of a window holds whatever it shows. `look` takes one window, never the display, never Launchy's, and never an app on a deny list (Keychain Access and password managers by default, which the user can extend).
- **MCP rather than a command line.**
  - Claude Code shows MCP tools by name. Its own permission rules can allow or ask per tool (`mcp__launchy__click`), on top of Launchy's approval.
  - A picture comes back as an image the model sees.
  - A command line (option 04) works for any agent, but is gated only by Bash prompts, which a session with Skip permissions doesn't show.
- **Claude Code restarts to gain the server.** The MCP config is read at launch. A pane started before the switch was turned on gains it at its next start, or with Restart in place (⌘⌥R). Per-pane Screen access is checked at each call, so it needs no restart.
- **Same-user limits.** A process of the user that wanted to could still drive a pane by typing into its zmx session, as it can today. This option adds no new power to such a process. It also doesn't contain one.

## User Stories

1. As a Launchy user, I want to turn Screen access on for one session, so that it can see the window it is working on and nothing changes for the others.
2. As a Launchy user, I want a session to show me where to click with the Arrow, signed with its name, so that I know who is pointing.
3. As a Launchy user, I want every click and keystroke a session makes to wait for my Allow, with the Arrow on its target, so that it never acts behind my back.
4. As a Launchy user, I want to allow a session for 10 minutes while I watch it work through a setup, and stop it at any time.
5. As a Launchy user, I want to see when a session is looking at or acting on my screen.
6. As a Launchy user, I want my password manager's windows never shown to a session.
7. As a Launchy user, I want a record of what each session looked at and did.
8. As a Launchy user, I want the interim helper's grants removed, so that no session acts on the screen without Launchy.

## Implementation Decisions

**Turning it on**
- **Settings › Screen access:**
  - a switch, off by default;
  - its detail says what a session is shown, that it goes to Anthropic with the session, and that control waits for approval;
  - it needs Accessibility, and Screen Recording for pictures and recognised text, shown as ADR 0019 and 0021's rows are;
  - a deny list of apps, starting with Keychain Access and the password managers found installed.
- **Per pane:** a Screen access item on the pane's menu, and a key on its board card, saved as an optional field on the pane's record. Off for every new pane. A pane with it on shows a badge in the header.
- **Other granted executables.** Launchy can't ask macOS which other executables hold a grant. So Settings says plainly that any other executable with Accessibility, such as the interim helper, can answer the prompt, and says how to remove it.

**The server and the channel**
- **`Launchy --mcp`** is a stdio MCP server, run by claude. It is Launchy's binary, so it is probably trusted in the pane, but it has no code path that reads or acts. Each call is one request line on the peer socket, carrying the pane id from its environment, the tool and the arguments, and the reply line is the answer.
- **The config.** With Screen access on globally, every Claude pane starts with `--mcp-config` naming one file Launchy writes in its Application Support folder. It isn't per pane: Launchy checks the pane at each call.
- **The socket.** The peer socket gains a `screen` operation, kept apart from the peers' operations. The caller's pid comes from the socket's peer credentials. Launchy walks its parents to the pane's zmx session or the pane's own process and rejects a call whose ancestry doesn't match the pane id it sent.
- **One action at a time** across all sessions. A second waits for the first, and a call waits at most 60 s for approval before it is answered "not approved".

**The tools**
- **`look`:**
  - Arguments: an app name or nothing (the focused app), with `text` and `picture` flags, both off.
  - Returns the window's title and its elements in ADR 0019's description, each with an id valid for that window until the next `look`.
  - With `text`, the recognised short lines (ADR 0021, typed text dropped where it can be placed).
  - With `picture`, a PNG of that window at most 1,568 points on its long side.
  - Refused for Launchy's own windows and for denied apps, by name, with the reason.
- **`point`:** an element id or a rectangle in screen points, and a note. Draws the Arrow, with the sign's note led by the session's name. It replaces any Arrow the same session drew and goes after 8 s, or at the next `point`.
- **`click`:**
  - An element id (pressed through Accessibility's press action), or a point inside a window `look` returned (a synthetic click there).
  - Approval first.
  - Refused on Launchy's windows, on a denied app, and on a point outside every window.
- **`type`:**
  - Text, or a named key or shortcut, optionally into an element id first.
  - Approval first, showing the text.
  - Refused on a secure field and on Launchy's windows.
- **Not built:** drag, scroll and file pickers. A session asks the user.

**Approval**
- **Before acting,** the Arrow goes to the target and the prompt appears in a small nonactivating panel near it: the session's name, the verb, the app, the element's label, and for `type` the text.
- **Answers:** Allow (once), Allow for 10 minutes (this session only, shown as a countdown in the header badge) and Deny. Keys: ↩, ⌥↩, Esc.
- **Ending a grant:** turning the pane's switch off, or a menu-bar item "Stop all screen access", ends it at once.
- **The prompt can't be answered from the socket,** by any tool, or by events Launchy posts itself.

**Showing and recording it**
- **The indicator:** while any session is in `look` or acting, Launchy's menu-bar icon shows an eye, and the pane's badge lights.
- **The record:** each call is written to `screen-log` in the pane's folder, with the time, the tool, the app, the element's label and allowed or denied. Never the picture, the typed text or the recognised lines. It sits beside the work log (ADR 0020), and the board's card can show it later.
- **Launchy's own log** gets kinds and durations only, as for spoken requests.

**State**
- Two new settings (the switch and the deny list), and one optional field on the pane's record.
- The MCP config file, rewritten when the switch changes.
- `sessions.json` gains only the optional field.

## Testing Decisions

- **The pure seams:**
  - the ancestry check (a pid chain and a pane id in, accepted or not);
  - the refusal rules (Launchy's window, a denied app, a secure field);
  - the request and reply lines;
  - the approval state machine (allow once, allow for 10 minutes, deny, expiry, revoke).
- **By hand, after a restart,** with the interim helper's grants removed:
  - From a pane, `Launchy --mcp` and `Launchy --ask --app` are checked for what they can do with Launchy's grants: the problem's measurement.
  - A session without Screen access calls `look` and is told to ask the user.
  - With it on, `look` lists System Settings' controls, and `point` draws the Arrow signed with the session's name.
  - `click` on a switch shows the Arrow and the prompt. Deny leaves it, and Allow toggles it.
  - Allow for 10 minutes lets the next click go, and the countdown shows. Turning the pane's switch off ends it.
  - `type` into a secure field is refused.
  - `click` aimed at Launchy's own panel is refused.
  - A second pane started with Skip permissions and no Screen access is refused, even when it sends the first pane's id from its own shell.
  - Keychain Access is refused for `look`.
  - The pane's `screen-log` holds the calls, and Launchy's log holds no labels.

## Out of Scope

- Drag, scroll, file dialogs and multi-step macros.
- Peers: a session on another Mac acting on this Mac's screen.
- Other agents than Claude Code through MCP (option 04 covers a command line).
- Keeping other same-user processes out of a pane. That is `panes-share-launchys-permissions` and beyond.

## Further Notes

- **ADR on acceptance.**
  - Launchy brokers screen access for sessions, no other executable is granted for them, and the per-pane switch is a guard, not an identity.
  - Launchy's command-line modes never read or act on another app for a caller. That includes deciding what becomes of `--ask --app`.
  - It amends ADR 0019 and 0021's "only for Hey Launchy" reading of the grants.
- **Glossary, proposed:** **Screen access**: what a session is allowed to do on the screen through Launchy (look, point, click, type), turned on per pane. _Avoid_: computer use, remote control.
- **Unverified:**
  - that an MCP tool result can carry a PNG Claude Code shows to the model as an image;
  - the socket peer's pid on macOS (`LOCAL_PEERPID`);
  - the 1,568-point cap on Claude's image input;
  - whether Accessibility's press action works on the apps the user cares about.

  The builder checks each before relying on it, and loads the `claude-api` skill for image limits.
- **Verified:**
  - the socket's mode and uid check;
  - `LAUNCHY_PANE_ID` in every pane, and that `ps -wwE` shows it to the same user;
  - Claude Code 2.1.296's `--mcp-config` and `--chrome`;
  - that nothing in Launchy clicks or types into another app today.
