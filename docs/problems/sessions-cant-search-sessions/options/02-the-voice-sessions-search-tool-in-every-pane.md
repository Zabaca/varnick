---
problem: sessions-cant-search-sessions
title: The voice session's `search` tool, as it is, in every pane
summary: The least to build. The `search` tool the voice session already has is listed for every Claude pane that has Panel access, and the app stops refusing it from other panes. A session then searches History, bookmarks and Claude sessions on this Mac and the paired Macs, by words and meaning, and gets up to 20 pages and 3 sessions, each session with its title, folder, when it was used, its prompts from the start cut at 300 characters, its conversation id and, on this Mac, its transcript's path. That is the voice session's search, not the panel's: 3 sessions, no tab or standing, no matching excerpt, and no way to open what it found. Reading means the raw transcript through the session's own file tools, which a paired Mac's session has none of. It sends the user's browsing history to Anthropic with every session that searches. Recommended against as the answer; it could be a first step only if the user wants something today.
status: proposed
---

## Solution

The voice session's `search` set is listed for every Claude pane that gets Panel access's set, not only the voice session. The app's check that the caller is the voice session goes, and so does the refusal while Answer with Varnick's own steps is on, which is about the voice session alone. Nothing else changes: the arguments (`query`, `project`, `from`, `to`), the search (the spoken pipeline's search step with no filter and no judge), the reply, and the rule that the caller's own conversation is left out.

## Trade-offs

- **Least to build:** the listing, two checks, and the docs. A few dozen lines of code.
- **Not the panel's search.** It ranks sessions as `?` search does, not as the prompt line the user types in: 3 sessions, never more, against the prompt line's 5; no `^mac` or `@agent`; and a project is a folder name only.
- **Results say less than the panel shows.** No tab and no Open, Closed or Done; no "a pane here is on it"; and the text is the prompts from the start, cut at 300 characters, never the part that matched. A long session found by something late in it comes back with its opening prompts.
- **No way to act.** Nothing opens what it found: `show` takes no conversation, `keys` refuses ↩ on a result, and `pane_open` resumes nothing. The session can only tell the user what it found.
- **Reading is the raw transcript.** The session reads the path with its own file tools: one JSON object per line, tool calls, file contents and command output included, often megabytes. A paired Mac's session has no path here, only its Mac's name.
- **Browsing history goes to Anthropic from every session that searches:** up to 20 pages a call, with their addresses, titles and descriptions. Today that happens only from the voice session, which the user turned on knowing it. Option 09 of `listening-never-answers` asked this as question (g) and answered "voice session only".

## User Stories

1. As the user, I want a session to search my sessions, pages and bookmarks the way the voice session can, so that I can ask it to find something today.
2. As the user, I want it to say which session it found and where its transcript is, so that it can read it.

## Implementation Decisions

- **The listing:** the search set's argument is passed wherever Panel access's is (`ClaudeSession.launchClaude`, the one place). A run, a Task step and a headless host still get none.
- **The app's checks:** the voice-only check and the voice-session switch's refusal are removed. Varnick starting and the calling pane (a Claude pane on this Mac) stay.
- **The tool's description** stops calling itself the voice session's and drops the spoken pipeline's wording.
- **Docs:** ADR 0042 and ADR 0031's amendment on sets name the search set as every pane's; `docs/privacy-and-security.md` moves "What its search tool finds" out of the voice session's section into Panel access's, and says any session can send history to Anthropic; where-it-breaks, Listening and spoken requests, loses "listed only for the voice session".
- **State:** none.

## Testing Decisions

- `make check-mcp`: the search set is listed with Panel access's for an ordinary pane, and not for a run.
- By hand, in a restarted ordinary session: `search` answers pages and sessions; its own conversation is left out; Varnick's log holds the tool, the kind and the duration only.

## Out of Scope

- Everything option 01 adds: the prompt line's ranking, more results, tabs and standing, a matching excerpt, a clean read and opening.

## Further Notes

- **Decision for the user:** whether any session, not only the voice session, may send your browsing history and bookmarks to Anthropic when it searches. The planner recommends not, which is why this option is not the recommendation.
- **As a first step before option 01:** possible, but option 01 would then leave two search tools in every pane. Option 01 keeps this tool the voice session's.
- **Verified in the code at bddf4ce:** the tool's listing, its two refusals, its reply's fields (`judgeRows` plus address, conversation id, transcript path or Mac), the 20 and 3 limits, the 300-character cut from the start of the prompts, and that the caller's own conversation is dropped.
