---
problem: text-generation-ignores-the-claude-subscription
title: One Claude Code conversation is kept open, and every text is a new message in it
summary: As option 01, but one `claude` process is started when Hey Varnick turns on and kept running, with streamed input. Each text Varnick asks for is a new user message in that one conversation, so no request pays Claude Code's start-up. But the conversation grows with every request, each answer sees the requests and rows before it, and a long-lived process has to be watched through crashes, logouts and updates. Passed over by the user on 2026-10-10.
status: proposed
---

## Solution

When Hey Varnick turns on with Claude Code chosen, Varnick starts one `claude` session through option 01's helper, with option 01's levers, and keeps it. The session takes its input as a stream, and each prompt is written as the next user message. Each reply is read from the stream, and the process stays for the next one. It is restarted when it exits, when Hey Varnick turns off, and after a set number of requests or tokens, so the conversation never grows without end.

## Trade-offs

- **No start-up per request.** That saves the share of each call spent starting the helper and `claude`, which is unmeasured.
- **Requests share a conversation.** Every answer is written with the earlier requests and their rows in context. That can colour an answer (a source named before turns up again), and the input grows with each request until the restart or a compaction. Clearing between requests is unverified with streamed input. Restarting after every request is option 01's warm helper, which starts a fresh query per request (option 01, still-open question 1).
- **A process to watch all day.** It can crash, outlive a logout, run an old binary after Claude Code updates itself, and hold memory while Hey Varnick sits idle for hours (unmeasured).
- **Cancel is harder.** Stopping one answer must not end the session, or the next request pays the start-up again.
- The data, the limits and the fallback are option 01's.

## User Stories

1. As a Varnick user, I want each spoken answer to start as soon as possible, with no start-up cost per request.
2. As a Varnick user, I want one request's results never to change the next request's answer.

The second story is what this option struggles with.

## Implementation Decisions

- The session runs with no persistence, so the long conversation is never written to `~/.claude/projects`.
- It restarts after a set number of requests, a set age or an error, and its state follows `ModelServerState`'s rest after a failure.
- Interrupting an answer ends only that turn. How the SDK interrupts a turn while keeping the session is unverified.

## Testing Decisions

As option 01, plus: a hundred requests in a row with the input size watched, and answers compared with option 01's for the same requests in a fresh process.

## Out of Scope

As option 01.

## Further Notes

- **Passed over by the user on 2026-10-10** for option 01. Option 01's warm helper gets most of the start-up saving without a shared conversation.
- It is worth reconsidering only if a fresh query's start-up stays large even when it is started at the wake.
