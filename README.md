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

The credential is one keychain item, and the app names the command if it is
missing:

```
security add-generic-password -s varnick -a anthropic-api-key -w
```

An exported `ANTHROPIC_API_KEY` also works; the keychain wins when both answer.
Nothing else is configured, and there is nothing to fill in on first launch —
an empty chat is the first frame, and anything that went wrong is one sentence
naming what to do about it.

Three routes ship, and they are the same code three ways: `#/designed` is the
chat and is where a launch lands, `#/bare` is the design-free page showing raw
machine state and one button per accepted event, `#/states` is every state of
the chat on one page, driven by the real machines.

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
- Your home directory is unreadable, and so is `/Users` above it. SSH keys,
  cloud credentials, and every repository stored under a home directory are
  outside the agent's reach. The clone is read back out of that denial. Reads
  are allow-by-default, so this is a statement about those roots and not about
  the whole filesystem — see *Where confinement stops*.
- Writes are the other way round: the clone and the OS temp directory are the
  only writable trees. A write to a directory outside both is refused.
- Neither keychain on the machine can be opened, though by two different
  mechanisms. The login Keychain is not even in the sandboxed search list,
  because its file lives under the denied home directory. `/Library/Keychains`
  does not, so it is denied on its own line — it holds `System.keychain`, whose
  generic-password items include the Wi-Fi networks the machine has joined.
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
- Sibling home directories. `/Users` is denied as a whole, but this machine has
  one home directory, so no probe has read from another.

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

- **Reads are allow-by-default; only the listed roots are denied.** The denied
  reads are `/Users`, your home inside it, `/Library/Keychains`, and four
  binaries. Everything else on the filesystem stays readable — `/etc`, `/usr`,
  and, measurably, a git repository kept somewhere other than a home directory,
  which the agent can read in full. If your work lives outside `/Users`, the
  boundary described above does not cover it, and the fix is to add the path to
  `denyRead` yourself. Writes are the opposite and much tighter: the clone and
  the OS temp directory, and nothing else.
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
  are separately denied, which is what actually declaws `open` and `osascript`.
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
bun run drive             # the state-machine driver
bun run typecheck
bun run build
cargo test --manifest-path src-tauri/Cargo.toml
scripts/clean-clone.sh    # what a stranger's clone does, as far as one machine can show
```

The boundary probes skip loudly rather than fail on a platform that cannot run
them.
