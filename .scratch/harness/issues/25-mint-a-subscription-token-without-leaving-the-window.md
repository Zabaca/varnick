# 25 — Mint a subscription token without leaving the window

**What to build:** The setup screen offers to get a subscription token for the developer. They click, they authorise in a browser, and varnick has a token — without them typing a command anywhere. `claude setup-token` runs **inside `srt`**, so nothing about [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md) moves.

**Blocked by:** 24. It owns the setup screen and the write path; this adds a second way to fill the same field.

**Status:** ready-for-agent for measurements 1 and 3; measurement 2 and the capture problem below are the remaining unknowns. **Measurement 1 is taken and the answer is yes** — see "What was measured".

## Read this before running anything

**Running `claude setup-token` mints a real, live credential** — a token valid for one year — and prints it. It was run once during measurement, its output was captured, and the token ended up in a session transcript. It had to be treated as compromised and rotated.

Nothing in this ticket may be developed by running the real flow and capturing its output into a log, a scratch file, a test fixture, or a terminal whose scrollback is kept. The value is a credential from the moment it exists. Develop against a recorded *shape* — the lines below, with the token replaced — and let the one real run be the human's, at the end, into the real keychain.

**Realizes:** no state path yet. If minting needs a state of its own — it probably does, since it is a long operation that can fail — that is a change to `CONTEXT.md` and the machines, and it is this ticket's to make.

## Why this is not an ADR-0003 exception

The rule is that varnick never spawns a Claude Code process **outside `srt`**. Running `claude setup-token` wrapped is inside, so the rule is satisfied rather than amended. This was nearly recorded as a bounded exception with the process on the host; that draft is not in the repository, and the reason it is not is that "spawn it" was being read as "spawn it unconfined", which it never had to mean.

Confining it is also *stricter* than the agent's own boundary, not looser — see the policy below.

## What was measured

Claude Code v2.1.226, macOS, run under a pty because it writes nothing at all to a plain pipe.

**1. It does not need to open the browser itself — answered, and this is what makes the ticket possible.** It prints, in this order:

```
Opening browser to sign in
Browser didn't open? Use the url below to sign in (c to copy)
<the authorize URL>
Paste code here if prompted >
```

So the launch is an attempt with a fallback, and the fallback is the whole flow: varnick shows the URL, the developer authorises in their own browser — which is outside the Sandbox and always was — and pastes the code back. **Launch Services refusing `open` under the policy is not fatal**, which was the thing that could have killed this outright.

**Two details that shape the design more than the confinement question does:**

- **The flow is paste-the-code, not a local callback.** `redirect_uri` is a hosted callback page that displays a code; the CLI reads it back on stdin. So there is no local HTTP server to run and no port to open inside the Sandbox — one less thing to allow.
- **The token is printed into a terminal UI, not to stdout.** It arrives wrapped in cursor positioning and colour, split across escape sequences, beside the sentence "Store this token securely. You won't be able to see it again." Capturing it means running a pty and parsing rendered terminal output. **That is now the hard part of this ticket**, and it is fragile in a way the confinement never was: a change to that CLI's rendering breaks the parse, and the failure mode is a truncated credential that fails authentication far from its cause. Whatever is built must verify what it captured looks like a token before storing it, and say so plainly when it does not.

**4. What it writes — partly answered.** It says the value cannot be shown again, which means it is not being kept anywhere the developer can retrieve it. Whether it also writes into its own configuration is still unmeasured, and is why `CLAUDE_CONFIG_DIR` must point at a directory varnick owns.

## The remaining measurements

Each of these is a command, not a judgement. Write down what came back.

1. ~~Does it need to open a browser itself?~~ **Answered above: no.**
2. **Which hosts does the flow actually contact?** The authorize URL is on `claude.com` and the callback is on `platform.claude.com`, but both of those are the *developer's browser*, which is outside the Sandbox and needs nothing from the policy. What matters is the host the CLI itself calls to exchange the pasted code for a token, and that has not been observed. Measure it — `nettop`, a proxy, or the CLI's own logging — rather than inferring it from the URL a browser was sent to. `DEFAULT_ALLOWED_HOSTS` is `api.anthropic.com` and `registry.npmjs.org`. If OAuth needs `claude.ai` or `console.anthropic.com`, they go in **this command's** policy and **never** in the agent's. Widening the agent's egress to mint a token would trade a permanent hole for a one-off convenience.
3. **Does an `srt` wrapping computed in one process still work when another process spawns it?** The agent spawn already relies on this — the runtime computes the wrapping, the Rust host performs the spawn (ADR-0008) — but it has only ever been relied on for a policy the wrapping process itself initialized. If `wrapWithSandboxArgv` writes a profile to a temp path, confirm that path outlives the process that made it.
4. **What does it write, and where?** Point `CLAUDE_CONFIG_DIR` at a directory varnick owns for this and nothing else. `allowWrite` for this command is that directory alone — not the clone.

## The shape, given those answers

`SandboxManager.initialize()` is process-wide: one policy per process, and `wrap()` uses whatever was initialized. The runtime already holds the agent's policy, so a second, narrower policy needs a second process. That is not the process-per-call ADR-0008 rejected — that argument was about losing the *agent's* Sandbox between calls, and this establishes a different Sandbox for a different command that runs once.

The credential rule is unchanged and is what makes the shape non-obvious: **the token must never enter a Node process.** So the split is the same one the agent spawn uses — a short-lived Node process computes the wrapping for the narrow policy and answers with argv, env and cwd, carrying no secret; the Rust host spawns `claude setup-token` with that wrapping and captures its output, where the value already belongs. **Not stdout — a pty**, per the measurement above: the token is rendered into a terminal UI and a plain pipe produces nothing at all. `Secret` holds it, the Keychain receives it, and nothing crosses the bridge.

## Watch for

- **The policy for this command is not the agent's policy.** It is its own: the OAuth hosts and nothing else, one writable directory, no clone access. If implementing this makes the agent's policy wider in any way, that is the wrong implementation.
- **A minted token is a credential and is treated as one from the first byte.** It is not logged, not echoed to the renderer, not written anywhere but the Keychain, and not printed even in a debug path. `security` receives it over stdin, hex-encoded, the way `secrets.ts` already does.
- **`setup-token` fails in ways this must show rather than swallow** — the developer declines in the browser, the flow times out, the account has no subscription. Each needs a sentence, and none of them may quote what the command printed.
- **No test may run the real flow.** It opens a browser and authenticates a human. The seam is the wrapping and the capture; the flow itself is measured once, by hand, and recorded here.

- [ ] The two measurements still open are recorded here with what came back
- [ ] `claude setup-token` runs wrapped by `srt` under a policy narrower than the agent's, and the agent's policy is byte-identical before and after
- [ ] The token reaches the Keychain without entering a Node process, a log, an error, the renderer, or the mirror — and without a pty capture surviving anywhere on disk
- [ ] What was captured is checked to look like a token before it is stored, and a parse that came back short says so rather than storing a truncated credential
- [ ] A developer with a subscription gets a working token from the setup screen having run no command
- [ ] Every failure of the flow reaches the screen as a sentence naming what to do
- [ ] `CONTEXT.md` gains whatever state this needs, and `#/states` gains its card

Follows the developer's decision that setting up varnick should require no terminal, and their correction that the mint can run confined.
