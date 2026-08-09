# 25 — Mint a subscription token without leaving the window

**What to build:** The setup screen offers to get a subscription token for the developer. They click, they authorise in a browser, and varnick has a token — without them typing a command anywhere.

**Blocked by:** 24. It owns the setup screen and the write path; this adds a second way to fill the same field.

**Status:** fixed.

## Read this before running anything

**Running `claude setup-token` mints a real, live credential** — a token valid for one year — and prints it. It was run once during measurement, its output was captured, and the token ended up in a session transcript. It had to be treated as compromised and rotated.

Nothing in this ticket may be developed by running the real flow and capturing its output into a log, a scratch file, a test fixture, or a terminal whose scrollback is kept. The value is a credential from the moment it exists. Develop against a recorded *shape* — the lines below, with the token replaced — and let the one real run be the human's, at the end, into the real keychain.

## The design below is superseded. This is what was built.

**The mint runs on the host, unwrapped, and everything in this ticket about narrow policies, `allowLocalBinding` and computing a wrapping in a second process is gone.** The developer decided that after the spike, and the reasoning is the ticket's real conclusion rather than a shortcut around it:

`srt` exists to confine *the agent* — a nondeterministic actor that might try to reach things. Minting a token is deterministic application setup with a fixed argv, started by a person clicking a button, with no agent input anywhere in it. That is the same class of work as reading the Keychain, which the Rust host already does. **ADR-0003 now carries a bounded exception** saying exactly what is permitted (one argv, never `query()`, never an SDK entry point), why the `SessionStart`-hook concern is closed by construction, and that the developer chose this after the alternatives were put to them.

What that means for the paragraphs further down: **"Why this is not an ADR-0003 exception" is wrong** — it is one, and it is written down. **"The shape, given those answers" is wrong** — there is no second Node process and no second policy. **The `allowLocalBinding` trade is not taken**; nothing anywhere sets it true, `sandboxPolicyFor` is untouched, and `sandbox-policy.json` is byte-identical before and after because no policy is generated for this at all. The measurements themselves all still stand, and are left below.

### What was built

- **`src-tauri/src/mint.rs`.** `openpty`, then `claude setup-token` with all three descriptors on the terminal, `setsid` so it leads its own process group, and a wide window so the renderer does not wrap what it prints. A plain pipe yields nothing at all — the token is drawn into a terminal UI rather than written to stdout.
- **`CLAUDE_CONFIG_DIR` and the working directory** both point at a directory varnick creates for the run, under the OS temp root, deleted afterwards. This is what closes ADR-0003's stated concern rather than accepting it: the rule exists because a session runs `SessionStart` hooks from the clone's `.claude/settings.json`, which the agent can write — point the command away from the clone and there is no such file to find. Said at the spawn, in the code.
- **`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are removed from the child's environment.** Never hand a credential to the thing minting one.
- **The authorize URL is surfaced in the window**, parsed by endpoint rather than by the sentence above it, and shown as text to copy — a bare `href` in a webview navigates *varnick* rather than a browser.
- **The token is cut from `sk-ant-oat01-` to `Store this token` / `Use this token`, then to the first blank line, then all whitespace is deleted** — the renderer wraps the value mid-string, so a parse that stopped at a newline would store half a credential. The result is checked against `^sk-ant-oat01-[A-Za-z0-9_-]+$` and refused loudly if it does not match.
- **It is stored with ticket 24's `store_credential`.** There is no second keychain writer, and the mint's tests assert the exact bytes reaching that path.
- **`credential.minting`** is the new state, with the URL in context, a card at `#/states`, and `MINT_CREDENTIAL` / `MINT_URL` on the Harness.

### What holds the credential rule

The token is never printed, never logged, never written to a file and never crosses the bridge. `Rendered` — the pty capture — has no `Serialize` and a `Debug` that prints `[redacted]`, the parsed value is a `Secret`, and every failure out of the mint is a `&'static str` tag chosen by a match arm, so there is no `String` on any path for a value to be formatted into. The actor on the Core side takes no input and answers with `void`: unlike a store there is not even a value passing through. No test runs the real flow.

## What was measured

Claude Code v2.1.226, macOS, run under a pty because it writes nothing at all to a plain pipe.

**1. It does not need to open the browser itself — answered, and this is what makes the ticket possible.** It prints, in this order:

```
Opening browser to sign in
Browser didn't open? Use the url below to sign in (c to copy)
<the authorize URL>
Paste code here if prompted >
```

So the launch is an attempt with a fallback, and the fallback is the whole flow: varnick shows the URL and the developer authorises in their own browser.

**Two details that shape the design more than the confinement question does:**

- **It is a local callback, and this was measured wrong once before it was measured right.** The `redirect_uri` in the authorize URL is a *hosted* page on `platform.claude.com`, and the CLI prints "Paste code here if prompted", so the first reading was that the flow is paste-the-code with no local listener. It is not. The hosted page bounces the browser to `http://localhost:<ephemeral>/callback?code=…` — observed as port 53267, so the port is not fixed — and the paste prompt is the fallback for when that fails. The way this was established is worth copying: the flow was started, the process killed before anyone authorised, and the browser then showed `ERR_CONNECTION_REFUSED` against the localhost callback. A refusal proved the listener existed more cleanly than a success would have. **Nothing follows from it now** — the command runs on the host, where binding was never in question — but it is why nobody has to paste anything.
- **The token is printed into a terminal UI, not to stdout.** It arrives wrapped in cursor positioning and colour, split across escape sequences, beside the sentence "Store this token securely. You won't be able to see it again." Capturing it means running a pty and parsing rendered terminal output. **That was the hard part of this ticket**, and it is fragile in a way the confinement never was: a change to that CLI's rendering breaks the parse, and the failure mode is a truncated credential that fails authentication far from its cause. What was built refuses loudly instead — `unreadable-token`, and nothing written.

**2. Which hosts does the flow contact? — Answered.** `claude.com/cai/oauth/authorize` and `platform.claude.com/oauth/code/{callback,success}` are the *developer's browser*. The one the CLI itself calls is **`platform.claude.com/v1/oauth/token`**, read out of the shipped binary's strings. **This no longer touches any allowlist**: the command is not inside `srt`, so no policy mentions it, and `DEFAULT_ALLOWED_HOSTS` stays `api.anthropic.com` and `registry.npmjs.org`.

**3. Does a sandboxed process's local listener work, and can something outside reach it? — Answered, both halves.** Under the shipped policy with `allowLocalBinding: false`, a Python HTTP server binding `127.0.0.1:0` fails with `PermissionError [Errno 1] Operation not permitted`, against a control proving the interpreter runs. That is **probe 10** in `containment.probe.test.ts`, and it stays — it was one line in `sandbox.ts` that nothing held to the kernel, and it guards a channel the allowlist says nothing about. With `allowLocalBinding: true` the same server bound an ephemeral port and an unsandboxed process reached it. That measurement is now unused: nothing sets it true.

**4. Does an `srt` wrapping computed in one process still work when another process spawns it? — Moot.** No wrapping is computed for this command.

**5. What does it write, and where? — Answered by construction.** `CLAUDE_CONFIG_DIR` and the working directory are a varnick-owned temp directory, created for the run and removed when it ends. Whatever the command writes, it writes there.

## What the spike found, and why it changed the plan

A throwaway spike ran `claude setup-token` under a policy of its own. **It did not mint a token, and the reason is worth more than the token would have been.**

The native binary cannot run under any policy that denies `$HOME`:

```
base         exit 1   error: An internal error occurred (EPERM)
noDenyRead   exit 0   2.1.226 (Claude Code)
writeHome    exit 1   EPERM
openNet      exit 1   EPERM
keepHome     exit 1   EPERM      <- denyRead /Users + $HOME alone reproduces it
keepBins     exit 0   2.1.226
keepKeys     exit 0   2.1.226
```

That is `claude --version`, not `setup-token` — so it is nothing to do with OAuth, browsers or listeners. Two things follow:

- **`denyRead` beats `allowRead`.** Adding `~/.local/share/claude/**` to `allowRead` does not lift a path out of a denied root. Neither does hardlinking the binary into the writable root, which was the obvious way to keep the boundary and was tried.
- **It is a different case from ADR-0003's correction.** That correction says `(allow process-exec)` is unconditional, and it was measured on `/usr/bin` system binaries, which execute while unreadable. This binary is a 280MB self-extracting single-file executable — it has to *read itself* — so denying read does deny it, and the earlier finding does not generalise the way its wording suggests.

The remaining way to run it confined would have been a policy for this one command that does not deny the home directory — a far larger widening than `allowLocalBinding`, for a command that is not the agent. That is the trade that was put to the developer, and it is the one they declined in favour of the host. A second spike ran it host-side and minted a real token into the keychain, which is the measurement this implementation is built from.

## Watch for

- **A minted token is a credential and is treated as one from the first byte.** It is not logged, not echoed to the renderer, not written anywhere but the Keychain, and not printed even in a debug path. `security` receives it over stdin, hex-encoded, the way ticket 24 already does.
- **`setup-token` fails in ways this must show rather than swallow** — the developer declines in the browser, the flow times out, the account has no subscription. Each has its own sentence, authored in `packages/harness/src/credentials.ts` and selected by a tag, and none of them quotes what the command printed.
- **No test may run the real flow.** It opens a browser and authenticates a human. The seam is the parse and the spawn's construction; the flow itself is measured once, by hand, and recorded here.

- [x] The two measurements still open are recorded here with what came back
- [x] ~~`claude setup-token` runs wrapped by `srt` under a policy narrower than the agent's~~ — superseded: it runs on the host under ADR-0003's bounded exception. **The agent's policy is byte-identical before and after**, which is still the check that matters and is now trivially true: `sandboxPolicyFor` is untouched and no policy is generated for this command.
- [x] The token reaches the Keychain without entering a Node process, a log, an error, the renderer, or the mirror — and without a pty capture surviving anywhere on disk
- [x] What was captured is checked to look like a token before it is stored, and a parse that came back short says so rather than storing a truncated credential
- [ ] A developer with a subscription gets a working token from the setup screen having run no command — **the one box a human has to tick**, because ticking it means signing in for real. Everything up to the browser is tested; the browser is not.
- [x] Every failure of the flow reaches the screen as a sentence naming what to do
- [x] `CONTEXT.md` gains whatever state this needs, and `#/states` gains its card

Follows the developer's decision that setting up varnick should require no terminal, and their correction that the mint belongs on the host.
