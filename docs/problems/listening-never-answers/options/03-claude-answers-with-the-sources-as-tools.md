---
problem: listening-never-answers
title: Claude answers through the Messages API, with the sources as tools run in Launchy
summary: Wake and response as in option 01, but the spoken request goes to Claude on Anthropic's API with option 02's four tools, which Launchy runs in-process. Claude decides which sources to search, may read a session, and writes the answer. Better reasoning than a 2-billion-parameter model, but the request and every row Claude reads (page titles, sites, descriptions, bookmark folders, session prompts and replies) go to Anthropic. That reverses a rule Launchy keeps today, so it needs its own switch, an API key and an ADR.
status: proposed
---

## Solution

The wake phrase, the request, the panel and the spoken answer are option 01's. The deciding and reading are option 02's tool loop, with the model being Claude through Anthropic's Messages API instead of Gemma.

Launchy sends the request with a fixed system prompt and four tools: search history, search bookmarks, search sessions, and read session. Each tool runs in Launchy against the local search store, and each result goes back to Claude. The loop ends when Claude answers, or after four rounds. The answer has option 01's form (the row number, then one or two sentences). Launchy speaks it and selects that row in the panel.

The tools' results go to Anthropic. That means titles, sites, page descriptions, bookmark folders, session titles and the user's prompts, and Claude's last reply when a session is read.

## Trade-offs

- **The best answers of the options.** Claude reads a vague spoken request well and picks the sources and words. It combines rows and says clearly when nothing fits. It also leaves room for later requests that aren't searches.
- **History and Bookmarks leave the machine, to a third party.** No Launchy feature does this today:
  - ADR 0012 chose an in-process model over a cloud provider to keep prompts on the Mac.
  - `where-it-breaks.md` says a session's prompts go to no service other than the user's paired Macs and own server.
  - TypeSafe sees only the top pages' title, site and description, and only when the user chose it.

  Session prompts and Claude's replies did already go to Anthropic when the session ran, since sessions are Claude Code conversations. History and Bookmarks never have.
- **A key, a cost and a network.** It needs an Anthropic API key, kept in the Keychain, and a connection to the internet. Each request costs money; see the estimate under Further Notes. Offline, it doesn't answer.
- **Latency.** Each round is a round trip, and a request takes two to four. Unmeasured, estimated at 3–8 s to the first spoken word, after the transcriber's 1–2 s.
- **A search apart from the panel,** as in option 02, with the same refactor.
- **Works on any Mac,** including one without Gemma or a server: nothing runs locally but the search.

## User Stories

1. As a Launchy user, I want vague or roundabout spoken requests understood, so that I don't have to phrase them for a small model.
2. As a Launchy user, I want to choose, knowingly, to send my spoken requests and what they find to Claude, and to see in Settings exactly what is sent.
3. As a Launchy user, I want my API key kept in the Keychain and never logged.
4. As a Launchy user, I want Launchy to say so when Claude can't be reached, and not hang.
5. As a Launchy user, I want everything else as in option 01: the wake phrase, the spoken answer, the panel with the named row selected, and nothing opening without ↩.

## Implementation Decisions

**Settings**
- Settings › Listening gets option 01's Hey Launchy switch.
- Settings › Models gets a **Spoken requests** row that names Claude and the model.
  - Its detail says what is sent: the spoken request, and the titles, sites, descriptions, bookmark folders, session prompts and Claude's replies that its searches find.
  - It can't be turned on without a key.
- An **Anthropic** key row under Keys, in the Keychain the way TypeSafe's and the model server's keys are. Never logged, never shown after saving.
- The model defaults to `claude-opus-5-5`, Anthropic's current default. Haiku 5.5 is faster and much cheaper; that is the user's choice (open question).

**The request**
- Anthropic's Messages API over HTTPS. There is no official Swift SDK, so it is a plain HTTPS request. The builder loads the `claude-api` skill for the exact request and response shapes.
- One fixed system prompt and the four tools with strict argument schemas, in a fixed order so the prefix can be cached. The request is the user message. Tool choice is automatic, since forcing a tool is rejected by the current models.
- Low effort; thinking can't be turned off on the current Opus. Non-streaming, with a modest maximum output.
- **The loop:**
  - While Claude stops to use tools, Launchy runs every tool call in that turn and returns all the results in one user message.
  - A failed tool returns an error result rather than nothing.
  - At most four rounds, then Launchy says it couldn't answer.
  - A refusal is read before any content, and spoken as "Claude declined that".
- A 20 s timeout for the whole request. A timeout, a status other than 200 or an unreadable reply is spoken as "Claude didn't answer", and nothing is retried.

**The tools**
- As in option 02: the same four tools, the same row form numbered across the request, the same limits, and the same search apart from the panel. The relevance filter never runs on a tool's search.

**The connection and logs**
- One address, Anthropic's API. It follows no redirect.
- It logs the kind of failure and the status code, never the request, a tool's result, the reply or the key. This mirrors the model server's rules.
- `where-it-breaks.md` gets a section on what goes to Anthropic and nothing else.

**Panel, speech, transcript, state**
- As in option 01. One new Keychain item and the model's name in UserDefaults.

## Testing Decisions

- No test target. The tool dispatcher (a tool name and arguments in, rows out) is the seam for a first test.
- **By hand:** option 01's checks, plus:
  - a request with the key missing, which can't happen, since the switch is off;
  - a request with the network off, which is spoken as no answer within the timeout;
  - Launchy's log, which holds no request, rows, reply or key.
- `--ask`, as in option 02, prints each tool call and the usage the API reports, to check cost and round counts on a dozen made-up requests.

## Out of Scope

- Claude Code headless instead of the API (see Further Notes).
- Server-side tools such as web search: Claude gets only Launchy's four tools.
- Follow-up questions, and actions beyond selecting a row.

## Further Notes

- **A new ADR on acceptance,** amending ADR 0012's "not a cloud provider" for this one use and recording what is sent. Its consequence is a new kind of data leaving the machine: History and Bookmarks.
- **Cost, estimated** from Anthropic's price table as cached on 2026-10-06, not measured. A request of three rounds is about 6,000 input and 300 output tokens.
  - Opus 5.5, at $4 and $20 per million: about 3 cents.
  - Haiku 5.5, at $0.10 and $0.50 per million: under a tenth of a cent.

  Caching the fixed prefix lowers both.
- **Considered: headless Claude Code (`claude -p`) instead of the API.** It needs no key, using the user's Claude Code login, and `Launchy --search <words> --json` already prints search rows as JSON for it to call.
  - Each request would start a login shell and Claude Code, and each search a second Launchy that loads the embedder. Inferred at several seconds per search, too slow to speak back.
  - Its transcript would land among the user's sessions. With no typed prompt it would stay out of search, but it would still be on disk.
- **Verified:** the Keychain pattern, the `--search --json` output, and that no Launchy code sends anything to a cloud language model today. **Unverified:** every latency figure here.
