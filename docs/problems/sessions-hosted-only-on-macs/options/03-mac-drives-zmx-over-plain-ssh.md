---
problem: sessions-hosted-only-on-macs
title: No relay on the Ryzen; each Mac drives its zmx over plain SSH
summary: Only zmx goes on the Ryzen. The Macs treat it as an SSH host, not a peer, and run every operation themselves as shell commands over SSH, keeping its session records on their own side. This is option 02 of sessions-tied-to-one-mac for a host where that option's main objection, claude signing in from an SSH login, no longer applies. Nothing is built for Linux, but each Mac gains a second way of doing every peer operation, the protocol's version check doesn't cover it, and the accepted live view can't run without a program on the host.
status: rejected
reason: The user chose option 01 on 2026-10-05, a Swift relay that shares the Macs' relay code, so the protocol lives in one language.
---

## Solution

**An SSH host, not a peer.** Settings › Peers gets a second kind of entry: an SSH host, added by address. It has no hello, no id of its own (the Mac makes one up) and no peer list on the host. A Mac in the list is anyone with the user's SSH keys.

**Each operation is a command the Mac runs over the shared SSH connection.** Each one names zmx 0.8.1 by absolute path and sets `ZMX_DIR`:
- **Starting.** The Mac opens a pane running `ssh -t -e none` with a fixed command. The command creates the zmx session with the three labels and runs claude through the account's login shell. The prompt, agent and folder travel base64-encoded and are decoded on the far side, so no user text enters the shell string.
- **Status, the session list, the screen, Take over, release and end** are `zmx ls`, `get`, `set`, `history`, `detach` and `kill`, parsed on the Mac.
- **The conversation** is a `cat` of the hook file at a path the Mac chose for the session.
- **Projects** are a `find` for repos under `~/Projects`, plus the newest transcript per folder. **Agents** are their files, read over SSH and parsed on the Mac.
- **Records.** Each Mac keeps the records of the sessions it started there. The other Mac sees those sessions only through zmx's labels.
- **Search (later).** The Mac lists the Ryzen's transcripts over SSH, copies the changed ones that hold the user's prompts, and reads them with its own transcript reader.

**Why it is viable now.** ADR 0007 passed over SSH straight to a host's zmx for four reasons:
1. claude would start from an SSH login without the GUI session's Keychain. This doesn't hold here: claude on the Ryzen signs in from its credentials file and its settings' token.
2. The host's Launchy would learn of its sessions late, and its sweep would need an exception. This doesn't hold: there is no Launchy on the Ryzen.
3. Two Launchys would read each other's files. This doesn't hold either.
4. It is closer to a list of SSH hosts than to peers. This still holds, but it is what a headless box is.

## Trade-offs

- **Nothing to build for Linux.** zmx is already on the Ryzen, though the existing browser terminal installed it and pins it, not Launchy.
- **A second way of doing every peer operation, inside the Mac app,** branched by kind of peer. That covers start, attach, status, sessions, screen, take over, end, projects, agents, resume, recent and rows. Today each is one request to a relay.
- **No version guard.** The Mac depends on zmx's output format, the remote shell and coreutils. A zmx or shell change shows up as a wrong reading, not as a refused request.
- **The host doesn't decide ending.** The Mac reads the origin label and kills or releases the session itself. `docs/agents/where-it-breaks.md` says to keep that decision on the host. With two Macs acting on labels directly, the decision is made in two places.
- **The paired-Macs-only rule becomes the SSH keys alone.** That is already true of a shell on the box. The prompts in its transcripts go to whichever Mac asks.
- **Two partial views.** The Mac that started a session knows its prompt and folder. The other Mac sees only labels and zmx's listing until Claude sets a title.
- **The live view doesn't fit option 04,** which needs a reader on the host connected to the session's zmx socket. Without a program there, a Mac can only:
  - poll `zmx history` in a remote shell loop, five times a second while the card shows, and also while Claude is idle (option 04 passed over this);
  - or use `zmx tail` (rejected there).

  So either a Ryzen session's live view would differ from a Mac's, or a program goes on the Ryzen after all, which is option 01 or 02.
- **Shell quoting guards user text again,** with base64 doing the work the relay's JSON does now.

## User Stories

As option 01, except:
- story 10: the Ryzen is added as an SSH host, with no build or zmx version from a hello;
- story 11: any Mac with the user's SSH keys can use it;
- story 14: the card updates by polling, not as on a Mac.

## Implementation Decisions

- **A peer kind,** saved with the peer as an optional field. Old entries load as Launchy peers.
- **One place in the Mac for the SSH host's commands,** beside the SSH runner. Every request a Mac sends a peer today is answered there instead, for this kind.
- **The commands are fixed text,** apart from base64 arguments and session names that pass the name check.
- **Where things live on the Ryzen:**
  - zmx at the existing browser terminal's `~/.local/bin/zmx`, with `ZMX_DIR=/tmp/zmx-<uid>`;
  - hook files under a folder the Mac creates first in `~/.launchy`.
- **Lifecycle** as option 01, run by the Mac. Release keeps the label. Nothing on the Ryzen reconciles, so a session that ended by itself is noticed by the Mac whose pane sees its client exit.
- **After a reboot,** the Mac whose restored pane finds the session gone starts it again with `--resume` from its own record. The other Mac can't, since it has no record.

**Scope and ticket order:**
1. The SSH host kind, and adding one.
2. Starting, attaching and Take over.
3. Ending and release.
4. The session list, status and following.
5. Projects and agents.
6. Recent.
7. Search, later.
8. The live view: polling, or a program on the host.

## Testing Decisions

As option 01, plus: a prompt with quotes, `$`, backticks and newlines reaches claude unchanged through the base64 path.

## Out of Scope

As option 01.

## Further Notes

### Recommendation

Not recommended.
- **It puts more into the Macs** than options 01 and 02 put on the Ryzen.
- **It gives up the protocol's version check,** and it moves the end-or-release decision off the host.
- **It can't meet the accepted live view** without a program on the host, and that program would be option 01 or 02.

Re-propose it if the live view is dropped for the Ryzen and nothing else needs a program there.

### Considered within this option

- **A shell-and-jq relay at the fixed path,** speaking the JSON protocol (jq is on the Ryzen). It would leave the Mac unchanged. Not chosen:
  - the protocol would then live in a third language, with no types;
  - the live view's socket reader can't be written in shell.
