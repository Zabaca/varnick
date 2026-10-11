---
problem: text-generation-ignores-the-claude-subscription
title: Varnick calls Anthropic's Messages API itself, with a key kept in the Keychain
summary: A Text generation choice that posts Varnick's prompts straight to Anthropic's Messages API, over URLSession, as Varnick already calls TypeSafe and ElevenLabs. The key is entered in Settings › Models › Keys and kept in the Keychain. There is no process to start, no Claude Code in the way and nothing to strip, and the connection can be warmed at the wake. It is likely the fastest route (unmeasured). But it is billed per token on an API account, apart from the subscription, which is what the user wants Varnick to use. Passed over by the user on 2026-10-10.
status: proposed
---

## Solution

Settings › Models › Keys gains an **Anthropic** row, built as ElevenLabs' row is. It has a secure field and Save, then "Key saved" and Remove key, and the key is kept in the login Keychain only, with no environment variable and no `.env`. With a key saved, Text generation's picker offers **Anthropic API**.

Each text Varnick asks for is then one `POST /v1/messages`:

- one user message with Varnick's prompt;
- the pinned model, Claude Haiku;
- `max_tokens` from the caller, as Gemma and a server get it;
- thinking off.

One `URLSession` is kept, and opened when "Hey Varnick" is heard, as ElevenLabs' is. The reply can stream. The fallback to this Mac's Gemma, the rest after a failure, the logs and the privacy text are option 01's, with "your API account" in place of "your subscription".

## Trade-offs

- **Likely the fastest:** no process start-up, no CLI, a warm connection, and the caller's exact token budget. Unmeasured.
- **Separate billing.** Calls are billed per token on an API account from the Claude Console, not on the subscription. That is what the user passed it over for. The cost is small: Claude Haiku 5.5 is $0.10 per million input tokens and $0.50 per million output tokens (the claude-api skill's table of 2026-10-06). That puts a spoken answer of under 2,000 tokens at a fraction of a cent (an estimate from the prompts' size).
- **One more key and one more account** in Settings, the README and the privacy page.
- **Nothing to strip and nothing to drift:** no hooks, plugins, memory or reminders exist on this path, and no SDK or CLI version to track.
- The same data goes to Anthropic as in option 01, under an API account rather than the subscription's.

## User Stories

1. As a Varnick user with an Anthropic API key, I want Hey Varnick's answers from Claude as fast as possible, billed to my API account.
2. As a Varnick user, I want the key kept in the Keychain and never read from a file.
3. As a Varnick user, I want this Mac's Gemma to answer when the API fails or is slow.

## Implementation Decisions

- The key goes only in the `x-api-key` header to Anthropic's API, follows no redirect, and is never logged. It has its own Keychain account, beside `ELEVENLABS_API_KEY`.
- The model is pinned in code, as `SpokenRouter.pinnedModel` is, with no picker.
- The warm-up at the wake carries nothing of the user's.
- Choosing Anthropic API is consent, as choosing an ElevenLabs voice is. On this Mac stays the private choice.

## Testing Decisions

`make build`, then `--ask` and `--generate` against both choices, then by hand: an answer, Wi-Fi off falling back, a wrong key refused and said so in the row.

## Out of Scope

As option 01. Also streaming into speech, and any use of the subscription's login on this path.

## Further Notes

- **Passed over by the user on 2026-10-10** for option 01: the subscription is the thing Varnick supports, and this route bills elsewhere. It stays proposed as the fast path if option 01's figures are too slow.
- Using a subscription login against the API from Varnick directly was not considered: it is option 01's job to go through the user's own `claude`.
