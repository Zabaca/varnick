# 10 — ADR: Userspace shares Core's realm

**What to build:** a written record of a limit the codebase currently implies is
covered when it is not, so that whoever next reasons about the Core/Userspace
boundary starts from what is true.

ADR-0004 gives Userspace **fault** isolation: a module that does not compile
fails at its own dynamic import and becomes a failed Surface rather than a dead
application, enforced by a lint rule. That is a crash boundary and it holds.

What it does not give is privilege isolation. A Surface is a component in Core's
webview — same origin, same realm, same globals — and the bridge to the host is
reached through a global. Nothing distinguishes a call made by Core's machines
from one made by a Surface, and nothing can, because they are the same realm
invoking the same command. The guard that keeps a merge behind an open diff is a
guard on Core's machines, not on the bridge.

Under the current threat model this reaches nothing: no answer on that bridge
returns a Credential. The ADR should say that plainly, and say equally plainly
that it is a property of today's route list rather than of the design — a future
route that returns something is what turns this from a limit into a hole.

No code. This is the one finding from the design work with no change to attach
itself to, which is exactly why it needs writing down.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] An ADR records that Userspace has fault isolation and not privilege isolation, and distinguishes the two
- [x] It states what is reachable from a Surface today and what that does and does not expose
- [x] It names why a same-realm dynamic import cannot provide a trust boundary, so the next attempt is not another lint rule
- [x] It names what closing it would take — a separate origin or a worker, with the bridge mediated — without proposing that it be done now
- [x] It states the condition that would make closing it urgent: a bridge route that returns something worth having
- [x] ADR-0004 and the Core/Userspace entries in CONTEXT.md link to it, so the containment claim is not read as broader than it is
