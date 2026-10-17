---
title: Text generation ignores the Claude subscription
description: Hey Varnick's answers, and its decide step whenever Jev doesn't decide, are written by Text generation, which runs only as Gemma 4 E2B on this Mac or on a model server the user runs. The Claude subscription that Varnick exists to run is never used for it, even though its `claude` is logged in on the same Mac for the panes. Every user who wants spoken answers downloads 3.6 GB and holds 2.5 GB, or keeps a server running, and gets a 2-billion-parameter model's sentences.
impact: Hey Varnick can't be turned on until Gemma is downloaded or a server passes its Check. Answers come from a small model whose prompts were cut down to suit it. After ten idle minutes Gemma unloads, so the next spoken request waits while it loads again (1.3 s, plus about 2.8 s of shader setup on the first one after launch). No answer is lost or wrong today. The cost is the setup, the memory and the quality of the answers.
severity: low
evidence: The user's request of 2026-10-10. The code was read on 2026-10-10 at 53e4064, and the help of `claude` 2.1.296 the same day. What one `claude -p` call costs in time is unmeasured; an eval in agent-lab is timing it, and its figures go under "Measured". The figures on what a bare call carries are from zbc's `@zabaca/agent` README (measured on Claude Code 2.1.220 and 2.1.291), not rerun here.
status: closed
---

## What the user asked (2026-10-10)

In short: Settings › Models › Text generation gets a third choice, **Claude Code**, which runs headless `claude -p` on the user's own Claude subscription, and it becomes the default. The subscription is the main thing Varnick supports (its panes run Claude sessions), and Text generation doesn't use it.

## Today

All of this was read in the code at 53e4064 unless it says otherwise.

**Who uses Text generation.** `TextGeneration.generateNow` is the one way in.
- The **answer step** of a spoken request that reads History, Bookmarks or sessions. It gets the request and the rows read, each described by its kind, title, site or folder, date in words ("3 days ago"), and description cut to 300 characters, and for a session its prompts, the paired Macs' too. It writes one or two sentences in at most 96 tokens (144 when the request asks for several).
- The **decide step**, when Jev doesn't decide: the relevance filter is not on TypeSafe, there is no key, or Jev failed or was slow (ADR 0016). It writes one line of JSON in at most 48 tokens.
- Nothing else. A request about the screen is decided and pointed at by Jev alone (Gemma never points), an off-topic request gets a fixed line, and the command line's `--generate` and `--ask` follow the same choice as the app.

**How it picks.** By the interactive rule of `ModelServerState.place`: a server not known to have failed, else this Mac's installed model. A failed server request rests the server for a minute and runs again on this Mac. When nothing can write, Varnick says "Text generation isn't set up." or "The text generation server isn't answering."

**Settings.**
- The Text generation row has a picker, On this Mac | Server, saved as `textGenerationRunOn` (`local` or `server`) and read as `local` when absent. The same type, `ModelRunOn`, serves Search embeddings' picker. `VARNICK_TEXT_GENERATION` overrides the saved choice.
- Hey Varnick can be turned on only once Text generation is ready: Gemma installed, or Server with a Check that passed. With Server, a Gemma that could answer meanwhile doesn't count.
- Hey Varnick is off until the user turns it on (`heyVarnick` reads false when absent), and Text generation has no other consumer, so nothing is written, here or anywhere, before that.

**Time.** From the end of speech to the first sound, the median is 1.81 s (timing lines on the user's machine); for history, bookmark and session requests the answer step is inside that. Deciding on this Mac costs 1 to 2 s (ADR 0016). Gemma loads in 1.3 s, spends about 2.8 s on shader setup on its first reply after launch, and unloads after 10 idle minutes (ADR 0012).

**What leaves the Mac for Text generation.** Nothing with On this Mac. With Server, the request and the rows go to the user's server on the tailnet. ADR 0015 began as "nothing to a cloud model". ADR 0016 (TypeSafe) and ADR 0033 (ElevenLabs) amended it for those providers. No Varnick feature sends rows from History or Bookmarks to Anthropic; Screen access sessions send what they read of the screen.

**How Varnick runs `claude` today** (`ClaudeCommand`, `ClaudeSession`).
- A pane runs `claude` through the account's login shell (`-l -i`), because that is where the shell's startup files put it on the PATH; a Varnick started by launchd doesn't have that PATH. The environment is built from scratch, never inherited.
- Varnick's hooks reach a pane only through `--settings` on its command line: the SessionStart hook (ADR 0001), the turn hooks (ADR 0010) and the work-link hooks (ADR 0020). Each one acts only when `VARNICK_SESSION_FILE` is set. A `claude` started without those settings and without that variable runs none of them. The user's own hooks, and the plugins they have enabled, come from Claude Code's settings files.
- Varnick reads every `.jsonl` under `~/.claude/projects` for session search (ADR 0018), Recent and how recently a project was used. A transcript written by a headless call would be read as a session.

**The `claude` CLI** (the help of 2.1.296, read on 2026-10-10).
- `-p` prints one reply and exits.
- `--bare` skips hooks, plugins and CLAUDE.md, but never reads OAuth or the Keychain, so it can't use the subscription.
- `--safe-mode` turns off CLAUDE.md, installed plugins, hooks and MCP servers, and says auth works normally.
- Also present: `--setting-sources`, `--settings`, `--tools` (`""` for none), `--strict-mcp-config`, `--no-session-persistence`, `--system-prompt`, `--model`, `--plugin-dir`, `--effort`, `--output-format` (`json`, `stream-json`).
- `--thinking disabled` is not in the help. The Agent SDK (0.3.291) passes it to the CLI to turn thinking off (read in the SDK's bundle).
- `claude auth status --json` reports `loggedIn` and `authMethod`.

**What a bare call carries.** From zbc's `@zabaca/agent` README, measured through a proxy; not rerun here.
- An Agent SDK query with its defaults sends 11 tool schemas and every settings source, 23,355 input tokens. The package's `minimalOptions()` brings the same query to 124.
- By default one prompt makes ten outbound requests, among them a second model call to title the session and logs to a third-party collector. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` leaves two, and turning off claude.ai connectors leaves one.
- Loading no settings sources does not stop auto-memory: the user's memory index goes into every request unless auto-memory is turned off in the settings passed.
- From Claude Code 2.1.291 every request carries reminders the engine adds itself: the working folder and OS, the logged-in account's email address, the model, a token counter and the date. A one-line prompt took 487 input tokens with them and 28 without. No setting turns them off; only a plugin drops them.
- With thinking on, "Reply with exactly: OK" spent 93 of its 100 output tokens thinking.
- The full Claude Code system prompt is about 29,000 characters. Plain `claude -p` sends it unless `--system-prompt` replaces it (inferred for the CLI; the SDK sends its own one-line prompt instead).

## Measured

Nothing yet. The eval in agent-lab is timing a call in `@zabaca/agent`'s minimal configuration (`minimalOptions()`), which option 01 uses.

| What | Result |
|---|---|
| A decide-sized prompt (about 400 tokens, estimated), from process start to the reply | unmeasured |
| An answer-sized prompt (about 1,000 tokens, estimated), the same | unmeasured |
| Claude Code's start-up alone, against the API time it reports | unmeasured |
| Gemma on this Mac with the same prompts, warm and cold | unmeasured here |
