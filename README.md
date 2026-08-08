# varnick

A desktop harness for a coding agent, and a chat that runs inside it. You clone
it, run it, and grow your own workspace inside it by asking the agent for what
you need. The chat is not the destination; it is the thing that builds
everything else.

This is one developer's tool, written in the open. It has no users other than
its author, and nothing here has been deployed or distributed.

Start with [CONTEXT.md](CONTEXT.md) for what the words mean, and
[docs/adr/](docs/adr/) for why the boundaries are where they are.

## What the Sandbox actually does

varnick's only real claim is a containment claim, so this section is written to
the measurements rather than to the intent. Everything below was measured on
**macOS** (Darwin 25.5, arm64) against a live kernel sandbox by
`packages/harness/src/sandbox.boundary.test.ts`. Run `bun test packages` and it
runs again.

The agent's whole process tree runs under
[`@anthropic-ai/sandbox-runtime`](https://github.com/anthropics/sandbox-runtime),
not per shell command — so `Read`, `Grep` and `Glob`, which never shell out, are
covered by construction. There is no unconfined mode: if the policy cannot be
established, the agent does not start.

**Measured against the kernel:**

- Your home directory and every sibling home are unreadable. SSH keys, cloud
  credentials, and every repository that is not the one you launched are outside
  the agent's reach. The clone itself is read back out of that denial, and is
  the one writable tree besides the temp directory.
- Neither keychain on the machine can be opened, though by two different
  mechanisms. The login Keychain is not even in the sandboxed search list,
  because its file lives under the denied home directory. `/Library/Keychains`
  does not, so it is denied on its own line — it holds `System.keychain`, whose
  generic-password items include the Wi-Fi networks the machine has joined.
- `api.anthropic.com` and `registry.npmjs.org` are reachable, over working TLS.
- A clone whose `sandbox-policy.json` predates one of these denials is contained
  by it on the next launch anyway, with nothing deleted by hand. That was not
  true until it was measured: the keychain deny above shipped, and its own probe
  then failed on the repository that shipped it, because the policy in force was
  the one generated an hour earlier. See below.

**Asserted by the policy, but not yet probed against a running kernel:**

- Every other host is denied. The policy is a strict allowlist with no ask
  callback, so an unlisted host is a refusal rather than a prompt — but no probe
  has yet tried to reach one.
- `packages/core/**`, `packages/harness/**`, `vite.config.*`, the root
  `package.json`, the generated `sandbox-policy.json` and the
  `sandbox-policy.baseline.json` beside it are unwritable, which is what keeps
  the agent from widening its own fence.

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

- **Anything the agent can reach over the network, it can send data to.** The
  allowlist bounds the blast radius; it does not prevent exfiltration.
- **Denying a binary read does not stop it running.** Four binaries are
  unreadable — `security`, `osascript`, `open`, `sudo`. Three of them execute
  anyway; only `sudo` is stopped, and that is its own setuid behaviour, not the
  policy. The list is a tripwire, not a boundary, and the keychains above are
  protected by file denials rather than by it. Apple Events are separately
  denied, which is what actually declaws `open` and `osascript`.
- **The Sandbox does not protect the clone from the agent.** Everything in
  Userspace is the agent's to rewrite, and git is the undo.
- **Code the agent writes runs on the host.** Userspace modules load into the
  application process, outside the Sandbox. That is the point of the product and
  cannot be closed without abandoning it. `packages/userspace/package.json`
  stays writable for the same reason, so a `postinstall` added there runs
  unconfined on your next install.
- **Only macOS is claimed.** `sandbox-runtime` has bubblewrap and Windows
  backends; neither has been exercised here, so neither is claimed.

## Development

```
bun install
bun run dev        # the app
bun test packages  # unit tests plus the real-kernel boundary probes
bun run drive      # the state-machine driver
bun run typecheck
```

The boundary probes skip loudly rather than fail on a platform that cannot run
them.
