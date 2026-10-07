---
problem: sessions-tied-to-one-mac
title: SSH straight to the host's zmx; zmx labels are the only shared state
summary: No Launchy-to-Launchy channel. A's relay, run over SSH, creates and attaches the session on B itself, labelled with the Mac in control. B's Launchy finds sessions labelled for another Mac when it lists its zmx sessions, shows them, and spares them in its sweep. Take over, the frozen screen and Recent and search work as in option 01, but every read goes through B's files and zmx rather than B's running Launchy.
status: proposed
---

## Solution

Peers, the relay and its fixed link, the SSH settings, Take over, the frozen screen and the client-exit rules are as in option 01. What differs is that the relay does the work itself, without the running Launchy.

**Starting a session on B.** A runs `ssh -t` to B's relay with a start request. The relay builds the claude command line with the same code Launchy uses for a local pane, then replaces itself with B's zmx attach, which creates the session, labelled `launchy=1` and `launchy-control=<A>`. claude is started from B's SSH login.

**What B's Launchy knows.** Nothing is sent to it. When its panel opens, and every minute or so, it lists its zmx sessions. A session labelled for another Mac that has no pane on B gets a background tab showing the frozen screen. B's launch sweep kills only sessions labelled for B or carrying no control label, and leaves those labelled for a peer to that peer.

**Each Mac sweeps the sessions it controls.** At launch, and when a peer comes back online, A asks each peer to kill the sessions labelled for A that no pane on A points to.

**Reads.** `tabs` and `recent` come from B's `sessions.json`, rows from B's search database opened read-only, `status` and `screen` from zmx, and the conversation from the hook file in B's pane folder.

## Trade-offs

- **Smaller.** No socket in Launchy and no request handling in the running app. The relay is the only new entry point.
- **Works while B's Launchy is down:** a session can be started on B as long as B accepts SSH.
- **claude runs from an SSH login.** Whether it finds its login in the macOS Keychain there is unknown, and is the first thing to try. Folders under Desktop, Documents and Downloads are closed to it unless Remote Login allows full disk access. Its environment has to be built by hand, without what a GUI login sets.
- **B learns late.** A session A started shows up on B only when B next lists zmx, and B's Recent learns of it only when it ends while B is looking.
- **The sweep changes**, and ADR 0004's "launch kills sessions no restored pane points to" gains an exception. A session whose controlling Mac never comes back leaks until B reboots.
- **Two Launchys read each other's files.** `sessions.json` and the search database become an interface between builds, not just Launchy's own saved state.
- **Weaker peers.** The relay is a binary at a fixed path, not a running Launchy, so this is closer to "a list of SSH hosts" than the user asked for.

## User Stories

Stories 1 to 18 of option 01, except that in story 4 the session appears on the desktop when its Launchy next looks, rather than at once.

## Implementation Decisions

- The control label and Take over sequence are as in option 01.
- B's sweep: kill a session labelled `launchy=1` that no pane on B owns, only if its control label is missing or names B. Sessions with no control label were started before this and are B's.
- A's sweep of its own sessions on peers runs when each peer is reachable. It is skipped for a peer that doesn't answer, and when A's saved tabs failed to load.
- The start request carries every claude argument as JSON. The relay builds the hook settings, the folder and the environment on B, and makes the pane folder on B first, so the hook's `cat >` has somewhere to write.
- B's Launchy adopts a session labelled for a peer as a pane with the host set to itself and the controller elsewhere. Its record is rebuilt from the zmx name and the hook file. The prompt it was started with isn't known, so the tab shows the conversation's title once claude sets it.
- Saved state as in option 01.

**Scope and ticket order** (about six tickets)
1. **Spike** (by hand, on B, outside any Claude session): start claude from an SSH login with a throwaway `ZMX_DIR` and check that it is logged in, can read a project folder, and that its hook runs. If it fails, this option is out, and that is a reason to choose option 01.
2. Peers, with the relay reading files (option 01's ticket 1, without the socket).
3. Start a session on another Mac, with the relay creating it, and A's remote pane.
4. B's adoption of peer sessions and the sweep exception, with each Mac sweeping its own sessions on peers.
5. Take over and the frozen screen.
6. Recent and search from B's files.

## Testing Decisions

- As option 01, plus: from an SSH login on B, claude is logged in and works in a folder under Documents (if any project lives there). A session started from A appears on B within a minute. B's launch sweep spares it, and A's sweep kills it once A has no pane for it.

## Out of Scope

As option 01.

## Further Notes

- The risks of option 01 apply, plus the Keychain and file-access unknowns above, which the spike settles.
- Re-propose over option 01 if the running-Launchy channel proves too heavy, and the spike shows claude works from an SSH login.
