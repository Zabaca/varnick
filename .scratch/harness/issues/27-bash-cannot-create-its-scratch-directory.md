# 27 — Every Bash command fails, because the agent cannot create its scratch directory

**What to build:** An agent running under varnick can run a shell command. Today every one of them fails before it starts.

**Blocked by:** None.

**Status:** ready-for-human — fixed and held by probe 9b. The last box needs a person: a Bash command run in the window, which is what the ticket said would close it and what no test can do.

**Realizes:** no state path.

## What the agent said, unprompted

The first Turn ever run in the application, under a real subscription credential, asked what the agent could see. It answered with a caveat before answering the question:

> One important caveat first: **my Bash tool is broken in this session.** Every command fails before it runs: `EPERM: operation not permitted, mkdir '/private/tmp/claude-501/-Users-uptown-Projects-zabaca-varnick/...'` It can't create its scratch directory under `/private/tmp` — so I can't actually `ls` anything.

It then read `package.json`, `README.md`, `CONTEXT.md` and `CLAUDE.md` directly and produced an accurate account of the repository from those alone. So the agent works; three of its tools do not.

It also noticed the irony itself: *"Fitting, given your own README documents that `/private/tmp` writes get refused under varnick's sandbox policy."* The policy was documented. The consequence — that this makes Bash unusable — was not, by anyone.

## Why

`allowWrite` is exactly two entries: the clone, and the OS per-user temp directory, which on this machine is `/var/folders/vf/…/T`. Claude Code creates a scratch directory under `/tmp` instead — `/private/tmp/claude-<uid>/<project>/<session>` — and `/tmp` is not `os.tmpdir()`. It is not in `allowWrite`, so the `mkdir` is refused, so the tool that needs it never gets to run a command.

This was filed alongside ticket 26, which claimed `Grep` and `Glob` were broken too. **That one was retracted** — those tools worked, and the probe's control was comparing an absolute path against a relative answer. This ticket is the real half: a directory the policy does not name, measured as a refused `mkdir` rather than inferred from a failed assertion.

## The decision

The narrow fix is one path in `allowWrite`, and it is genuinely narrow: `/private/tmp/claude-<uid>/**` is a per-user scratch directory outside the clone, and the policy already grants exactly this for `os.tmpdir()`. It grants no new *kind* of access — it grants the same kind in the place the tool actually looks.

**It does not honour `TMPDIR`, and that was measured rather than inferred.** A run with `TMPDIR=/private/tmp/varnick-tmpdir-test` still created its scratch under `/private/tmp/claude-<uid>/…`; the only thing that landed in `TMPDIR` was an unrelated file from a shell shim. So the free option — point the agent at the temp directory already allowed and change no policy — is not available, and the path is a fixed `/tmp/claude-<uid>` rather than a resolved temp dir.

What must not happen is widening `allowWrite` to `/tmp` wholesale. That is a world-writable directory shared with every other process on the machine, and the agent having free rein there is a different proposition from having its own subdirectory in it.

- [x] Whether Claude Code honours `TMPDIR` is measured and recorded — it does not
- [x] `allowWrite` gains the per-user scratch path and nothing broader — never `/tmp` itself
- [x] The entry is derived from the running uid rather than hardcoded, so it is right in a fresh clone on another machine
- [ ] A Bash command runs end to end under a real Turn, and that is what closes this rather than a unit test
- [x] The boundary probes gain a case for it, so a policy that loses this entry fails something — probe 9b, which also asserts `/private/tmp` itself stays refused and the file never appears

## What this says about the probes

The containment suite runs commands *it* wraps, with `runner()`, and they work — `python3 -c "print(6*7)"` passes in probe 10. What it never did was let the agent's own Bash tool try, because that needs a Session, and the only probe with a Session is probe 6, which skipped for want of a credential from the day it was written.

Two defects were behind that skip. Both were found in the first ten minutes of the product actually running.
