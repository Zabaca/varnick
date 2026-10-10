# The card's live screen is pushed as whole snapshots over one channel

While a card is shown, the Mac not in control holds one SSH channel, on its shared connection to the host, to the relay's `watch` request. The relay reads the session's zmx socket, and the host's own Varnick does the same in process for its own card. A reader never sends the socket input, Init or a size, so it can't lead, resize the session or take control. When output arrives, the reader sends a whole snapshot with its grid, at most five a second, and the card draws it at that grid, scaled to fit the pane. Every frame is a whole picture, so nothing garbles, and nothing is sent while Claude is idle or the card isn't shown. We chose this over polling the screen because an idle Claude then costs nothing, and over a raw output stream because zmx 0.8.1 offers no way to line a stream up with a snapshot. The problem and its options are in `docs/problems/frozen-screen-not-live/`; this records option 04.

## Considered Options

- **`zmx tail` (option 01)**: rejected. It strips every escape sequence, so Claude's screen can't be drawn from it.
- **Polling `screen` (option 02)**: not chosen. Every poll pays an SSH session, and the host serializes the screen even while Claude is idle.
- **Claude's output between snapshots (option 03)**: not chosen for now. It is the smoothest, and it is this channel plus output frames, but 0.8.1's snapshots don't line up with the output that follows them. Add it once a zmx with screen-only capture is pinned.
- **Within option 04**: polling the history on the host instead of reading the socket (it serializes five times a second even while Claude is idle); `zmx tail` as the change signal (an extra process per card, and it misses changes that only move the cursor or erase); snapshots taken from Init (a client that sends Init resizes the session and sets off a focus report).

## Consequences

- A long-lived relay channel: a third kind of call in the SSH runner, beside requests and pane terminals. Each shown card holds one channel on the shared connection, beside each attached pane's. The spike ran 14 channels at once on one Tailscale SSH connection with no refusals (the spike of 2026-10-05), so cards and panes can share it. The channel's ssh keeps its input open for its whole life, and a cancel closes it first, so the relay ends at once, then terminates the ssh after 1 s and kills it after 2 s.
- Varnick speaks zmx's socket protocol, which upstream declares frozen, and relies on how 0.8.1 treats a client that never sends Init. A zmx pin bump has to recheck the header, the tags and the history request. That goes beyond ADR 0004's note that a new IPC protocol ends running sessions.
- A reader counts as a zmx client (the spike counted a silent one), so the host keeps a registry of readers and counts clients without them. Otherwise a shown card would turn "Last controlled on" into "Controlled on".
- Take over and Release end readers, since they detach every client; the spike saw `detach` close a silent client within 0.1 s, with the session still listed. A card still showing another Mac in control starts a new reader.
- The grid comes from the session's terminal and follows a resize, in the spike with a client attached and after it detached, so each frame can carry it.
- Killing the ssh on a shared connection doesn't end the remote command until the master next handles traffic (the spike saw 8 to 23 seconds, and 91 once), so the relay writes a blank keep-alive line every five seconds while idle, to notice a closed channel.
- Nothing runs while Claude is idle or the card isn't shown. The reader stops ten seconds after the card stops being shown.
- The relay can now run for as long as a card is shown. It still needs only zmx, so it keeps working while the host's Varnick restarts.
- Nothing on the host's side rules out a Linux host: the reader needs only a Unix socket, polling and a terminal size read.
