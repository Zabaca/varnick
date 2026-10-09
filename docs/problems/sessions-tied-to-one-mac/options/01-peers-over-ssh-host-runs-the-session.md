---
problem: sessions-tied-to-one-mac
title: Launchy peers over SSH; the host's Launchy runs each session
summary: Each Launchy reaches the other's running Launchy through a relay it runs over SSH. A session always runs on its host, started there by the host's own Launchy, which keeps a pane for every session it runs. The Mac in control is attached through `ssh -t` to the host's zmx; the other shows a frozen screen with Take over, which relabels the session and detaches its clients. Recent and search pull the other Mac's session rows over the same channel.
status: shipped
---

## Solution

**Peers.** Each Launchy install has a peer id and a name (the Mac's). Settings › Peers lists the Macs it is paired with, each with whether it answered lately and its Launchy version. Find Macs suggests the macOS nodes `tailscale status --json` lists as online. Each one is tried with a hello over SSH, and only the Macs whose Launchy answers can be added. An SSH address can also be typed by hand. Pairing works both ways: a hello carries how to reach the caller, so the other Mac adds it back and shows it in its own list. A Mac that isn't paired is never contacted.

**The relay.** Launchy's own binary gets a peer mode, which it runs before anything else starts, like `--search` and `--rerank-eval`. Each Launchy keeps a link to its binary at a fixed place in its Application Support folder, refreshed at launch, so a peer's SSH command doesn't need to know where the other Mac's checkout is. A request is one base64-encoded JSON argument, so no user text passes through the remote shell. The relay hands the request to the running Launchy over a socket in its Application Support folder that only the user can open, and prints the reply. A few reads work from saved state and zmx when the running Launchy doesn't answer: tabs, Recent, a session's status and its screen.

**Host and control.** Every session has one host, the Mac whose zmx runs it. The host's Launchy starts it from its own GUI login, the way local panes start today, and keeps a pane for every session it runs. The Mac in control has a live pane attached to the session: the host directly, a peer through `ssh -t` to the relay, which checks the session name and replaces itself with the host's zmx attach. The controlling Mac is a label on the zmx session, so it survives either Launchy restarting.

**Take over.** The Mac taking control relabels the session, detaches every client (zmx's only way to detach) and attaches. The Mac losing control sees its client exit, asks the host, finds the session still running and labelled for another Mac, and shows the frozen screen instead of ending the pane.

**The view on the Mac not in control.** The session's screen as the host's zmx last drew it (`zmx history --vt`), fed into the pane's terminal, which takes no input. A bar across the pane says "Controlled on <Mac>" and has Take over. The screen is fetched again whenever the pane is shown.

**Recent and search.** Each history sync asks every reachable peer for the session rows it has read from its transcripts since the last sync. A keeps them tagged with their Mac and searches them with its own. The peer's Recent is asked for when the panel shows, and listed in A's own. ↩ on one sends its host a `resume` request, and the pane opens on A in control.

## Trade-offs

- **claude starts the same way on every Mac.** The host's running Launchy starts each session, so it has the same Keychain login, environment, SessionStart hook file and sweep as a local pane. Nothing Claude runs is started from an SSH login.
- **The launch sweep is nearly unchanged.** The host keeps a pane for each session it runs, so "kill what no pane owns" still holds on every Mac, and ADR 0004 stands, with one exception: the sweep spares a session labelled for a listed peer (ADR 0007).
- **Both Launchys take part.** The host shows the sessions it runs for its peer, and either Mac can take any session. That is the user's "peers, not SSH hosts".
- **No listening port.** SSH with the user's keys is the only way in, and the socket is owner-only on the Mac itself, the same posture as the user's existing browser terminal, where Tailscale is the only door.
- **The host's Launchy must be running** to start a session there. Taking over, attaching and reading status still work through the relay's fallback while it restarts, and an attached session doesn't depend on it at all, since the bytes go straight to zmx.
- **More moving parts than option 02:** a peer mode in the binary, a socket in Launchy, and a request format two builds must agree on. A hello refuses a peer on another protocol version.
- **Starting a session from A adds a tab on B,** in the background, controlled on A.
- **Every control action is an SSH round trip.** With a shared connection kept open it should be tens of milliseconds over the tailnet, and a second or more without one (inferred, not measured).
- **The view on the Mac not in control is frozen,** not live (option 04 is the live version).
- **B's prompts are copied to A** for search, between paired Macs only, and never reach a reranker (decision 3 below).

## User Stories

1. As a user at my laptop, I want to start a Claude session that runs on my desktop Mac, so that it keeps running there after I close the laptop.
2. As a user typing a prompt, I want to name the Mac it runs on the way I name a project or an agent, with suggestions, so that starting elsewhere is one word.
3. As a user, I want a pane and its rows to show which Mac the session runs on whenever it isn't this one, so that I always know where the work is.
4. As a user back at my desktop, I want the session I started from my laptop to be there, marked "Controlled on <laptop>", so that I can see it and where it is being typed into.
5. As a user, I want Take over on either Mac to move control to that Mac, with the screen as it was, so that I carry on where I left off.
6. As a user on the Mac that lost control, I want the pane to keep the session's last screen with "Controlled on <Mac>" and Take over, so that the session doesn't look closed.
7. As a user at my laptop, I want to see the sessions running on my desktop and take one over, so that I can pick up work I left there.
8. As a user, I want only one Mac to type into a session at a time, so that two keyboards never interleave.
9. As a user, I want closing a session on the Mac in control to end it when I started it for that Mac, as closing a pane does today, so that nothing I closed keeps running somewhere.
9a. As a user, I want closing a session on a Mac that it didn't come from (one I started at the host and took over from here) to leave it running on its host, so that closing my view of it never ends work I began there.
10. As a user, I want closing a session's frozen view on a Mac that isn't its host to remove it from that Mac only, so that I can tidy one Mac without ending work.
11. As a user, I want a restart of Launchy on either Mac to neither end a session nor move its control, so that restarts stay harmless.
12. As a user whose laptop sleeps or loses the network, I want the session to keep running on the desktop and the pane to say the connection was lost and offer Reconnect, so that a dropped link costs nothing.
13. As a user whose desktop is off or not running Launchy, I want its sessions on my laptop to say so and nothing to be killed, so that I can retry later.
14. As a user, I want /clear and /resume in a session controlled from another Mac to be followed, so that a later resume opens the right conversation.
15. As a user, I want Recent to list my desktop's ended sessions, marked with the Mac, and ↩ to resume one there, so that I can go back to them from my laptop.
16. As a user, I want search to find my desktop's sessions by their prompts and titles, so that I can find a conversation without remembering where I had it.
17. As a user, I want Settings to list my paired Macs, whether each answered lately, and how to add or remove one, so that I control which Macs talk to each other.
18. As a user, I want a Mac I haven't paired never to be contacted, and nothing reachable without my SSH keys, so that pairing is my decision.

## Implementation Decisions

**Peer identity and pairing**
- A peer id per install (a UUID in UserDefaults) and a display name (the Mac's name). Labels and records use the id, the UI uses the name, and SSH uses the address.
- A peer's address is what the user would type after `ssh`: by default its MagicDNS name, or `user@name` if the user differs. The user's own ssh config still applies.
- Find Macs reads `tailscale status --json` through the Tailscale CLI, from the app bundle or the user's link to it, since Launchy under launchd has no shell `PATH`. It tries a hello on each online macOS node that isn't this Mac, in the background, and lists those that answer. Without Tailscale's CLI, only adding by hand works.
- A hello returns the peer's id, name, address for the way back, Launchy protocol version, Launchy build and zmx version. A different protocol version is shown on the peer's row and blocks every other request to it.
- Reverse pairing: a hello from an unknown Mac adds it to the list, marked "added by <Mac>", and the receiving Mac confirms the way back with a hello of its own. Removing a peer on one Mac doesn't remove it on the other.
- Saved in UserDefaults as a list of peers (id, name, address, last answered). Not in `sessions.json`.

**SSH**
- Every call made without a person (hello, start, status, take over, rows) uses `BatchMode=yes`, a short connect timeout, keep-alives, and a connection shared per peer and kept open for a while, with its control socket under Launchy's Application Support folder. The shared master is a background `ssh` process, the only process this adds.
- The pane of a session controlled from a peer runs `ssh -t -e none` to the relay's attach request. `-e none`, because `~.` at the start of a line in Claude would otherwise close the connection.
- The pane's environment gets the user's `SSH_AUTH_SOCK` in addition to today's minimal set, or keys in the agent can't be used.
- Host keys: Launchy's calls accept a peer's key on first contact and refuse a changed one. The tailnet has already authenticated the node, so trusting the first key it presents costs little, and the user doesn't have to run ssh by hand once per Mac.

**The relay's requests**
- `hello`; `start` (folder, prompt, agent, resume id, whether to skip permissions, the requesting peer); `resume` (a conversation that ended on the host, a new session id, folder and agent, the requesting peer: starts `claude --resume`, only for what the user picked in Recent or search, and distinct from `start` with a resume id, which only restarts a pane the host restored itself); `attach` (session name, whether to take control, which also relabels and detaches when taking); `status` (sessions: running or not, client count, controlling peer, current conversation, title); `screen` (session); `end` (session; the host decides whether it ends or is released, see Ending); `sessions` (the Claude sessions open there); `recent`; `rows` (since a stamp); `projects`; `agents` (folder). Every request but `hello` names the Mac asking and is answered only to a Mac the receiver lists, since they reveal or change what runs there and carry the user's prompts.
- The relay accepts only names of the form `launchy-<uuid>` and never runs a shell. attach replaces the relay with the host's bundled zmx, with Launchy's own zmx environment and `ZMX_SESSION` unset.
- Without an answer from the running Launchy, the relay serves `sessions` and `recent` from `sessions.json`, `rows` from the search database, `status` and `screen` from zmx itself, and `attach` as usual. `start`, `end`, `projects` and `agents` fail with "Launchy isn't running on <Mac>".

**Starting a session on a peer**
- In the prompt, a leading `^name` word picks the Mac, with suggestions like `#` and `@` (the sigil is a default: open question 1). `#project` and `@agent` are then resolved against that Mac's projects and agents, fetched over the relay with the last result shown meanwhile. Without `#project` the session starts in that Mac's default folder.
- The requesting Mac makes the record and its id, as today, and sends `start`. The host adds a background tab with a pane for that record. It creates the zmx session in its own login, labelled `launchy=1` and `launchy-control=<requesting peer>` in the same attach, through a client of its own on a pseudo-terminal, and replies once the session exists. The requester's pane then attaches with take, which detaches the host's starting client. The host's pane shows the frozen screen.
- The session runs the claude command line the host builds with today's code, from the request's fields. Skip permissions follows the Mac the session was started from.
- The requesting Mac's record carries the host's peer id. Its pane isn't wrapped in its own zmx: nested zmx across SSH is unsupported, and the session already outlives everything on the host. Restarting the requesting Mac's Launchy only drops its SSH client.

**When a pane's client exits**
- Today's rule (the pane has ended) still holds when the session is gone.
- When the session is still running and labelled for another Mac, the pane switches to the frozen screen.
- A peer's pane that can't reach the host shows "Lost connection to <Mac>" with Reconnect, and kills nothing.
- The check uses the label, not timing. A takeover always relabels before it detaches, so a session that is ending can't look like one that was taken.

**Take over**
- On the host: relabel to itself, detach every client, attach locally. From a peer: one `attach` with take, which relabels, detaches and then attaches in one request.
- On a Mac not in control, a restored or newly shown pane doesn't attach unless the label names that Mac. It shows the frozen screen. Control moves only through Take over or starting a session.
- A label that names a peer with no client attached (it quit, or lost its link) still needs Take over. The bar then reads "Last controlled on <Mac>".

**The frozen screen**
- After its client exits, the pane's terminal is reset and fed the host's `zmx history --vt`. The pane sends no keys, and focus goes to the bar.
- Fetched when control leaves, and again whenever the pane is shown. Large scrollback is cut to the screen plus a fixed tail (size to be checked by hand).

**Ending**
- Closing a pane in control sends `end`, and the host decides, because only it knows where the session came from. If the session's origin names the asking Mac (a session the host started for it) it ends wherever it runs, as today: the host kills it and closes its pane. Otherwise (the host started it itself, or for another Mac) it is released: control goes back to the host, the session keeps running, and the peer's pane closes for good. How the origin is recorded and what a release does are in `docs/agents/where-it-breaks.md` (Peers).
- Closing the frozen view on a peer removes the view from that peer only.
- Closing the frozen view on the host asks first ("End this session? It's controlled on <Mac>."), because the host keeps a pane for every session it runs (decision 1).
- An ended session goes to Recent on its host, as today, and on the peer that was viewing it, carrying the host's id. Recent lists one entry per conversation.

**Following /clear and /resume**
- The host follows its pane's hook file as it does today, whichever Mac controls the session.
- A peer learns the current conversation and title from `status`, which it polls every few seconds while it has a pane on that host, and when the panel opens.

**Restore**
- A record with a host is restored without a transcript check on this Mac. When it is shown, the pane asks the host: a running session controlled here is attached, one controlled elsewhere shows the frozen screen, and a session that is gone is started again by the host with `--resume`, as after a reboot today.
- No status request runs inside a SwiftUI view update or blocks the main thread. Panes start after the update, as today, and SSH calls run off the main actor.

**Recent and search**
- The host's rows are the ones its history sync already reads from its transcripts: id, folder, title, agent, prompts, first and last prompt. Replies aren't in them.
- The receiving Mac keeps peers' rows in a table of their own with the host's id, so the sync that mirrors its own transcripts never deletes them. They are written and counted current in the same refresh and embedding passes as its own sessions. The local check that a session's folder exists is skipped for them, since the host only sends rows whose folder exists there.
- A peer's rows are embedded on the receiving Mac. Copying the host's embeddings when both use the same model is a later saving.
- They are session rows, so they never reach a reranker, local or TypeSafe. Copying them is allowed between paired Macs only (decision 3).
- A search row and a Recent row name their Mac. ↩ on a session that is open on the host (in control there or not) opens it on the card with Take over, and never takes it by itself; on an ended one it sends the host a `resume` request (never `start`: the host starts a new session for the conversation, under an id the asking pane chose, and refuses one it already has a tab for).
- The session list with an empty query adds each peer's open tabs after this Mac's own, under the Mac's name, fetched when the panel opens, with the last result shown meanwhile. ↩ on one opens it on the card, with its frozen screen and Take over, whoever is in control there and with or without a client attached; the user presses Take over (↩ in the focused card) to take control. Each new row height goes into the panel height in the branch that shows it.

**Saved state**
- `SessionRecord` gains an optional host (the peer id; none means this Mac). Saved records without one load as this Mac's.
- The search database gains a table for peers' session rows, created if missing.
- UserDefaults gains the peer id and the peer list.

**Scope and ticket order** (about five tickets, each usable on its own)
1. **Peers.** Peer id and name, the relay mode and its link, the socket, `hello`, Settings › Peers with Find Macs and adding by hand, reverse pairing, and protocol version checks. Done when both Macs list each other as answering.
2. **Start a session on another Mac** (wish 1). The `^name` word, `start`, the host's background tab, the peer's remote pane through `ssh -t`, the client-exit rules, and closing in control ending the session. The host shows "Controlled on <Mac>" as a plain card, with no screen and no Take over yet.
3. **Take over** (wish 2). Take over on both Macs, the frozen screen, peers' open tabs in the session list, and the ending rules for frozen views.
4. **Follow and restore.** Status polling for conversation and title, lost-connection and offline states with Reconnect, restore of peer panes after either Launchy restarts, and resume on the host when the session is gone.
5. **Recent and search** (wish 3). Rows and Recent from peers, the new table, search rows that name their Mac, and resume on the host. The same ticket rewords the rule in `docs/agents/where-it-breaks.md` (Search store) that a session's prompts stay on this Mac: they stay on the user's paired Macs and never reach a reranker.

## Testing Decisions

- There is no test target. Pure seams for the first tests once one exists: encoding and decoding a relay request; what a pane does when its client exits (session gone, running and labelled elsewhere, unreachable); the relay's name check; merging a peer's Recent into this Mac's, one entry per conversation; the sweep's choice, which must not change.
- Every zmx test made by hand uses a throwaway absolute `ZMX_DIR` and makes sessions through `zmx attach` on a pseudo-terminal (where-it-breaks, Checking by hand). Never the user's `/tmp/zmx-<uid>`.
- By hand, on both Macs (A the MacBook Air, B the Mac Studio), after `make build` on each and a restart the user does:
  - Pairing: Find Macs on A lists B and not the Macs without Launchy. Adding B shows A on B. A Mac without Launchy, an offline Mac and a protocol mismatch each show their own state.
  - Start `>^b fix the tests` on A: a pane opens on A, B gets a background tab marked as controlled on A, and the session's process runs on B (B's `zmx ls` with `ZMX_DIR=/tmp/zmx-$(id -u)` lists it with one client).
  - In the pane on A: typing, arrows, shift+enter, ⌘V of text and of an image (the image paste key is sent, but the clipboard Claude reads is B's, so expect it to fail; see open question 2), scrolling back, resizing the panel, `~.` at the start of a line (must not disconnect), and a long prompt with quotes and `$`.
  - Take over on B: A's pane shows the frozen screen and "Controlled on B", B's pane is live at B's size, and typing on A does nothing. Take over on A again. Then from A, take over a session B started itself.
  - `/clear` on A in a session hosted on B, then restart Launchy on A: the pane comes back on the new conversation.
  - Restart Launchy on B while A is in control: A's pane keeps working. Restart Launchy on A: its pane reattaches when shown. Quit Launchy on B: starting a new session on B fails with a message, and Take over still works.
  - Turn off Wi-Fi on A for a minute: A's pane says the connection was lost, and Reconnect brings the session back. The session ran on B the whole time.
  - ⌘W on A in control of a session started for A (`>^b …`): the session ends on B, its tab closes, and the session is in Recent on both Macs. Closing the frozen view on A leaves B's session running. Closing it on B asks first.
  - ⌘W on A in control of a session started at B and taken over from A: A's pane closes, B's session keeps running, and B's card for it goes live, with no client left on A.
  - ↩ on B's open session in A's list, with no client attached on B and with B typing into it: either way A's pane shows the card and Take over, and nothing is displaced until the user presses Take over.
  - Recent and search on A list B's ended sessions marked with B. ↩ resumes one on B with A in control.
  - B's launch sweep kills nothing that A started.

## Out of Scope

- Terminal, web, file and app panes on a peer, and splitting a peer's pane into one. A split of a peer's Claude pane starts on the same host. Every other kind stays local.
- A live view on the Mac not in control (option 04).
- More than two Macs in the test plan. Nothing in the design is limited to two.
- Syncing settings, projects or agents between Macs.
- Off-tailnet access, and Tailscale SSH (the user chose SSH with keys).
- Moving a session to another host. A session stays on the Mac it started on.

## Further Notes

**Risks, most serious first.**
- **An SSH call blocking the main thread** would freeze the panel. Every peer request has to run off the main actor and never inside a view update (where-it-breaks, Sessions and tabs).
- **Detaching kills.** Until the client-exit rule lands (ticket 2), a takeover on a build without it would end the session. Both Macs have to run builds with the rule before Take over is used.
- **The other Mac's clipboard.** Claude reads the clipboard on the Mac it runs on. Pasted text arrives through the terminal and works, but an image pasted on A can't reach claude on B (inferred).
- **Shared SSH connections from a LaunchAgent.** The shared master is a background `ssh` that outlives the call that started it. Whether that behaves under Launchy's LaunchAgent, and whether XProtect objects, needs a hand check. Without it every call opens a new connection (slower, nothing else).
- **SSH keys in the agent.** Keys with a passphrase in the macOS Keychain need the agent, and Launchy under launchd has to find it. A failure shows as a peer that doesn't answer.
- **A frozen screen at the wrong size.** zmx draws its history at the leader's size, and the viewing pane may be another size. Expect wrapping until it's checked by hand.
- **Protocol drift.** Both Macs build from the same repo, but not at the same moment. The hello's protocol version is the only guard.

**Spikes before ticket 2** (by hand on both Macs, not from a Claude session: they start zmx daemons, and XProtect has killed a session doing similar work):
1. With a throwaway `ZMX_DIR` on B, create a session running claude with `script -q /dev/null zmx attach --labels launchy=1 …`, then detach it with `env ZMX_SESSION=<name> zmx detach` and the same `ZMX_DIR`. The session survives with no client (`zmx list` shows none).
2. From A, run `ssh -t -e none B '<B's zmx> attach <name>'` with that `ZMX_DIR` set on B's side. A is the only client, so it becomes the leader: the screen is restored at A's size, and keys and resizing work.
3. On B, detach again: A's ssh exits 0, A's terminal is reset, and the session survives.
4. `zmx history <name> --vt` fed into a SwiftTerm view renders the screen faithfully, including Claude's colours and box drawing.

**Spike results, 2026-10-04** (the MacBook Air as A, the Mac Studio as B, `ZMX_DIR=/tmp/zmx-spike`). All four passed, with one finding for the frozen view.
- **Detach from outside:** `env ZMX_SESSION=spike zmx detach` returns 0. The attached client gets a terminal reset and exits 0, and the session lives on with `clients=0`. The same held for a client attached over `ssh -tt`.
- **Attach from A:** run over `ssh -t -e none` in a Launchy terminal pane. Typing, shift+enter, a leading `~`, resizing (Claude redraws to fit) and the OSC window title (the tab took Claude's title) all work.
- **Control label:** `zmx set spike controller=studio` followed by a detach left the label in `zmx list` and `zmx get`.
- **Frozen screen:** `zmx history spike --vt` (about 2 KB) drawn in a Launchy pane shows Claude's last screen with its colours and shaded prompt boxes. It keeps the width of the last client to attach, so a frozen view at another size wraps as that client saw it.
- **Finding for the frozen view:** the history includes the private modes Claude had set: `?1000h`, `?1002h`, `?1003h`, `?1006h` (mouse), `?1004h` (focus), `?2004h` (bracketed paste), `?1049h` (alternate screen) and `?2031h`. Replayed into a live pane, they left mouse and focus reports going to the shell as text. The frozen view must strip mode sets, or draw into a read-only view that never sends input back.
- **"Claude API" in the banner** shows for every claude on B, including ones B's Launchy starts in its GUI session, not only from an SSH login. B's `~/.claude/settings.json` sets `CLAUDE_CODE_OAUTH_TOKEN` on a subscription account, so the label most likely reflects token sign-in rather than API billing. It doesn't bear on keeping claude off SSH logins; the host running each session stands on its other reasons.

**Verified and inferred.** Verified in Launchy's code: everything under Today in the problem; that the CLI modes run before the app starts; that `make run`'s kill pattern is anchored to the bare binary path, so a relay started with arguments isn't matched. Verified in zmx 0.8.1's source: the zmx facts in the problem. Verified on this Mac: the tailnet listing, the ssh config, the existing browser terminal's plist, and that `~/.claude/projects` holds 1.1 GB in 126 folders. Inferred: round-trip times, the clipboard, Keychain behaviour over SSH (avoided here by design), the frozen screen's rendering.

**Considered within this option.**
- **Discovery:** a list in Settings only (kept, as adding by hand); Bonjour (Tailscale carries no multicast); Tailscale's macOS nodes without a hello (four on this tailnet, and nothing says which run Launchy).
- **Recent and search:** copying the peer's raw transcripts (1.1 GB on this Mac, mostly replies search doesn't use); searching the peer at query time over SSH (a round trip per keystroke, and the peer would have to load its embedder for each one). Pulling the rows the peer already reads is small and fits the existing sync.
- **Who starts claude on the host:** the relay itself, from the SSH login (option 02). Avoided here so claude never depends on what an SSH login can reach.

**Records.** Accepting this needs an ADR: peers over SSH, the relay, the socket, control as a zmx label, and the host keeping a pane for every session it runs. It doesn't contradict ADR 0004. The new terms Peer, Host, In control and Take over go to `/domain-modeling` for `CONTEXT.md`. The existing browser terminal's glossary uses Session for a zmx shell; here Session stays the Claude conversation, and the zmx one is a zmx session.

**Decided by the user, 2026-10-04.**
1. **Closing the frozen view on the host** asks, then ends the session. The host always keeps a pane for every session it runs, so the sweep is unchanged apart from the exception in ADR 0007.
2. **A session started from a peer** shows as a background tab on its host.
3. **A peer's prompts** are copied between paired Macs only, for Recent and search, and are never sent to a reranker.
4. **The two Macs** are the MacBook Air and the Mac Studio, each with a MagicDNS name of the form `<name>.example.ts.net`.

**Decided by the user, 2026-10-05, after hand-testing.**
5. **Opening a peer's open session always shows the card first,** with Take over, even when no client is attached there. Resuming an ended session still starts and attaches.
6. **Closing on a Mac that the session didn't come from releases it** to the host, which keeps running it; a session started for the closing Mac still ends. The host decides (the `end` request), by the session's origin. Protocol 7.
7. **Signed off as they are:** a card opened from the list that finds its label already naming this Mac attaches directly, since nobody is displaced; a host-started session with no pane on the host ends when closed on a peer; and sessions that predate this change, which have no origin, are released rather than ended.

**Open questions.**
1. **The word that names a Mac in the prompt.** Default, not yet confirmed by the user: `^name`, which no other prompt word uses. `%name` and `+name` also work. `~` would read as a path.
2. **Image paste into a session on another Mac.** Default, not yet confirmed by the user: unsupported for now. Later, Launchy could copy the image to the host's clipboard over the relay before sending the paste key.
