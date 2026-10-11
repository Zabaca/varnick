---
problem: text-generation-ignores-the-claude-subscription
title: Varnick runs plain `claude -p` itself, with zbc's levers copied as command-line flags
summary: As option 01, but with no helper. Varnick starts the user's `claude -p` directly for each text, with the levers of `@zabaca/agent`'s `minimalOptions()` written out as flags, environment variables and inline settings, and a reminders filter module of its own loaded with `--plugin-dir`. Nothing new to build or sign, and no Agent SDK inside Varnick. But the copied levers drift from zbc, the filter is untested from the CLI, and a one-shot `-p` has no path to a warm process. Passed over by the user on 2026-10-10 in favour of option 01.
status: proposed
---

## Solution

Everything outside the call is option 01's:

- the three-way picker and the default;
- `local` stored once for existing Gemma users;
- the Settings rows;
- finding `claude` through the login shell and `claude auth status`;
- the allowlisted environment;
- the fallback to this Mac's Gemma;
- the logs and the privacy text.

The call is different. Varnick starts the kept `claude` path directly, with the prompt on standard input and these arguments, which are the CLI flags the Agent SDK passes for `minimalOptions()`'s levers:

- `-p`, `--model` with the pinned model, and `--output-format json`;
- `--tools ""`;
- `--setting-sources=`, empty;
- `--strict-mcp-config` with no `--mcp-config`;
- `--settings` inline, with `autoMemoryEnabled` false and `disableClaudeAiConnectors` true;
- `--thinking disabled`, which isn't in the help but is the SDK's mapping;
- `--plugin-dir` with a reminders filter module Varnick ships in its resources;
- `--no-session-persistence`;
- `--system-prompt` with one line of Varnick's. Plain `-p` otherwise sends Claude Code's full prompt, about 29,000 characters.

The environment adds `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `CLAUDE_CODE_ATTRIBUTION_HEADER=0`. `Subprocess.run` gains an optional input. The JSON result's text goes through Gemma's clean-up.

## Trade-offs

- **Nothing new in the build or the bundle.** No Bun, no second signed executable, no JIT entitlements, no Agent SDK licence question.
- **No SDK between Varnick and `claude`,** so no SDK-to-CLI protocol to drift. Only the flags and the JSON result's shape can change.
- **The levers are copied by hand.** When zbc learns a new one (as it did with the reminders at 2.1.291), Varnick doesn't get it until someone copies it.
- **The reminders filter is untested from the CLI.** zbc's live check runs through the SDK.
- **No path to a warm process.** `-p` answers once and exits. Keeping a process ready for the next request means option 01's helper or option 04's session.
- **No streaming** with `--output-format json`. `stream-json` would bring partial messages, at the cost of reading the SDK's message stream by hand.
- The rest is option 01's: the data that goes to Anthropic, the shared usage limits, the network, and the unmeasured time.

## User Stories

1. As a Varnick user, I want Hey Varnick's answers written by my Claude subscription with nothing more inside Varnick.app than today.
2. As a maintainer, I want no build-time dependency beyond what Varnick has today.

The rest are option 01's.

## Implementation Decisions

- The arguments and environment above, run directly and never through the shell. The prompt goes on standard input, never as an argument.
- Never `--bare`, which can't use the subscription. Never Varnick's hook `--settings`, `--session-id` or `--resume`.
- The model and the effort follow option 01's: Haiku 5.5, with thinking off and the effort the eval settles.
- The filter module is Varnick's own drop-all copy, modelled on zbc's `mods/reminders`. It needs Claude Code 2.1.291 or newer.
- **`--safe-mode` was considered.** It is one flag that turns off CLAUDE.md, plugins, hooks and MCP and keeps auth. Its "installed plugins" may include the `--plugin-dir` filter, its help doesn't say it covers auto-memory or the reminders, and nothing measured it.

## Testing Decisions

As option 01, less the bundle check, plus one check: a call's request body, through the eval's proxy, holds no reminder and no memory index, since no zbc check covers the CLI path.

## Out of Scope

As option 01.

## Further Notes

- **Passed over by the user on 2026-10-10** for option 01, the bundled helper. The reasons: the copied flags would drift from zbc, the reminders filter is untested from the CLI, and there is no path to a warm session.
- **When to come back to it:** Anthropic's agreements turn out not to allow shipping the Agent SDK inside Varnick. The user decided to build option 01 now and read them before the first release that ships the SDK, with this option as the way back. (The signing spike of 2026-10-10 showed the bundled Bun signs and notarizes with one entitlement, so signing is not a reason.)
- **Read, not run:** the flags, from `claude` 2.1.296's help and the Agent SDK 0.3.291's mapping. **Inferred:** the JSON result's field names, and that the CLI has no token-budget flag.
