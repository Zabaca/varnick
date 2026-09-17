# The Host's one note to itself is where it put each ttyd

Status: accepted, 2026-09-17.

ADR-0007 says the Host persists nothing and rebuilds its actors from git and
zmx at launch. That holds, with one file named here: `.varnick/terminals.json`,
a per-clone, gitignored map from a Session's branch to the port and pid of the
ttyd serving it.

It exists because a ttyd is the one thing a Session is made of that the world
cannot be asked about. A Worktree is in `git worktree list` and a zmx session is
in `zmx ls`, but a ttyd is an ordinary process on a port the Host itself chose
at random and then deliberately let go of, so that a Session outlives the Host
(spec user stories 5 and 6). Without the note, a Restart orphans every terminal
and opens a second one beside it.

Considered: scanning loopback ports for something that speaks ttyd, and reading
the process table for a `ttyd … zmx attach {branch}` command line. Both are
guesses about which process is ours, on a machine the developer also uses; the
second is also the least portable thing in the Host.

What keeps this inside ADR-0007 rather than an exception to it: no Snapshot and
no state name is written, nothing in the file is believed, and nothing in it is
required. At launch every recorded port is checked, an answering one is adopted
and anything else is replaced with a fresh ttyd; a missing or unreadable file
costs a Session its terminal's continuity and nothing more. The Machines are
still rebuilt from the world. This is a note about a process, of the same kind
as a pid, not a record of what the Host was doing.

Consequences: a stale entry for a Session that has been reaped is harmless and
stays until something overwrites it; deleting entries is Reap's to do when Reap
arrives. A Preview shares the Live tree's file, which is correct — it sees the
same Sessions and therefore the same terminals.
