# 25 — Mint a subscription token without leaving the window

**What to build:** The setup screen offers to get a subscription token for the developer. They click, they authorise in a browser, and varnick has a token — without them typing a command anywhere. `claude setup-token` runs **inside `srt`**, so nothing about [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md) moves.

**Blocked by:** 24. It owns the setup screen and the write path; this adds a second way to fill the same field.

**Status:** blocked — measure first, then build. The four measurements below decide whether this is a small ticket or an impossible one, and none of them has been taken.

**Realizes:** no state path yet. If minting needs a state of its own — it probably does, since it is a long operation that can fail — that is a change to `CONTEXT.md` and the machines, and it is this ticket's to make.

## Why this is not an ADR-0003 exception

The rule is that varnick never spawns a Claude Code process **outside `srt`**. Running `claude setup-token` wrapped is inside, so the rule is satisfied rather than amended. This was nearly recorded as a bounded exception with the process on the host; that draft is not in the repository, and the reason it is not is that "spawn it" was being read as "spawn it unconfined", which it never had to mean.

Confining it is also *stricter* than the agent's own boundary, not looser — see the policy below.

## The four measurements, before any implementation

Each of these is a command, not a judgement. Write down what came back.

1. **Does `claude setup-token` need to open a browser itself, or does it print the URL?** Under the shipped policy `open` is refused by Launch Services and Apple Events are denied — both measured in ADR-0003 — so a flow that depends on launching a browser cannot complete inside `srt`. If it prints a URL, varnick's own window opens it, which is the host opening a URL and involves no Claude Code process at all. **If it can only auto-launch, stop and report** — the ticket needs a different shape and that is a decision, not a workaround.
2. **Which hosts does the flow actually contact?** `DEFAULT_ALLOWED_HOSTS` is `api.anthropic.com` and `registry.npmjs.org`. If OAuth needs `claude.ai` or `console.anthropic.com`, they go in **this command's** policy and **never** in the agent's. Widening the agent's egress to mint a token would trade a permanent hole for a one-off convenience.
3. **Does an `srt` wrapping computed in one process still work when another process spawns it?** The agent spawn already relies on this — the runtime computes the wrapping, the Rust host performs the spawn (ADR-0008) — but it has only ever been relied on for a policy the wrapping process itself initialized. If `wrapWithSandboxArgv` writes a profile to a temp path, confirm that path outlives the process that made it.
4. **What does it write, and where?** Point `CLAUDE_CONFIG_DIR` at a directory varnick owns for this and nothing else. `allowWrite` for this command is that directory alone — not the clone.

## The shape, given those answers

`SandboxManager.initialize()` is process-wide: one policy per process, and `wrap()` uses whatever was initialized. The runtime already holds the agent's policy, so a second, narrower policy needs a second process. That is not the process-per-call ADR-0008 rejected — that argument was about losing the *agent's* Sandbox between calls, and this establishes a different Sandbox for a different command that runs once.

The credential rule is unchanged and is what makes the shape non-obvious: **the token must never enter a Node process.** So the split is the same one the agent spawn uses — a short-lived Node process computes the wrapping for the narrow policy and answers with argv, env and cwd, carrying no secret; the Rust host spawns `claude setup-token` with that wrapping and captures its stdout, where the value already belongs. `Secret` holds it, the Keychain receives it, and nothing crosses the bridge.

## Watch for

- **The policy for this command is not the agent's policy.** It is its own: the OAuth hosts and nothing else, one writable directory, no clone access. If implementing this makes the agent's policy wider in any way, that is the wrong implementation.
- **A minted token is a credential and is treated as one from the first byte.** It is not logged, not echoed to the renderer, not written anywhere but the Keychain, and not printed even in a debug path. `security` receives it over stdin, hex-encoded, the way `secrets.ts` already does.
- **`setup-token` fails in ways this must show rather than swallow** — the developer declines in the browser, the flow times out, the account has no subscription. Each needs a sentence, and none of them may quote what the command printed.
- **No test may run the real flow.** It opens a browser and authenticates a human. The seam is the wrapping and the capture; the flow itself is measured once, by hand, and recorded here.

- [ ] The four measurements are recorded in this ticket with what came back
- [ ] `claude setup-token` runs wrapped by `srt` under a policy narrower than the agent's, and the agent's policy is byte-identical before and after
- [ ] The token reaches the Keychain without entering a Node process, a log, an error, the renderer, or the mirror
- [ ] A developer with a subscription gets a working token from the setup screen having run no command
- [ ] Every failure of the flow reaches the screen as a sentence naming what to do
- [ ] `CONTEXT.md` gains whatever state this needs, and `#/states` gains its card

Follows the developer's decision that setting up varnick should require no terminal, and their correction that the mint can run confined.
