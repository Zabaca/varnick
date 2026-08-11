# 08 — A band offers the pre-release, and promoting it restarts you onto it

**What to build:** the developer comes back to a window that says a pre-release
is waiting, what version it is, and what changed. One control promotes it:
varnick restarts onto the new build, the conversation resumes where it was, and
the announcement is posted into the transcript so the record says when the
ground moved.

The band is silent when nothing is pending, like the bands that already report
pending Worktrees and finished merges — a permanent slot for the state it is in
almost all the time is how something ends up below the fold. It sits where those
do, above the conversation, because it is the most consequential thing on the
screen and must not be scrollable away from.

Promotion is the developer's, always. The run cuts the pre-release; it never
switches the build under an open window.

**Realizes:** release.idle, release.pending, release.promoting, release.failed

**Blocked by:** 06 — Cut a pre-release from the command line.

**Status:** ready-for-agent

- [ ] A pending pre-release appears in the window with its version and its announcement
- [ ] The band renders nothing when there is no pre-release pending
- [ ] One control promotes it, and it is rendered only when the machine accepts the event
- [ ] Promoting switches the served artifact and restarts varnick onto it
- [ ] The conversation is intact afterwards, restored from the Session mirror
- [ ] The announcement is posted into the transcript, attributed as varnick's own rather than as something the developer or the agent said
- [ ] A promotion that fails leaves the developer on the build they were already running, with the reason on screen and a way to try again
- [ ] The states are named in the machine, carry cards on the states page, and are driven headlessly — including the refusals
