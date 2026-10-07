---
problem: frozen-screen-not-live
title: Follow the session with `zmx tail` over one long-lived channel
summary: A new relay request turns into `zmx tail <name>` on the host, the way `attach` turns into `zmx attach`. The viewing Mac draws the first frame from `screen` and adds what tail sends after it. zmx 0.8.1's tail strips every escape sequence, so this gives a plain-text log of new output, not Claude's screen.
status: rejected
reason: removes every escape sequence, so Claude's redraws become a growing log rather than a screen
---

## Solution

While a card is shown, the viewing Mac holds one SSH channel to a new relay request. The relay checks the session and the asking Mac, then replaces itself with the host's `zmx tail <name>`. The view first draws the snapshot from `screen`, then adds each chunk tail prints.

## Trade-offs

What zmx 0.8.1's source shows (problem, Facts):

- **Read-only.** tail never writes to the session's socket, so it can't type, lead or resize.
- **No first frame.** zmx sends the restored screen only in answer to Init, which tail never sends. It gets only output written after it connects, so the snapshot has to come from `screen`, and output between the two is lost.
- **It strips every escape sequence.** It keeps printable bytes, CR, LF, tab and backspace, and drops cursor moves, erases and colours. Claude redraws its spinner, status line and prompt box in place with cursor moves. Through tail, each redraw is added as new text, so the view becomes a growing log of repeated fragments, without colours, under a screen that no longer matches it.
- **It leaks split sequences.** Its filter starts a new parser for every chunk. A sequence split between two reads of the terminal leaks its tail as text, such as `[38;2;153;153;153m`, and Launchy can't repair it because it only gets text.
- **The leader's resize can't be seen.** Nothing is positioned, so the controller's grid doesn't matter to it and can't be learned from it.
- **It counts as a zmx client** while connected, so the host's "Last controlled on" would need it left out, as for any reader (option 04).
- **Take over and Release close it**, since they detach every client.
- **Little to build:** the relay already turns into zmx for `attach`.

Not usable as the live screen the user asked for. At most it could show a text log of new output beside the frozen screen.

## User Stories

1. As a user at the Mac not in control, I want to see what Claude prints as it works, so that I can follow it without taking over. This option meets that only as text, not as the screen.

## Implementation Decisions

- **Request:** `tail` (session), answered only to a listed Mac, like `screen`. It needs only zmx, so it works with Launchy not running on the host. The relay replaces itself with zmx, with Launchy's zmx environment and `ZMX_SESSION` unset, as `attach` does.
- **Stripping on a stream:** zmx does it, per chunk, and leaks split sequences. Launchy's own mode strip has nothing left to strip.
- **Size:** none. Text is added at the view's width.
- **Battery and bandwidth:** an estimated 0.5–5 KB/s of text while Claude works, almost all of it repeated spinner and status text, and nothing while idle. Measured by step 4 of the spike (option 04, Further Notes).
- **Reconnect and lifecycle:** as option 04: one channel while the card is shown, ended by Take over, Release, the session ending or the link dropping, and started again with a fresh snapshot.
- **Linux:** zmx's tail runs the same on Linux.
- **State and protocol:** no saved state. The new request bumps the protocol version.

## Testing Decisions

- By hand, against a throwaway session only (spike step 4): watch tail's output while Claude works.

## Out of Scope

- Anything that needs the screen: positions, colours, the prompt box.

## Further Notes

- **Not recommended.** It fails wish 1 (the screen, live) and wish 3 (the controller's grid). It is kept on record because the user asked about it, and so it isn't proposed again without a zmx that keeps escape sequences.
- **Verified:** tail's behaviour above, in zmx 0.8.1's source and changelog. **Inferred:** the byte rate.
