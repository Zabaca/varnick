---
problem: sessions-hosted-only-on-macs
title: A small Go relay on the Ryzen speaks the Macs' protocol
summary: A static Go program, kept in this repo and cross-built for Linux, plays the headless host of option 01, with option 01's state folder, lifecycle and installer. The Swift package doesn't change, and the Macs change only where their SSH command looks for the relay. The cost is that the protocol, the frozen screen's preparation, the transcript reader and the live view's reader are written twice, in two languages, and every protocol bump has to change both.
status: rejected
reason: The user chose option 01 on 2026-10-05, a Swift relay that shares the Macs' relay code, so the protocol lives in one language.
---

## Solution

The Ryzen gets a relay written in Go. It answers the same requests, in the same JSON, at the same protocol version as the Macs. Everything option 01 says about a headless host holds here, written in Go instead of shared Swift:
- the install root and its state folder;
- pairing and the peer list;
- starting a session through a pseudo-terminal, the labels, end and release, reconciling, and resuming after a reboot;
- the requests, the Macs' fallback path, and the later `rows` and `watch`.

Its source lives in this repo, in a folder with its own Go module. A Makefile target cross-builds it, and option 01's installer copies it.

## Trade-offs

- **No package split and no Swift toolchain for Linux.** The Swift app is untouched. Go cross-builds a static Linux binary in one command, a few MB (inferred). Go is on the Ryzen (1.26.4) but not on the Macs, so the build Mac needs it installed.
- **The protocol in two languages.**
  - About fifteen request and reply types, kept in step by hand. The version number is the only guard at run time.
  - The next two bumps (the history pull, then the live view) each mean a Swift change, a Go change and a reinstall.
- **The hard-won rules written twice.** A fix on one side doesn't reach the other:
  - the session-name check;
  - relabelling before detaching;
  - `/usr/bin/false` as the attach command;
  - the modes the frozen screen strips, and its 500-line tail;
  - the markers the transcript reader looks for, in Claude's undocumented format, where drift shows as missing search rows rather than as an error;
  - the project scan's skipped folders and depth;
  - agent frontmatter;
  - zmx's listing format;
  - the live view's reader, frames and 200 ms rule.
- **Easier tests.** Go's own tests run anywhere, which Launchy lacks. Request and reply fixtures shared with the Swift side would catch most drift in shape, but not in behaviour.
- **A small binary** that starts quickly.

## User Stories

As option 01.

## Implementation Decisions

Option 01's sections "The headless host", "Starting a session", "Lifecycle with no app", "The requests a headless host answers", "The Macs", "Recent and search", "The live view", "Install and update" and "Saved state" hold as written. What differs:

- **Language and build.**
  - Go, with no cgo, built on a Mac for Linux on x86_64.
  - `attach` replaces itself with zmx through Go's `exec` call, as the Swift relay does with `execve`.
  - The pseudo-terminal that creates a session, and the window-size read for the live view, use Go's Unix system package.
- **The shapes.**
  - Go structs with the Swift side's JSON keys. Unknown fields are ignored.
  - The version and operation are read first, then the asker, before anything else, as the Swift relay does.
- **Fixtures.**
  - A folder of request and reply examples that the Go tests decode and encode again.
  - A change of shape on the Swift side changes the fixtures in the same commit.
  - Without a Swift test target, nothing checks the Swift side against them automatically.
- **Porting rules.** Each shared rule in the list above names the Swift code it copies, so that a change there finds its twin.
- **Not Bun** (see Considered).

**Scope and ticket order:**
1. The Go relay's skeleton: the installer, identity, pairing and hello, and the Macs' second relay path.
2. Sessions on the Ryzen: everything in option 01's ticket 3.
3. `rows`, later.
4. `watch`, ported when the live view's tickets land on the Macs.

## Testing Decisions

- Go's own tests cover:
  - the fixtures;
  - the name check;
  - the end-or-release decision;
  - reconciling by boot id;
  - the frozen screen's stripping, against screens saved from a Mac's relay.
- By hand, option 01's checks.

## Out of Scope

As option 01.

## Further Notes

### Recommendation

Second choice. It is the fallback if spike step 1 shows that Swift's static Linux build doesn't work, or costs more than it saves. The Mac side is the same as option 01's, so choosing between the two can wait for the spike.

### Considered within this option

- **Bun**, the existing fleet tooling's precedent (`bun build --compile --target=bun-linux-x64`). Bun is on both the Air and the Ryzen. Not chosen:
  - Bun can't replace its own process, so every attached pane would keep a Bun process alive as the parent of its zmx client, which has to pass the terminal through untouched.
  - Reading the grid would mean running `stty`.
  - The binary is about 100 MB (inferred).
- **Building on the Ryzen with its own Go.** Not chosen: the build would then come from whatever checkout the Ryzen has, not from the commit the Mac runs.

### Spike

Option 01's spike. Step 1 decides between this option and option 01.
