---
problem: text-generation-ignores-the-claude-subscription
title: Claude Code writes Text generation's text on the user's subscription, through Varnick's bundled Bun, by default, with this Mac's Gemma as the fallback
summary: Settings › Models › Text generation gains a third choice, Claude Code, and it becomes the default for new installs. Each text Varnick asks for goes to the text helper. That is a copy of `bun` shipped in Varnick.app, running `agent.js`, which `bun build` makes from TypeScript that calls zbc's `@zabaca/agent` (`run` with `minimalOptions()`). The helper drives the user's own `claude`, logged in with their subscription. The call uses Claude Haiku, with no tools, none of the user's settings, hooks, plugins, MCP servers, CLAUDE.md or memory, Claude Code's reminders dropped, no transcript saved, and one request to Anthropic, and the text streams back as it is written. When `claude` is missing, logged out, fails or is slow, this Mac's Gemma writes the text if it is installed. With Hey Varnick on, what the user asks and the rows read go to Anthropic. Hey Varnick is off by default and its detail says this, so turning it on is the consent. Installs already answering with Gemma keep On this Mac.
status: accepted
---

## Solution

Settings › Models › **Text generation** gets a three-way picker: **Claude Code | On this Mac | Server**. Claude Code is the default for an install that never chose.

With Claude Code, each text Varnick asks for goes to **the text helper**. Today that means a spoken request's answer, and its decide step when Jev doesn't decide. The helper has two parts:

- **`bun`**, a pinned copy of Bun shipped in Varnick.app's `Contents/Helpers`. It is signed with Varnick's Developer ID and the hardened runtime, with one entitlement, `allow-jit`.
- **`agent.js`**, in `Contents/Resources`, one file of about 1.3 MB. `bun build` makes it from a small TypeScript entry in this repository, so `@zabaca/agent` and the Agent SDK are inside it and no `node_modules` is needed at run time. zbc's `mods/reminders` folder ships beside it as real files.

Varnick runs `bun --no-env-file` on `agent.js`. `make build` fetches the pinned Bun, as it fetches zmx, and uses the same binary to build `agent.js` and to ship. Nothing has to be installed to run Varnick.

The entry calls `@zabaca/agent`'s `run(prompt, minimalOptions())`, the zbc package whose README measures what each of its levers stops:

- no tools and no MCP servers;
- no settings sources, so none of the user's hooks, plugins, skills or CLAUDE.md;
- auto-memory and claude.ai connectors off;
- thinking off;
- one request to Anthropic, with no session-title call and no third-party logs;
- Claude Code's own reminders dropped by the package's filter module.

To those levers Varnick adds five things. The user's own `claude` is the executable, so the call runs on their subscription login. No session is saved. The working folder is an empty one of Varnick's. Partial messages are on, so the text comes back as it is written. The reminders filter is passed by its real path.

The prompts and the clean-up stay Varnick's, as they do for a server (ADR 0014); Claude Code only computes. Varnick talks to the helper in lines of JSON on its standard input and output. In this first cut there is one helper process per request. Varnick starts it with an environment built from a short allowlist, so nothing ties the call to a pane and Varnick's own hooks never see it.

When Claude Code can't answer, the text is written by **this Mac's Gemma**, if it is installed. That covers `claude` not found, not logged in, offline, at the plan's usage limit, an error, or slower than the deadline. This is the rule a server has today, and the user's rule from ElevenLabs: fall back to the local thing. A failure rests Claude Code for a minute, so the next request goes straight to Gemma. Gemma becomes optional. A **Fallback on this Mac** row under Claude Code offers its download, and Hey Varnick no longer needs it to be turned on.

The default sends nothing by itself. Text generation's only consumer is Hey Varnick, which is off until the user turns it on. Its detail, and the Claude Code row's, name what goes to Anthropic. Installs that already answer with Gemma keep On this Mac: `local` is stored once for them at the first launch of this build.

## Trade-offs

- **The subscription does the writing.** No 3.6 GB download and no 2.5 GB in memory for Hey Varnick. The answers come from Claude Haiku rather than a 2-billion-parameter model, which should be better worded (not compared yet).
- **What the user says and the rows read go to Anthropic,** with Claude Code chosen and Hey Varnick on. Session prompts and folders came from sessions that already ran on Anthropic under the same account. History and bookmark titles, sites and descriptions never went to Anthropic through Varnick before, Screen access aside. A default that sends data off the Mac is new for Varnick. It rests on Hey Varnick being off by default and naming Anthropic where it is turned on, and on keeping existing Gemma users where they are.
- **The levers come with zbc and move with it.** A lever zbc learns later reaches Varnick through a version bump, not by copying flags by hand (option 02). The reminders filter is the one zbc's own live check runs.
- **The Agent SDK drives a `claude` it didn't ship with.** The SDK speaks a control protocol to the CLI it bundles. Here it drives the user's `claude`, which updates itself. A mismatch makes every call fail into the fallback until Varnick's pins move. The row and the timing line say so.
- **Time is unmeasured.** Each call pays for starting `bun`, loading `agent.js`, starting `claude`, then the network and the model. Gemma pays nothing for warm text, but 1.3 to 4 s after 10 idle minutes, which is often the case for Hey Varnick. The eval's figures decide the deadline, and whether the helper stays warm (still open, below).
- **The text streams.** Speech could start at the first sentence. This option still speaks the whole answer as today; speaking early is a follow-up the protocol already allows.
- **A bigger app, a new build step and one entitlement.**
  - `bun` adds 63.1 MB to Varnick.app, and `agent.js` about 1.3 MB.
  - `bun` needs `com.apple.security.cs.allow-jit` under the hardened runtime, and nothing more (the signing spike, below).
  - Building needs Bun, which the Makefile fetches pinned, as it fetches zmx.
- **The same Bun can later run custom apps and the Phone page,** which today need the user to install Bun (ADR 0005). That is a follow-up, not this option.
- **The Agent SDK's licence** is "all rights reserved, use subject to Anthropic's legal agreements". The user's decision: build now, and read those agreements before the first release that ships the SDK. Option 02 is the way back if they don't allow it.
- **Two calls on Jev's failure path.** When Jev doesn't decide, Claude Code writes the decide step too, as a server does today. That is a second call, made during the hold.
- **The plan's usage limits are shared with the panes.** Haiku calls are small, but they count. At the limit every call fails and Gemma answers, if it is there.
- **It needs the network.** Offline, the call fails and Gemma answers. That a failed connection ends the call before the deadline is inferred.
- **The account goes with each call.** The account's token, and its device and account ids in metadata, go with every call (zbc's README). That is the same as for the panes.

## User Stories

1. As a Varnick user, I want Hey Varnick's answers written by my Claude subscription, so that I don't download or hold a 3.6 GB model for it.
2. As a new Varnick user with `claude` logged in, I want Hey Varnick to work as soon as I turn it on, with no model to download and nothing else to install.
3. As a Varnick user, I want Settings to tell me plainly, where I turn Hey Varnick on and where I choose Claude Code, that what I say and the results it reads go to Anthropic.
4. As a Varnick user who already answers with Gemma, I want an upgrade to leave me on On this Mac until I choose otherwise.
5. As a Varnick user, I want an answer from this Mac's Gemma when Claude Code is missing, logged out, offline, at its limit or slow, so that I still get an answer.
6. As a Varnick user, I want to download Gemma as a fallback while Claude Code stays my choice.
7. As a Varnick user, I want Settings to say when `claude` can't be found or isn't logged in, and to check that Claude Code answers and how fast.
8. As a Varnick user, I want these calls never to appear as Claude sessions: not on the board, not in Recent, not in session search.
9. As a Varnick user, I want my own hooks, plugins, CLAUDE.md and memory kept out of these calls, and a project's `.env` too, so that my notes and secrets don't go with a spoken request and nothing of mine runs on it.
10. As a Varnick user, I want my plan billed, not an API key that happens to be in Varnick's environment.
11. As a Varnick user, I want a failed or slow Claude Code to cost me one wait at most, not one on every request.
12. As a Varnick user, I want turning Hey Varnick off, or saying more, to stop a call under way at once, with no `bun` or `claude` left running.
13. As a maintainer, I want `make build` to fetch a pinned Bun, build `agent.js` and sign `bun`, with nothing to install by hand.
14. As a maintainer, I want `@zabaca/agent`, the Agent SDK and Bun pinned exactly, so that a build today and next month send the same request.
15. As a maintainer, I want `--generate` and `--ask` to run through the helper, and to split its time from the API's, so that the deadline and a warm helper can be decided from figures.

## Implementation Decisions

**Decided by the user (2026-10-10)**
- A third choice for Text generation, Claude Code, on the user's subscription.
- It is the default for new installs only. With no saved choice it is Claude Code. With Hey Varnick on or Gemma installed, `local` is stored once.
- Fallback to the local thing: this Mac's Gemma.
- **The runtime is plain bundled Bun, not a compiled helper:**
  - a copy of `bun` in `Contents/Helpers`;
  - an `agent.js` made by `bun build` (no `--compile`) in `Contents/Resources`;
  - `mods/reminders` beside it as real files;
  - run as `bun --no-env-file` on `agent.js`.
- The entry calls `@zabaca/agent`'s `run(prompt, minimalOptions())` with the user's own `claude` as the executable, and streams text as it comes.
- The model is pinned to Claude Haiku 5.5 (`claude-haiku-5-5`).
- The reminders filter is zbc's own module, keeping nothing.
- Claude Code also writes the decide step on Jev's failure path.
- No `ANTHROPIC_API_KEY` in the helper's environment.
- Build now, and read Anthropic's agreements before the first release that ships the SDK; option 02 is the way back.

**The signing spike (2026-10-10, Bun 1.3.14, SDK 0.3.291, kept on its own branch, not merged)**
- Signed with the Developer ID, `-o runtime`, `--timestamp` and the entitlement `com.apple.security.cs.allow-jit` alone, `bun` and `agent.js` ran inside a throwaway app. It was notarized (Accepted), stapled, and `spctl` called it a Notarized Developer ID. A quarantined copy ran.
- **`allow-jit` is required, not just faster.** Without it the hardened runtime refuses JSC its JIT memory. JSC falls back to the interpreter (about twice as slow), takes away `SharedArrayBuffer`, and the SDK fails at import.
- **The other four entitlements Bun's own binary carries are not needed:** `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `allow-dyld-environment-variables` and `disable-library-validation`. Don't add them.
- `pathToClaudeCodeExecutable` is honoured. The SDK never looks for its own platform binary, extracts nothing, needs no Node or `cli.js`, and writes nothing beside itself, so the bundle's signature still verifies after runs.

**The helper's source and build**
- **Source.** A top-level folder beside `PhonePage/` (for example `TextHelper/`) holds a `package.json`, a committed `bun.lock` and one entry file of a few dozen lines.
- **Pins.**
  - `@zabaca/agent` is pinned at an exact version, 0.2.0 today.
  - The Agent SDK is a direct dependency at an exact version too, 0.3.291 today. `@zabaca/agent` allows `^0.3.291`, and the SDK's protocol to `claude` is what can drift.
  - Packages install with the frozen lockfile.
  - The SDK's optional native Claude Code packages (226 MB for macOS arm64) are never used. The install leaves them out where Bun allows it (unverified).
- **Bun is pinned like zmx.** The Makefile fetches one Bun release, 1.3.14 as the spike used, by version and SHA-256 into `.build`. The same binary builds `agent.js` and ships, so the pin is both the build tool and the runtime, whatever Bun the machine has.
- **`make build`:**
  - installs the packages, then runs `bun build` on the entry for Bun as the target, into one `agent.js` in the resource folder (beside the binary in a checkout build);
  - copies `mods/reminders` from the pinned `@zabaca/agent` beside it;
  - puts the signed `bun` beside the binary, as zmx is put.
  - Each is written by rename, so a request during a build never reads half a file.
  - Rebuilt when the source, the lockfile or the Bun pin changes, as the zmx and metallib stamps work.
- **Signing `bun`:**
  - with the identity zmx gets, `-o runtime`, an identifier of its own (for example `com.zabaca.varnick.bun`), and an entitlements file holding `com.apple.security.cs.allow-jit` and nothing else;
  - that file follows `Varnick.entitlements`' rule, with a comment naming the failure without it (the SDK's `SharedArrayBuffer` error);
  - the dev build signs with `--timestamp=none`, as zmx is; a release needs a secure timestamp (`--timestamp`).
  - `agent.js` and the filter folder are resources the bundle's signature covers.
- **`app-bundle`** puts `bun` in `Contents/Helpers`, and `agent.js` and `mods/reminders` in `Contents/Resources`. Signing stays inside out and never `--deep`: zmx and `bun` first, then the bundle. The spike's notarization passed with this layout.
- **The reminders filter is passed by its real path.**
  - Varnick sends the filter folder's path in each request, and the entry sets it as the plugin in place of the package's own.
  - The entry checks that the folder's hooks file exists before calling. When it is missing, it answers with a failed `result` ("filter missing"), which falls back to Gemma.
  - The reason: `claude` skips a plugin path that doesn't exist with only a log line and runs without the filter, which is what happened to the compiled helper in the spike.
  - The filter needs Claude Code 2.1.291 or newer; an older one ignores it and sends the reminders.
- **`pathToClaudeCodeExecutable`.** `minimalOptions()` has no parameter for it. The entry spreads it into the returned options, as the spike did and as `minimalOptions()`'s own comment invites ("Spread the result to extend it"). This is recommended over asking zbc for a parameter: nothing waits on a zbc release, and spreading `plugins` is already needed.

**Talking to the helper**
- **The process.** Varnick runs `bun --no-env-file` on `agent.js`, in Varnick's empty working folder, with the allowlisted environment (below).
  - `--no-env-file` keeps Bun from loading a `.env` into the helper's environment, which `minimalOptions()` passes on to `claude`.
  - The working folder holds no `bunfig.toml` either. Whether a global Bun config in the user's home reaches a plain `bun` run is unverified. If it does, `bun` is pointed at an empty config of Varnick's.
- **One helper process per request** in this first cut (still open, below).
- The helper reads requests, one JSON line each, from standard input until it closes, and exits once its requests have finished. Per request, Varnick writes one line and closes the input. A warm helper later is the same program with the input kept open and an id on each line.
- **A request** holds the prompt, the model, the path of the user's `claude`, the filter's folder and the working folder. Varnick decides them all, so the entry holds no choices of its own beyond `minimalOptions()`.
- **The output** is JSON lines: `text` for each piece as it is written, then one `result`. A `result` is either ok, with the whole text and the times the SDK reports, or failed, with a kind and the SDK's stop reason.
  - Nothing else goes to standard output.
  - Nothing of the prompt, the reply or the account goes to standard error.
- Varnick reads the lines as they arrive. In this option it uses the whole text and speaks it as today; speaking from the first sentence is Out of Scope.
- **Cancel and the deadline.**
  - Varnick sends `bun` SIGTERM, then kills it a second later. On SIGTERM the entry aborts its query through the SDK's abort controller, which ends `claude`.
  - A `claude` whose parent was killed ends when its input closes (inferred).
  - No `claude` may outlive a cancelled request; this is checked by hand.
- **Process plumbing.** `Subprocess.run` gives every child `/dev/null` as input and returns only at the end. `Subprocess.stream` holds an input pipe and streams the output, so the helper goes through it, or a sibling of it, with a way to write the request line and close the input.

**The call, inside the entry**
- `run(prompt, …)` with `minimalOptions()`'s levers unchanged. They are:
  - no tools;
  - no settings sources, so no user, project or local settings, which means no hooks, enabled plugins, skills or CLAUDE.md;
  - no MCP servers, with the MCP config strict;
  - auto-memory off, which empty settings sources don't do on their own;
  - claude.ai connectors off;
  - thinking disabled;
  - non-essential traffic off, which leaves one outbound request, with no session-title call and no third-party logs;
  - the attribution header off;
  - every reminder dropped;
  - the SDK's own one-line system prompt;
  - Haiku 5.5 (`claude-haiku-5-5`), in place of `minimalOptions()`'s own default model, set from the request so Varnick pins it in one place.
- No effort is set. Haiku 5.5 thinks by default, and turning thinking off is accepted only at effort `high` or below; its default effort is `medium` (the claude-api skill's model notes of 2026-10-06). Whether the call takes thinking off as `minimalOptions()` asks, and whether `low` effort is faster, is for the eval to confirm (still open, below).
- Spread over them:
  - the user's `claude` as the executable;
  - no session persistence, so nothing is written under `~/.claude/projects` for session search, Recent or project recency to read;
  - the working folder;
  - partial messages on;
  - the filter's folder as the plugin.
- `minimalOptions()` passes the helper's own environment to `claude`. That environment is the allowlist Varnick started `bun` with, plus the package's own flags.

**The environment Varnick starts `bun` with.** It is built from an allowlist, never from Varnick's own environment:
- `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_ALL` and `LC_CTYPE`, as Varnick has them;
- the `PATH` the login shell gave;
- the proxy and CA variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` in both cases, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) when Varnick has them;
- `CLAUDE_CODE_OAUTH_TOKEN` when Varnick has it, since it is a subscription credential.

So no `VARNICK_*`, `ZMX_*`, `CLAUDECODE` or other `CLAUDE_CODE_*` variable reaches `claude`, even when Varnick itself was started from a pane. No `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL` reaches it either, so a choice named "on your subscription" bills the subscription. A `claude` that is itself logged in with a key still bills that key, and the row's help says how `claude` is logged in. `HOME` is never changed and `CLAUDE_CONFIG_DIR` never set: either breaks the Keychain login (zbc's README).

**Finding `claude`**
- `claude` is resolved once per launch, off the main thread, through the account's login shell as a pane runs it (`-l -i`). The shell reports `command -v claude` and its `PATH`, and both are kept for the launch. They are resolved again after a call fails because `claude` didn't start (the file moved, as an update can do). Nothing found gives "claude not found".
- Then `claude auth status --json`, run by Varnick itself: `loggedIn` gates, and `authMethod` goes in the row's help. This runs at launch when Claude Code is chosen and Hey Varnick is on, when Settings › Models or Listening appears, and after a call fails as not logged in. It carries nothing of the user's. Whether it contacts Anthropic is unverified.
- A `claude` that is a JavaScript file, from an npm install rather than the native installer, may not start under the SDK's executable option. That is unverified; the row shows the call's failure.

**The choice**
- Text generation's choice gets a three-way type of its own: Claude Code, On this Mac, Server. It is saved in `textGenerationRunOn` as `claude`, `local` and `server`, so the saved values keep their meaning. Search embeddings keeps `ModelRunOn` with its two cases, since Claude Code can't embed, so its picker is unchanged.
- `textGenerationRunOn` absent reads as Claude Code.
- **Existing installs.** At launch, where Skip permissions is stored once (`storeSkipPermissionsIfAbsent`), `local` is stored when `textGenerationRunOn` is absent and either Hey Varnick is on or Gemma is installed. It runs at the same point and for the same reason: a default worked out on each read would move under the user later. Otherwise the key stays absent and reads as Claude Code.
- An older build reads `claude` as an unknown value, which gives `local`. Going back a version is safe; verified, since an unknown string gives the default.
- `VARNICK_TEXT_GENERATION=claude` chooses it from the environment, beside `local`, `server` and an address.

**Settings › Models**
- The picker: Claude Code | On this Mac | Server, widened to fit three.
- **Claude Code** row. Its detail is in the words of the Server row. "Runs your own Claude Code on your Claude subscription, with Claude Haiku: no tools, none of your settings, hooks, plugins, CLAUDE.md or memory, and no transcript saved. With Hey Varnick on, Anthropic gets what you ask out loud and the kind, title, site or folder, date and description of the few results it reads (for a Claude session, its prompts, your paired Macs' too). Each answer counts toward your plan's usage limits."
- Its controls are a status and **Check**.
  - Statuses: "Not checked yet". "Checking…". "Logged in", with help naming `claude`'s version and how it is logged in. "Answers in 2.4 s", after a Check or a call. In orange: "claude not found", "Not logged in: open a Claude pane and log in", and "Not answering: <kind>" until a call succeeds again.
- **Fallback on this Mac** row, below Claude Code. It is today's On this Mac row (Download, progress, Installed, Retry, Download again) with its own detail. "Writes the text when Claude Code can't: `claude` missing or logged out, offline, at your plan's limit, or too slow. Gemma 4 E2B, 4-bit, on this Mac; nothing is sent anywhere. One-time 3.6 GB download, about 2.5 GB of memory while in use, freed after 10 idle minutes. Optional." This is the shape of ElevenLabs' Fallback voice row.
- **Hey Varnick can be turned on** with Claude Code once its local check passed (found and logged in), or with this Mac's model installed. The link reads "Needs Claude Code: Settings › Models" when neither holds, and "Using this Mac's model" when Claude Code failed and Gemma answers, as Search embeddings' link does.
- **Hey Varnick's detail** gains a sentence. "With Text generation on Claude Code (the default), what you say and the results it reads go to Anthropic to write the answer."

**The fallback**
- The rule stays in `ModelServerState.place` and nowhere else (where-it-breaks, Search store), extended to Claude Code: Claude Code when it isn't known to have failed, else this Mac's installed model (`fallback`), else nothing.
- Claude Code's state has `ModelServerState`'s shape: in memory, worked out again each launch, and resting for `retryAfter` (60 s) after a failure. Reuse that type, with the `claude` path and the model as its target, if it fits; it is named for servers (Out of Scope).
- **A failure** rests Claude Code and runs the same request again on this Mac's model at once, as a server failure does. The failures are:
  - `claude` not found, or not logged in;
  - `bun` failed to start;
  - the deadline passed (unmeasured, set from the eval's figures; still open, below);
  - a failed `result`, the missing filter included;
  - output that can't be read;
  - the helper exiting without a `result`.
- A successful reply that cleans up to nothing is the model's verdict ("I couldn't answer that."), as with Gemma, not a failure. The reply goes through the clean-up Gemma's does (`SpokenText.plan(fromReply:)`, `SpokenText.spoken`). The prompts' sentence limits and that cut hold the length.
- With no Gemma, Varnick says "Claude Code isn't answering." after a failed call, and "Text generation isn't set up." when `claude` is missing or logged out.
- **No call is made before the first use** to check, unlike a server's first-use Check: it would double the first request's time. The local check gates, and the first real call tells.
- **Check** runs the local check, then one fixed prompt ("Reply with the single word: ready") through the helper, and shows the time. It uses a sliver of the plan.
- Not found, or not logged in, rests Claude Code like any failure, so logging in from a pane brings it back within a minute.
- A speculation that more speech restarts cancels its call first, so one call runs at a time.

**Logs**
- `ModelPlace` gains Claude Code. The timing line's decide and answer parts name it, or name the fallback with the failure's kind.
- Logged: durations, the failure's kind, the helper's exit status, and the stop reason and times the `result` carries. Never logged: the prompt, the reply, the helper's or `claude`'s output, or the account.
- `--generate` follows the choice and prints three times: `bun`'s start to its first line, the time to the `result`, and the API time the SDK reported. That splits start-up from the model. `--ask` follows the choice as the app does. These are what the eval and a builder time with.

**What leaves the Mac, and the docs it changes**
- With Claude Code chosen and Hey Varnick on, Anthropic gets the following under the user's account:
  - the request as heard after the wake phrase, cut to 500 characters;
  - for the answer step, the rows read, as the Server row lists them;
  - for the decide step, the request alone;
  - what Claude Code itself sends with a call: the account's token, and device and account ids in metadata.
- It never gets the user's settings, hooks, CLAUDE.md or memory index, a `.env`, the working folder, the OS or the date, tools or files. Nothing is written to disk as a transcript.
- **ADR 0029** once built: Text generation can run as the user's own Claude Code on their subscription, through Varnick's bundled Bun, and does by default for new installs. It records the levers, the helper and its pins, the one entitlement, and the fallback.
  - It amends ADR 0012 (which expected a cloud choice to come with a key under Keys), ADR 0014 ("over a cloud provider") and ADR 0015 ("on this Mac or … the user's own server … and nowhere else"), each with an "Amended by" line.
  - Its consequences include Bun as a build dependency, and a second signed executable in the bundle with `allow-jit`.
- **Privacy and security** › "What leaves your Mac" gains **Anthropic, through Text generation**, in the TypeSafe section's shape. Choosing Claude Code, the default, is consent to send what Text generation needs, with the list above. Keeping it private is On this Mac. "Out of the box, two things" stays true, since Hey Varnick is off by default.
- The **README**'s Privacy list gains a bullet. The **guide** says Claude Code writes Hey Varnick's answers by default, and the on-device models table marks Gemma as the choice or the fallback.
- **THIRD_PARTY_NOTICES** gains what the app now contains (Bun, and in `agent.js` `@zabaca/agent`, the Agent SDK and what they pull in), and "What the build downloads" gains Bun.
- **docs/building.md** gains that the build fetches Bun.
- **Where Varnick breaks:**
  - Search store's "What goes to a model server, and to nothing else" gains Claude Code's counterpart.
  - "Listening and spoken requests" says who writes.
  - Signing gains `bun`'s rules: inside out, its own identifier, `allow-jit` only and why, and no other entitlement.
  - A text helper paragraph gives the rules: the levers and Varnick's additions, `--no-env-file`, the allowlist, `HOME` and `CLAUDE_CONFIG_DIR` left alone, no persistence, the filter by real path and its check, the protocol (nothing but JSON lines on standard output, nothing of the prompt on standard error), SIGTERM ending `claude`, the fallback rule's home, and the pins and their check by hand.

## Testing Decisions

There is no test target. Verification is `make build` (which must fetch Bun, build `agent.js` and sign `bun` from a clean `.build`), then the command line, then by hand after the user restarts Varnick.

- **Side by side:** `--ask` over a set of made-up requests with `VARNICK_TEXT_GENERATION=claude` and `=local`, comparing the answers and the times, and `--generate` for the split between start-up and the API. Request files are personal, so they stay out of the repo.
- **The bundle:**
  - `codesign --verify --deep --strict` passes with `bun` inside.
  - `codesign -d --entitlements` on `bun` shows `allow-jit` and nothing else.
  - The notarized app runs a call from a quarantined copy that has been opened once, as in the spike.
  - The bundle still verifies after calls, since nothing is written beside `agent.js`.
- **Nothing is left behind:**
  - After several calls there is no new `.jsonl` or folder under `~/.claude/projects`, no card on the session board, nothing new in Recent or session search, and no work link on the Problems board.
  - After a cancel (more speech, Hey Varnick turned off) no `claude` or `bun` process remains.
- **Nothing of the user's runs or goes:**
  - A CLAUDE.md with a marker instruction, and a `.env` with a made-up variable, put in Varnick's working folder for the test, don't reach the reply or `claude`'s environment.
  - The user's own hooks and plugins don't fire. The user checks this, by a hook of their own that writes a file; an agent doesn't edit the user's Claude settings.
  - With the filter folder renamed away, the call fails as "filter missing" and Gemma answers.
  - zbc's live reminders check (`e2e:reminders`) passes against the pinned versions. If the eval's proxy is at hand, a call through the helper makes one outbound request, and its body holds no reminder and no memory index.
- **By hand after the restart:**
  - With Claude Code and Hey Varnick on, a request is answered and the timing line names Claude Code.
  - Wi-Fi off: Gemma answers at once and the line names the failure. With no Gemma, Varnick says Claude Code isn't answering.
  - A second request within a minute of a failure goes straight to Gemma.
  - An upgraded Mac with Hey Varnick on and no saved choice is still on On this Mac. A fresh account, with no Hey Varnick and no Gemma, shows Claude Code, and Hey Varnick turns on without a download.
  - Not logged in is checked by the user only, never by an agent: logging out signs out every pane.
- **A pin bump** (`@zabaca/agent`, the SDK or Bun) repeats the bundle check, the reminders check and one spoken request.
- Once a test target exists, the pure parts are worth tests: the request line and the allowlist (no `VARNICK_*`, no `ANTHROPIC_*`), reading the helper's lines (pieces, a result, a failure, an exit without a result), the one-time store of `local`, and the fallback rule over each failure kind.

## Out of Scope

- Speaking from the first sentence while the rest is written. The stream allows it; the speech path speaks whole answers today.
- A warm helper kept running between requests (still open, below).
- **Follow-up:** custom apps and the Phone page could run on the bundled Bun, lifting ADR 0005's requirement that the user installs Bun.
  - The spike showed `bun add` into a fresh folder works under the hardened runtime with `allow-jit` alone.
  - Native `.node` addons, and `bun:ffi` with dylibs that aren't Apple's, would need `disable-library-validation` (untested). `bun:ffi`'s `cc` would need unsigned executable memory.
- Claude as the decide step in Jev's place, or Claude as an agent with the sources as tools: listening-never-answers options 03 and 04.
- The other routes: plain `claude -p` with copied flags (option 02), calling the Anthropic API with a key (option 03), and one Claude conversation kept open across requests (option 04).
- A model picker.
- Claude Code for Search embeddings or the relevance filter.
- Claude Code on a paired Mac or the headless host: a request's text is written by the Mac that heard it.
- Rewriting the prompts for Haiku. They were cut down for Gemma and can be tuned later with `--ask`.
- Renaming `ModelServerState` now that it also holds Claude Code's state. Worth raising, not asked for.

## Further Notes

**Still open** (recommendation first; the eval's figures are pending)

1. **One process per request, or a warm helper.** Recommended: one `bun` per request in this first cut, unless the eval shows start-up is too slow. A warm helper is one long-lived `bun`, started when Hey Varnick turns on, speaking the same JSON lines with ids. It saves `bun`'s start and the load of `agent.js`, and it can start the `claude` query when "Hey Varnick" is heard and feed it the prompt once the rows are ready. That hides `claude`'s start-up as ElevenLabs' warm-up hides its connection. Each request is still a fresh query, so no request sees another's rows (unlike option 04). The figure to decide on: start-up's share of a call.
2. **The deadline.** From the eval's figures: the slowest warm answer-sized call, plus a margin. Unmeasured until then.
3. **Thinking off and effort on Haiku 5.5.** The eval confirms that the call runs with thinking off, which Haiku 5.5 accepts only at effort `high` or below, and whether setting `low` effort makes it faster. If thinking can't be turned off, the levers need a change before this ships. Whether the subscription's Claude Code serves `claude-haiku-5-5` is unverified, and the eval's first call shows it.

**Considered and not chosen**
- **A helper compiled with `bun build --compile`.** This was this option's first design, passed over by the user on 2026-10-10 after the spike. It needs the same one entitlement, but:
  - its reminders filter resolves inside Bun's virtual file system (`/$bunfs`), where `claude` can't read it, and is skipped with only a log line;
  - the compiled binary loads a `.env` and `bunfig.toml` from its working folder unless both are turned off when compiling;
  - it can't run anything else, where a plain `bun` can later run custom apps.
- **Plain `claude -p` with the levers copied as flags** (option 02): passed over by the user on 2026-10-10. The copied flags would drift from zbc, the reminders filter is untested from the CLI, and a one-shot `-p` has no path to a warm helper.
- **Depending on zbc's package at run time from the user's own Bun or Node:** nothing to require the user to install.
- **The SDK's own bundled Claude Code:** 226 MB in the app, and a login of its own rather than the user's `claude`.
- **Asking zbc for a `pathToClaudeCodeExecutable` parameter on `minimalOptions()`:** not needed, since spreading it works, as above. Worth offering zbc later, beside a `plugins` path parameter.

**Verified in the code at 53e4064:**
- Text generation's two consumers and its one way in.
- The interactive fallback rule and the lines spoken when nothing can write.
- `textGenerationRunOn`'s values and default, and the type it shares with Search embeddings.
- Hey Varnick's gate and its default of off.
- Varnick's hooks arriving only through a pane's `--settings`, and acting only with `VARNICK_SESSION_FILE`.
- Session search and project recency reading `.jsonl` files under `~/.claude/projects`.
- `Subprocess.run`'s `/dev/null` input, and `Subprocess.stream`'s held input and streamed output.
- zmx's pinned fetch, its signing by rename, and the inside-out signing in the Makefile.
- Rows carrying dates in words.
- Skip permissions' store-once at launch.

**From the spike, not rerun:** the one entitlement and the four not needed, notarization, the quarantined run, `pathToClaudeCodeExecutable` honoured with nothing written beside the SDK, the `/$bunfs` filter path skipped, `.env` loading, `bun add` under the hardened runtime, and `bun`'s 63.1 MB. The spike made no live call: a stand-in for `claude` answered, and the real `claude` was shown starting with the right arguments.

**Read, not run:**
- `@zabaca/agent` 0.2.0's `minimalOptions()`, `run()` and README.
- The Agent SDK 0.3.291's options (`pathToClaudeCodeExecutable`, `persistSession`, `includePartialMessages`, `cwd`).
- The SDK's licence file.
- `claude auth status --json`'s two keys.

**Inferred:**
- That a killed helper's `claude` ends on its input closing.
- That a failed connection ends a call before the deadline.
- That the install can leave out the SDK's native packages.
- That the SDK drives a newer `claude` than its own without trouble today.
- Whether a global Bun config reaches a plain `bun` run.
