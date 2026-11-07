---
problem: sessions-cant-reach-each-other-reliably
title: Option 01 across Macs, with `send` reaching a session in a tab hosted on a paired Mac, over the link the Macs already have
summary: Built on option 01. A pane id that `board_read` gives for a session on a paired Mac is a valid `to`. This Mac's Varnick sends the paired Mac one new request over the SSH link the Macs already use, and that Mac's Varnick applies option 01's checks and pushes the text into its session, which answers the same way back. The receiver also sees which Mac the sender is on. A second switch under option 01's, Also between my Macs, lists each paired Mac as ready, needing approval on that Mac, or on an older Varnick (with Update); turning it on puts a notice on each other Mac that opens the same checklist there, since the password must be typed on that Mac. A Mac that isn't ready is skipped, and sends to it say why. It needs both Macs on the same build (a protocol change). Headless hosts and the phone stay out.
status: accepted
---

## Solution

Everything in option 01 holds; `send` also reaches a session hosted on a paired Mac.

**Setup: a second switch** (the user's design of 2026-11-07). Under Messages between sessions in Settings › Claude, a switch **Also between my Macs**, which needs the first on. Below it, one row per paired Mac (headless hosts aren't listed):

- **Ready:** that Mac's own Messages between sessions and Also between my Macs are on and its checklist passes.
- **Needs approval on that Mac:** anything else on that Mac, with its first failing row's words. Approval can't be done from here, since the administrator password is typed on that Mac.
- **Older Varnick, Update it:** that Mac speaks an older protocol; the button is the Upgrade a paired Mac already offers (ADR 0013).
- **Not answering:** asleep or off the network, as the Peers list says.

**Turning it on asks the other Macs.** Each paired Mac that isn't ready gets a notice in its Varnick, in its menu bar menu, saying which Mac asked; choosing it opens the same checklist there, Also between my Macs included. The notice goes when the other Mac's checklist passes or the user there dismisses it. A Mac that doesn't answer is asked when it next does.

**Both ends opt in.** A Mac takes messages from paired Macs only while its own Also between my Macs is on. A Mac that isn't ready is skipped: the rest work, and a `send` to a session on it says why ("that Mac hasn't approved messages yet: its Varnick shows how"). Turning the switch off stops sends to and from other Macs at once; messages on this Mac go on.

**What it takes.** The same `to`: a pane id `board_read` lists for a session in a tab "on" another Mac, which the session already gets today, or the `from` of a message that came from one. `opener` reaches a paired Mac when `tab_open` opened the tab there (not possible today: `tab_open` opens on this Mac only), so in practice it stays on one Mac.

**What travels.** One new request from this Mac's Varnick to the host of the target's tab, over the paired Macs' existing SSH link (the connection is reused for 10 minutes, so a warm send costs one command): the target pane, the sender's pane id, project and Mac, whether the sender was started skipping permission checks, and the text. The host's relay accepts it only from a Mac it lists, as it does every request but a hello, and refuses it from a device. The host's Varnick does what option 01's does for its own panes: the target's kind, state and receiving, the skip rule, the queue, and an answer with the receiver's turn, which this Mac relays to the sender.

**What the receiver sees.** As option 01, plus `from_mac`, the sending Mac's name as the board shows it. `from` is the sender's id in the receiver's own table, which knows the paired Mac's tabs from its board, so the answer goes back the same way.

**Where it goes.** To the Mac that hosts the tab, where the session runs, whichever Mac or device is watching or controlling it (ADR 0034). A view here of another Mac's tab is never the target.

**What is refused, in addition to option 01's refusals:** a paired Mac that doesn't answer ("nothing was sent", never held for later), one on another build (the protocol check's words, which say to upgrade both), a host that isn't ready (its row's reason), and either switch off on either Mac. A headless host's session is refused: its server lists `notify` alone.

**The rate cap and the skip rule** count across Macs: the cap is the sending pane's, kept on the sending Mac; the skip rule is decided by the host from what the request says of the sender.

## Trade-offs

- **Work spread across Macs can be coordinated by the sessions,** with the same tool and the same answers.
- **A protocol change.** Both Macs must run the same build; until the other Mac is upgraded, every request between them is refused, as for any protocol change.
- **Each Mac needs its own approval,** typed on that Mac, and its own Claude Code with channels on; the notice brings the checklist to it, so the user does it there once.
- **Both ends opt in,** so turning it on here never opens another Mac's sessions to messages by itself.
- **The reach grows.** A session on one Mac can steer a session on another; the skip rule still holds, and pairing is already full trust between the user's Macs, but a session misled on one Mac now reaches every paired Mac's skipping sessions.
- **Slower and less certain than on one Mac.** One SSH command per message (unmeasured: a warm connection should be well under a second), and a Mac asleep or off the network refuses.
- **The message crosses the user's own link,** SSH between the user's Macs; nothing goes through a third party but Anthropic, with the receiving session.

## User Stories

1. As a lead session on the laptop, I want to send work to a session on the desktop by the id the board gave me, so that I can split work across the user's Macs.
2. As a session on the desktop, I want to answer a message from the laptop with `send` to its `from`, so that the result gets back without the user.
3. As a receiving session, I want to know which Mac the sender is on, so that I don't assume its files are mine.
4. As a sender, I want a clear refusal when the other Mac is asleep, unreachable, on another build or not approved, so that I don't wait for an answer that won't come.
5. As the user, I want the skip rule to hold across Macs, so that pairing doesn't widen what an asking session can steer.
6. As the user, I want a message to reach the Mac where the session runs, whoever is watching it, so that controlling a tab from elsewhere doesn't change where it lands.
7. As the user, I want the phone kept out of this, so that a listed device can't push text into sessions this way.
8. As the user, I want one switch that shows which of my Macs are ready and why the others aren't, so that I know what to fix where.
9. As the user, I want the other Mac to show me the same checklist when I turn this on, so that I approve it there without hunting for the setting.
10. As the user, I want a Mac on an older Varnick to offer Update, so that the fix is one press.
11. As the user, I want a Mac that isn't ready to be skipped rather than to stop everything, so that the Macs that are ready work.
12. As the user, I want each Mac to accept messages from other Macs only once I've turned it on there, so that one Mac can't open another by itself.

## Implementation Decisions

- **One new peer request,** Macs only (refused to a device by the relay's existing list), forwarded by the relay to the app as `start` is; protocol 34 becomes 35.
- **Each Mac's readiness for messages from other Macs** travels with what Macs already ask each other, so the rows need no request of their own: whether both switches are on and the checklist passes, and the first failing row's words.
- **The ask** is one more Mac-only request carrying the asking Mac's name; the receiving Mac keeps one notice per asking Mac until its checklist passes or it is dismissed.
- **The host answers with option 01's refusals** and the receiver's turn; the asking Mac turns the reply into `send`'s answer.
- **The sender's facts travel in the request** (pane id, project, Mac, started skipping); the host trusts them as it trusts a listed Mac's every request.
- **The answer** to a sender for a waiting receiver waits as option 01's does, inside the relay's time limit for a request.
- **A request's size:** 20,000 bytes of text, base64-encoded in one command argument, well under the 120,000 bytes the phone page's relay allows itself; the Macs' own path has no cap of its own in the code read (unverified how large an argument SSH and the shell take).
- **Docs:** where-it-breaks' Peers entry gets the request and the protocol; the privacy doc says messages cross the paired Macs' link.

## Testing Decisions

- **The pure parts** (the request's shape and its refusals) join option 01's check table.
- **The pure parts** also cover each row's decision from a paired Mac's reported state.
- **By hand,** after both Macs run the build and are restarted: turning Also between my Macs on shows the other Mac as needing approval and puts the notice there; the notice opens the checklist; after it passes there, the row here turns ready; with the other Mac on an older build, the row offers Update; from a session on one Mac, `send` to a session the board lists on the other; it starts a turn there and its answer arrives back; a send to a tab hosted on the other Mac but controlled from this one lands on the other Mac; with the other Mac on an older build, the refusal says to upgrade; with its policy entry removed, it says so; a send to a headless host's session is refused.

## Out of Scope

Headless hosts (their sessions' server lists `notify` alone, and Linux keeps machine policy elsewhere), the phone sending, `tab_open` on another Mac, and holding a message for a Mac that is asleep.

## Further Notes

- **Verified in the code at 2f6ddf2:** the SSH relay's one request per command, the 10-minute reused connection, the listed-Mac gate, the device refusals, protocol 34 and its mismatch refusal; `board_read` lists paired Macs' sessions with ids.
- **Unverified:** the time a message takes between Macs; the largest argument the Macs' path carries.
- **Steps that need the user:** the other Mac upgraded to the build (the row's Update) and restarted; the checklist there from the notice (the password once on that Mac); a hand test across both (about 30 minutes).
- **Size, in agent time:** about 2.5 to 3 hours of building after option 01 (the request, the second switch, the rows, the notice and the ask), 30 to 45 minutes of review, plus the user's steps.
- **Decided by the user (2026-11-07):** accepted, to be built now with option 01, not later.
- **Build order:** on its own branch, from main once option 01 has merged (option 01's Further Notes say why). Option 01 and this one together: about 8 to 9.5 hours of building and 1.5 to 2 hours of review and fix rounds, plus the user's steps on both Macs.
- **Assumption:** the notice lives in the menu bar menu, where Varnick's other notices are, and is not a macOS notification, as they are not.
- **Depends on** option 01 (or 03, whose delivery it shares).
