# 25 — Mint a subscription token without leaving the window

**What to build:** The setup screen offers to get a subscription token for the developer. They click, they authorise in a browser, and varnick has a token — without them typing a command anywhere. `claude setup-token` runs **inside `srt`**, so nothing about [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md) moves.

**Blocked by:** 24. It owns the setup screen and the write path; this adds a second way to fill the same field.

**Status:** ready-for-agent. Every measurement that decides feasibility is taken and the answer is yes; what remains is measurement 4 (does a wrapping survive being spawned by another process) and the capture problem, which are implementation questions rather than existential ones.

**The developer has accepted the trade** that this command's policy sets `allowLocalBinding: true` where the agent's leaves it `false`. That acceptance is about *this command's* policy only — the agent's is unchanged and the ticket fails if it moves.

**The measurements corrected the ticket twice**, and both corrections are left visible below rather than tidied away. The first draft said the flow could not run confined because it opens a browser; it prints the URL as a fallback, so it can. The second said it was paste-the-code with no local server; it is a local callback on an ephemeral port, and it needs `allowLocalBinding`, which the agent's policy sets to `false`.

## Read this before running anything

**Running `claude setup-token` mints a real, live credential** — a token valid for one year — and prints it. It was run once during measurement, its output was captured, and the token ended up in a session transcript. It had to be treated as compromised and rotated.

Nothing in this ticket may be developed by running the real flow and capturing its output into a log, a scratch file, a test fixture, or a terminal whose scrollback is kept. The value is a credential from the moment it exists. Develop against a recorded *shape* — the lines below, with the token replaced — and let the one real run be the human's, at the end, into the real keychain.

**Realizes:** no state path yet. If minting needs a state of its own — it probably does, since it is a long operation that can fail — that is a change to `CONTEXT.md` and the machines, and it is this ticket's to make.

## Why this is not an ADR-0003 exception

The rule is that varnick never spawns a Claude Code process **outside `srt`**. Running `claude setup-token` wrapped is inside, so the rule is satisfied rather than amended. This was nearly recorded as a bounded exception with the process on the host; that draft is not in the repository, and the reason it is not is that "spawn it" was being read as "spawn it unconfined", which it never had to mean.

**It is not, however, strictly stricter than the agent's boundary, which an earlier draft of this ticket claimed.** The agent's policy sets `allowLocalBinding: false`, and this command cannot work without a local listener — see the measurement below. So its policy is narrower in two dimensions (no clone access, one writable directory, a single allowed host) and wider in exactly one, deliberately, for one short-lived command that is not the agent. That trade is the thing to review, and stating it as "stricter" would have hidden it.

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

- **It is a local callback, and this was measured wrong once before it was measured right.** The `redirect_uri` in the authorize URL is a *hosted* page on `platform.claude.com`, and the CLI prints "Paste code here if prompted", so the first reading was that the flow is paste-the-code with no local listener. It is not. The hosted page bounces the browser to `http://localhost:<ephemeral>/callback?code=…` — observed as port 53267, so the port is not fixed — and the paste prompt is the fallback for when that fails. The way this was established is worth copying: the flow was started, the process killed before anyone authorised, and the browser then showed `ERR_CONNECTION_REFUSED` against the localhost callback. A refusal proved the listener existed more cleanly than a success would have.
- **The token is printed into a terminal UI, not to stdout.** It arrives wrapped in cursor positioning and colour, split across escape sequences, beside the sentence "Store this token securely. You won't be able to see it again." Capturing it means running a pty and parsing rendered terminal output. **That is now the hard part of this ticket**, and it is fragile in a way the confinement never was: a change to that CLI's rendering breaks the parse, and the failure mode is a truncated credential that fails authentication far from its cause. Whatever is built must verify what it captured looks like a token before storing it, and say so plainly when it does not.

**4. What it writes — partly answered.** It says the value cannot be shown again, which means it is not being kept anywhere the developer can retrieve it. Whether it also writes into its own configuration is still unmeasured, and is why `CLAUDE_CONFIG_DIR` must point at a directory varnick owns.

## The remaining measurements

Each of these is a command, not a judgement. Write down what came back.

1. ~~Does it need to open a browser itself?~~ **Answered above: no.**
2. ~~Which hosts does the flow contact?~~ **Answered.** `claude.com/cai/oauth/authorize` and `platform.claude.com/oauth/code/{callback,success}` are the *developer's browser* and need nothing from the policy — the browser was never inside it. The one the CLI itself calls is **`platform.claude.com/v1/oauth/token`**, read out of the shipped binary's strings rather than inferred from what a browser was sent to. That host goes in **this command's** allowlist and **never** in the agent's; `DEFAULT_ALLOWED_HOSTS` stays `api.anthropic.com` and `registry.npmjs.org`. Worth confirming against a real run once, since a string in a binary is evidence of an endpoint and not proof it is the one used.

3. ~~Does a sandboxed process's local listener work, and can something outside reach it?~~ **Answered — both halves, and this is what unblocks the ticket.**

   Under the shipped policy, with `allowLocalBinding: false`, a Python HTTP server binding `127.0.0.1:0` fails with `PermissionError [Errno 1] Operation not permitted`, against a control proving the interpreter itself runs. So the setting does something and the agent genuinely cannot listen. That is now **probe 10** in `containment.probe.test.ts`, because it was one line in `sandbox.ts` that nothing held to the kernel, and it guards a channel the allowlist says nothing about: the allowlist bounds where the agent may reach, not who may reach the agent.

   With the same policy and `allowLocalBinding: true`, the same server bound an ephemeral port (53340 in the run), and an **unsandboxed** process fetched `http://127.0.0.1:<port>/callback` and got its marker back. So the browser reaching inward works, which is exactly the shape of the OAuth callback.
4. **Does an `srt` wrapping computed in one process still work when another process spawns it?** The agent spawn already relies on this — the runtime computes the wrapping, the Rust host performs the spawn (ADR-0008) — but it has only ever been relied on for a policy the wrapping process itself initialized. If `wrapWithSandboxArgv` writes a profile to a temp path, confirm that path outlives the process that made it.
5. **What does it write, and where?** Point `CLAUDE_CONFIG_DIR` at a directory varnick owns for this and nothing else. `allowWrite` for this command is that directory alone — not the clone.

## The shape, given those answers

`SandboxManager.initialize()` is process-wide: one policy per process, and `wrap()` uses whatever was initialized. The runtime already holds the agent's policy, so a second, narrower policy needs a second process. That is not the process-per-call ADR-0008 rejected — that argument was about losing the *agent's* Sandbox between calls, and this establishes a different Sandbox for a different command that runs once.

The credential rule is unchanged and is what makes the shape non-obvious: **the token must never enter a Node process.** So the split is the same one the agent spawn uses — a short-lived Node process computes the wrapping for the narrow policy and answers with argv, env and cwd, carrying no secret; the Rust host spawns `claude setup-token` with that wrapping and captures its output, where the value already belongs. **Not stdout — a pty**, per the measurement above: the token is rendered into a terminal UI and a plain pipe produces nothing at all. `Secret` holds it, the Keychain receives it, and nothing crosses the bridge.

## Watch for

- **The policy for this command is not the agent's policy.** It is its own: `platform.claude.com` and nothing else, one writable directory, no clone access, and `allowLocalBinding: true`. **If implementing this makes the agent's policy wider in any way — the allowlist, or local binding especially — that is the wrong implementation**, and `sandbox-policy.json` being byte-identical before and after is how you prove it did not.
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
