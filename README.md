# varnick

A desktop harness for a coding agent, and a chat that runs inside it. You clone
it, run it, and grow your own workspace inside it by asking the agent for what
you need. The chat is not the destination; it is the thing that builds
everything else.

This is one developer's tool, written in the open. It has no users other than
its author, and nothing here has been deployed or distributed.

Start with [CONTEXT.md](CONTEXT.md) for what the words mean, and
[docs/adr/](docs/adr/) for why the boundaries are where they are.

## First run

You need [bun](https://bun.sh) and, for the desktop app, a Rust toolchain —
Tauri's own [prerequisites](https://tauri.app/start/prerequisites/) are the list.

```
bun install
bun tauri dev
```

That opens the chat. If nothing else on this page were true, one thing would
still be: varnick reads its credential in the desktop host, so the chat only
works from `bun tauri dev`. `bun run dev` gives you the same interface in a
browser with no host behind it, and it says so rather than failing quietly.

The credential is one keychain item, and it is either a Claude subscription
token or an Anthropic API key. **With nothing stored, the window asks for one.**
A first launch opens on a setup screen: pick which of the two you are supplying,
paste it, and varnick writes the keychain item and carries on. Nothing about
that step needs a terminal, and the value goes one way — into the host process
that owns the keychain, never back out, never into the transcript.

**Minting a subscription token is part of that screen too.** Pick "Claude
subscription", press the button, sign in when the browser opens, and varnick has
a token — you never see it and never paste it. What that runs is
`claude setup-token`, on the host rather than inside the Sandbox, which is the
one bounded exception to
[ADR-0003](docs/adr/0003-containment-wraps-the-process-tree.md): a fixed argv, no
session, and a working directory outside this clone so there are no
agent-authored hooks anywhere near it. The token goes from the terminal that
printed it into the keychain without being logged, shown, or crossing into the
window. If the browser does not open, the screen shows the URL to sign in at,
which is what makes the whole thing survivable.

The terminal route still works and is the right one for a machine with no
window — CI has neither a window nor a keychain — and it is what to fall back on
if the mint fails for any reason. For a subscription:

```
claude setup-token
security add-generic-password -s varnick -a claude-oauth-token -w
```

For an API key:

```
security add-generic-password -s varnick -a anthropic-api-key -w
```

Whichever way it got there, varnick works out which kind it is holding from what
it found; there is nothing to declare, and the setup screen's choice of kind
picks the item to *write* rather than recording a preference. Exported
`CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` variables also work. The
keychain wins over the environment, and within either store a subscription wins
over a key — a plan you already pay for should not sit unused while varnick
bills per request. Nothing else is configured.

varnick does not read Claude Code's own credential store. That item holds an
access token that expires in about an hour, so consuming it would mean varnick
implementing OAuth refresh against an item Claude Code is also writing, from a
second process with no lock between them. `claude setup-token` exists for
exactly this, and the boundary is recorded in
[ADR-0011](docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md).

Three routes ship, and they are the same code three ways: `#/designed` is the
chat and is where a launch lands, `#/bare` is the design-free page showing raw
machine state and one button per accepted event, `#/states` is every state of
the chat on one page, driven by the real machines. All three are in the **View**
menu — ⌘1, ⌘2, ⌘3 — because for a long time two of them shipped with no way in:
the bare and states pages each render a nav and the chat renders none, so the
pages that could navigate were exactly the two nobody could reach.

`#/states` addresses one card at a time — `#/states/turn-failed` is the card for
a failed Turn — which is what makes a ticket able to point at a state rather
than at the whole page.

`scripts/clean-clone.sh` clones the repository into a temporary directory and
runs it with a scrubbed environment and a `HOME` that has never held varnick.
It prints what that establishes and what it only approximates; the honest limit
is that it runs on a machine which *has* run varnick, so it is not a
clean-machine result and is not reported as one.

## varnick does not inherit your Claude Code setup

By default the agent varnick starts reads none of your settings, none of your
`CLAUDE.md` files, no MCP servers, no plugins and no hooks, and is handed an
environment with every `CLAUDE*` and `ANTHROPIC_*` variable removed except the
credential. Behaviour that depends on what you happened to export in the
terminal you launched from is behaviour you cannot reproduce and nobody else
can either.

```
VARNICK_INHERIT_CLAUDE_CONFIG=1 bun tauri dev
```

is the way out, and it restores less than it sounds like: the Sandbox denies the
home directory, so `~/.claude` — your user settings, your user `CLAUDE.md`, your
skills, your plugins — stays unreachable either way. What the flag restores is
the clone's own `.claude/` and `.mcp.json`, and your environment. The reasoning,
and why widening the policy to reach the rest is not on offer, is
[ADR-0010](docs/adr/0010-the-agent-is-isolated-from-the-developers-claude-code.md).

## What the Sandbox actually does

varnick's only real claim is a containment claim, so this section is written to
the measurements rather than to the intent. Everything below was measured on
**macOS** (Darwin 25.5, arm64) against a live kernel sandbox, by
`packages/harness/src/containment.probe.test.ts` and
`packages/harness/src/sandbox.boundary.test.ts`. Run `bun test packages` and
they run again. One probe skips without a credential, and what it does not
cover is named below rather than assumed.

The agent's whole process tree runs under
[`@anthropic-ai/sandbox-runtime`](https://github.com/anthropics/sandbox-runtime),
not per shell command. That is what puts `Read`, `Grep` and `Glob` inside the
boundary: they are JavaScript in the agent's own process and never shell out, so
a per-command sandbox never sees them.

Every probe below has a positive control beside it — the same operation
succeeding where the policy allows it. Without one, a broken wrapper and a
working boundary report the same green.

**Measured against the kernel:**

- One file under `$HOME` and outside the clone, asked for four ways from inside
  the real agent entry — `Bash`, and the syscalls behind `Read`, `Grep` and
  `Glob` — is refused four times with `EPERM`. The same four reach that marker
  inside the clone, and the Agent SDK reports itself loaded from within the
  Sandbox, so a denial cannot mean the process never started.
- Your home directory is unreadable, and so is `/Users` above it. Both roots are
  asked for directly: listing `/Users` is refused, and so is `/Users/Shared`,
  which is under no home directory. SSH keys, cloud credentials, and every
  repository stored under a home directory are outside the agent's reach. The
  clone is read back out of that denial. So is everything else the agent can
  read: the filesystem root itself is denied, and a repository kept outside a
  home directory — on `/opt`, `/srv`, `/Volumes`, an external disk — is refused
  a read as well as a write.
- Writes are the other way round: the clone and the OS temp directory are the
  only writable trees. Both are written to in the same run that is refused the
  five paths below. The OS temp directory means `$TMPDIR` — `/var/folders/…` on
  macOS, not `/private/tmp`, and a write into `/private/tmp` is refused.
- Neither keychain on the machine can be opened, though by two different
  mechanisms. The login Keychain is not even in the sandboxed search list,
  because its file lives under the denied home directory. `/Library/Keychains`
  does not, so it is denied on its own line. What was in it when it was still
  readable is in ADR-0003's second correction, and cannot be measured again from
  here now that the directory is denied.
- `api.anthropic.com` and `registry.npmjs.org` are reachable, over working TLS,
  and an unlisted host is not: `example.com` comes back
  `curl: (56) CONNECT tunnel failed, response 403`. The allowlist is strict and
  no ask callback is ever registered, so an unlisted host is a refusal rather
  than a prompt.
- `packages/core/**`, `packages/harness/**`, the root `package.json`, the
  generated `sandbox-policy.json` and a root `vite.config.ts` are each refused a
  write from inside the Sandbox, which is what keeps the agent out of Core and
  away from its own fence. Ordinary Userspace writes succeed in the same run,
  which is the control that makes those five refusals mean something.
- There is no unconfined mode. A clone carrying a policy `srt`'s schema rejects
  raises rather than starting an agent — establishing the Sandbox has several
  ways to fail and no way to degrade.
- The agent process inherits none of your Claude Code environment. The probe
  reports how many `CLAUDE*` and `ANTHROPIC_*` variables the confined process
  was handed — nine, on the run that prompted this — and asserts that isolation
  leaves none of them. The first number varies with the terminal you launched
  from; the second does not.
- A clone whose `sandbox-policy.json` predates one of these denials is contained
  by it on the next launch anyway, with nothing deleted by hand. That was not
  true until it was measured: the keychain deny above shipped, and its own probe
  then failed on the repository that shipped it, because the policy in force was
  the one generated an hour earlier. See below.
- varnick watches the kernel's own deny log and prints a denial the policy did
  not mean to make, on stderr, once per distinct path. On a correct policy you
  see nothing: one `cat` produces three kernel denials, two of which are a
  `sysctl-read` that *every* wrapped command trips and one of which is the home
  directory being refused on purpose, and none of the three is worth a line. The
  case it exists for is the other one — a read of a path nothing denied
  deliberately, which is otherwise `exit 133` and no message at all.

**Not measured, and named rather than assumed:**

- `sandbox-policy.baseline.json` is denied writes for the same reason as the
  policy beside it, and is the one entry on that list no probe writes to. Its
  five neighbours above are measured; this one is the policy's word.
- The Agent SDK's *own* `Read`, `Grep` and `Glob` implementations. The probe
  that drives them opens a real Session and so needs a credential; without one
  it skips with a printed reason, and it skipped on the run this section was
  written from. What stands in its place is the first bullet, which runs the
  same syscalls in the same process tree under the same policy — that is the
  load-bearing measurement, and this one would be confirmation.
- Sibling home directories. `/Users` and `/Users/Shared` are both asked for and
  both refused, but this machine has one home directory, so no probe has reached
  for another person's.

## The policy is yours to edit, and still gets varnick's fixes

`sandbox-policy.json` is generated into the clone on first launch and is meant to
be edited — the boundary is the thing a fork most wants to change. That is why a
strengthening cannot simply overwrite it, and why varnick records what it
generated in `sandbox-policy.baseline.json` beside it. A difference between the
policy and that baseline is **your** edit; a difference between the baseline and
what the generator produces today is **varnick's**. Both are printed on start.

Field by field: what you did not touch takes varnick's current value, so a
denial you never had an opinion about arrives on its own. What you touched and
varnick did not is kept exactly. Where both moved, the **stronger** side wins —
a boundary is never resolved downwards on your behalf, so a narrowing of yours
survives an upgrade and a widening of yours is dropped and reported rather than
kept silently. Machine paths are compared with the clone, home, users root and
temp directory tokenized, so carrying a clone to another laptop or renaming your
home directory rewrites the paths and reports nothing.

Delete the baseline and varnick can no longer tell the two apart; it falls back
to taking the stronger side of every difference and says so.

## Where confinement stops

Read this part before you walk away from an agent running unattended. Each item
is a limit somebody measured, written at the strength the measurement supports.

**A green `bun test packages` is not a measurement of this section.** It means
every probe your machine could run, ran. One of them needs a credential — probe
6, the Agent SDK's own `Read`, `Grep` and `Glob` driven by a real Session — and
on a machine without one it skips, correctly, because a suite that fails on a
fresh clone is a suite people learn to ignore. Whether it has *ever* completed is
recorded in [`packages/harness/probe-attestation.json`](packages/harness/probe-attestation.json);
open it before quoting anything below. `bun run probe` is the command that has no
skip in it and fails when it cannot measure.

- **Reads are deny-by-default, and the allowlist is where they stop.** The
  filesystem root is denied and `filesystem.allowRead` in `sandbox-policy.json`
  is the whole of what the agent can read: the clone, the interpreter, the Agent
  SDK's install tree, the developer toolchain, eleven measured system paths, and
  the two writable trees. Everything else is refused, including a repository kept
  outside a home directory — which was readable in full until ticket 18 and is
  the reason the inversion happened. Read the allowlist rather than this
  paragraph: it is generated for your machine, and it is the boundary.

  Two things it is honest to say about that list. Every entry is load-bearing —
  each was verified by dropping it and watching something fail with the path in
  the message — and several are broad: `/usr`, `/Library` and `/System` are whole
  system trees, so "deny-by-default" bounds what the agent can reach on *your*
  disk, not what it can read about the machine. And the four denied binaries and
  `/Library/Keychains` sit *inside* allowed trees; they stay denied because srt
  re-emits a nested literal deny after the allows. Write one of those denials as
  a glob and it is silently re-opened, which is why they are literal paths.

  Writes are unchanged and remain tighter still: the clone, the OS temp
  directory, and Claude Code's scratch directory, and nothing else.
- **Anything the agent can reach over the network, it can send data to.** The
  allowlist bounds the blast radius; it does not prevent exfiltration. The probe
  showing `api.anthropic.com` answering is the same fact from the other side — a
  request left the Sandbox and a reply came back.
- **Denying a binary read does not stop it running.** Four binaries are
  unreadable — `security`, `osascript`, `open`, `sudo` — and all four are indeed
  refused a read. Three of them execute anyway under the same policy:
  `security help` prints its usage, `osascript -e 'return 6*7'` answers `42`,
  `open --help` fails with its own usage error. Only `sudo` is stopped, and not
  by this list: with all four entries lifted out of a throwaway clone's policy,
  `security` hands back its bytes and `sudo` is refused exactly as before. `sudo`
  is mode `-r-s--x--x`, unreadable to every non-root process on the machine
  before any policy applies. The list is a tripwire, not a boundary, and the
  keychains above are protected by file denials rather than by it. Apple Events
  are separately denied, and that half is now measured rather than reasoned:
  `osascript` still evaluates a script, but an event only a running application
  can answer — asking Finder to count its windows, asking System Events for the
  process list — comes back a connection error, and `open -a Calculator` is
  refused by Launch Services. One trap for whoever re-runs this: AppleScript
  answers a *static* property such as `get version` out of the target's bundle
  without sending an event at all, so that one succeeds and measures nothing.
- **The Sandbox does not protect the clone from the agent.** Everything in
  Userspace is the agent's to rewrite — the write probe uses exactly that as its
  control, and it succeeds. Git is the undo; the Sandbox is not.
- **Code the agent writes reaches the host by being run.** Only the agent's
  process tree is wrapped. The application is the host process and is outside
  it, so code the agent wrote into the clone executes unconfined the moment the
  host runs it. That is the point of the product and cannot be closed without
  abandoning it. The measured edge of it is `packages/userspace/package.json`,
  which stays writable — a `postinstall` added there runs unconfined on your next
  install. ADR-0002 accepts that, because closing it would also stop the agent
  adding an ordinary Userspace dependency. Whether the dev server could itself
  run inside the Sandbox, which would narrow this, has not been checked.
- **That edge is one of several, and this list used to name only the first.**
  `denyWrite` covers `packages/core/**`, `packages/harness/**`, the root
  `package.json`, `vite.config.*`, `sandbox-policy.json` and its baseline.
  Everything else in the clone is writable, and these are the writable files a
  host process later executes: `packages/userspace/package.json`,
  `packages/lint/package.json`, `bun.lock`, `tsconfig.json`, `eslint.config.js`,
  and `scripts/clean-clone.sh` — which this README tells you to run. They are the
  same accepted class as the line above, not a separate defect, but naming one of
  them read as if the list were complete.
- **Your own `claude` in this repo is not confined by any of this.** varnick never
  spawns a Claude Code session outside `srt` ([ADR-0003](docs/adr/0003-containment-wraps-the-process-tree.md)),
  and the agent it does spawn is isolated from your `~/.claude`
  ([ADR-0010](docs/adr/0010-the-agent-is-isolated-from-the-developers-claude-code.md)).
  Neither says anything about the session *you* start in this directory. The
  clone's `.claude/settings.json` is agent-writable, and hooks declared there run
  unconfined in your session, with your permissions. If you run Claude Code in a
  repo an agent has been working in, read that file the way you would read a
  `postinstall`.
- **One claim on this page rests on a probe that has never run.** Everything
  above about `Read`, `Grep` and `Glob` comes from probe 1, which runs those
  syscalls in the agent's own process under the real policy — the load-bearing
  measurement, and it passes on every machine. Probe 6 runs the SDK's *actual*
  tool implementations, in the Claude Code process the SDK starts, and it needs a
  credential; it skipped from the day it was written until somebody went looking.
  What sat behind that skip was not nothing: a defect where every `Bash` command
  the agent ran died at `mkdir` before executing, and a fictional defect that cost
  most of a day. Neither was visible to a green suite. The skip is right — there
  is no honest way to fake a Session, and the sandbox denies local binding and
  every unlisted host precisely so a stub API cannot be reached — so what changed
  is that "has this ever run" is now a committed fact rather than a line of test
  output. Read `probe-attestation.json`, and run `bun run probe` before you rely
  on this bullet.
- **Only macOS is claimed.** Every measurement on this page is Darwin 25.5 on
  arm64. `sandbox-runtime` has bubblewrap and Windows backends; neither has been
  exercised here, so neither is claimed. The probes skip with a printed reason on
  a platform that cannot run them, so a green suite elsewhere is not a
  confinement result.

## Development

```
bun install
bun tauri dev             # the desktop app, which is the one that has a host
bun run dev               # the same interface in a browser, with no host
bun test packages         # unit tests plus the real-kernel boundary probes
bun run probe             # the same probes with no skip in them; needs a credential
bun run drive             # the state-machine driver
bun run typecheck
bun run build
bun run lint              # three import rules — two ADRs and the bundle boundary
cargo test --manifest-path src-tauri/Cargo.toml
cargo build --manifest-path src-tauri/Cargo.toml
scripts/clean-clone.sh    # what a stranger's clone does, as far as one machine can show
```

`cargo build` is on that list because a green `cargo test` is not evidence that
the application builds: it compiles test harnesses and leaves `target/debug`
holding no `varnick` binary, no `.dylib` and no `.a`, so everything that only
happens at the real link — the three crate types the Tauri app is assembled
from — is exercised nowhere else in the loop.

The boundary probes skip rather than fail where the platform, the network or a
missing credential makes one unrunnable, because a suite that is red on every
fresh clone is a suite people stop reading. `bun run probe` is the other side of
that trade: it takes the same probes, refuses to skip any of them, and exits
non-zero when this machine cannot measure — no credential, wrong platform, or a
probe that ran and reached no tool. It ends by checking that a completion was
actually written to `packages/harness/probe-attestation.json`, because probe 6
can exit green having measured nothing at all, and the exit code cannot tell you
which happened. Run it before you trust *Where confinement stops*, and commit the
file it changes: the record is the evidence, and an uncommitted one leaves the
repository still saying nobody has ever run it.
