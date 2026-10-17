---
problem: listening-never-answers
title: Gemma on this Mac calls the three sources as tools
summary: Wake, response and privacy as in option 01, but the steps aren't fixed. This Mac's Gemma 4 E2B runs a short tool loop with four tools: search History, search Bookmarks, search sessions, and read one session, including Claude's last reply. It may search more than once or read a session before it answers. Searches use option 01's search apart from the panel, and the answer is only spoken. Runs on this Mac only.
status: rejected
reason: Option 09 shipped instead. Every spoken request goes to the voice session, a Claude Code session with a search tool over History, Bookmarks and sessions, which chooses what to search and reads sessions itself.
---

## Solution

The wake phrase, the request, keeping Launchy's own voice out, the spoken-only answer and the logging rules are option 01's. What differs is steps 1 and 2: the model drives them instead of Launchy.

The request goes to this Mac's Gemma as a chat with four tools:

- **search history** and **search bookmarks** take search words and return the top pages, numbered, in option 01's row form;
- **search sessions** does the same for Claude sessions;
- **read session** takes the number of a session already returned and gives its prompts plus the start of Claude's last reply, read from its transcript.

The model may call up to three tools, then must answer, in option 01's answer form: one or two sentences, which Launchy speaks. Nothing shows on screen.

The pinned mlx-swift-lm already runs this loop: a chat session takes tool definitions and a dispatcher, and parses Gemma 4's tool-call format. So there is no new package.

## Trade-offs

- **More can be answered.** A request can mix sources ("did I bookmark it, or was it in a session?") or retry with other words. "What did Claude conclude about the title prompt?" can be answered from the session's last reply, which option 01 never reads.
- **Tool calls by a 2-billion-parameter model are unproven here.** Picking a tool and good arguments is harder than filling in option 01's two fields. A wrong tool call, or one in a malformed format, ends in a weaker answer or none. A spike has to show it works before this is built.
- **This Mac only.** Text generation on a server speaks one user message, with no tools. Tools over the OpenAI-compatible route need the server's chat template to handle Gemma 4's tool format, which is unverified. With Server chosen, the switch shows that it needs Text generation on this Mac.
- **Slower and more variable.** Each tool round is another prefill and generation, so a request costs one to three more rounds than option 01's two calls. Estimated warm at 4–7 s to the first spoken word, unmeasured.
- **Several searches per request,** through option 01's search apart from the panel, so nothing on screen changes however many run.
- **Still private.** Everything runs in Launchy's process. Reading Claude's replies adds nothing that leaves the Mac.

## User Stories

1. As a Launchy user, I want a request that spans sources answered from all of them, so that I don't have to know where I kept something.
2. As a Launchy user, I want "what did Claude decide about X" answered from that session's last reply, not only from my prompts.
3. As a Launchy user, I want Launchy to try other words when the first search finds nothing useful.
4. As a Launchy user, I want everything else as in option 01: the wake phrase, the answer only spoken, nothing opening, and nothing leaving this Mac.

## Implementation Decisions

**Wake, request, response, privacy, Settings, transcript and state**
- As option 01, except where the switch can run. It requires Text generation on this Mac. With Server chosen, it shows "Needs Text generation on this Mac", linking to Settings › Models.

**The tool loop**
- One chat on this Mac's Gemma, using the generator already loaded for titles.
  - A fixed instruction, kept in one place: what each source holds, to answer in option 01's form, and to say so when nothing fits.
  - The four tools, with their argument schemas.
  - The request as the user message.
- Greedy decoding, at most 160 new tokens per round.
- **At most three tool calls.** After the third, the tools are dropped and the model must answer.
  - A call that names no known tool, or has unreadable arguments, counts as a call. It returns a short error the model can see.
  - A turn with no tool call and no text ends the request with "I couldn't answer that".
- **Tool results** use option 01's row form, numbered across the whole request, so read session names a session unambiguously.
  - search history: 5 pages.
  - search bookmarks: 5 bookmarked pages.
  - search sessions: 3 sessions.
- **read session** takes a number already returned. For one of this Mac's sessions it reads its transcript once and returns:
  - its prompts, oldest first, cut to 1,000 characters;
  - the text of Claude's last reply, cut to 1,000 characters.

  A paired Mac's session has no transcript here, so it returns its prompts and says the reply is on the other Mac. Reading a transcript happens off the main actor, as title lookups do.

**Searching apart from the panel**
- Tools call option 01's search apart from the panel, which ranks exactly as the panel does and sets nothing on screen.
- Tools never run the relevance filter. Their candidates go nowhere.

**Command line**
- `Launchy --ask <file>`, as in option 01, also prints each tool call and its arguments.

## Testing Decisions

- **Spike first.** About 30 made-up spoken-style requests: 10 for pages, 10 for bookmarks, 10 for sessions, a few spanning two, and a few about nothing in the store. Run them through the loop with `--ask` on a copy of the database, and count:
  - the right tool first;
  - usable search words;
  - well-formed calls;
  - answers about the right row.

  If the right tool comes first in fewer than about 25 of 30, this option isn't worth more than option 01.
- **By hand:** option 01's checks, plus a request answered from a session's last reply, and a request whose first search finds nothing.

## Out of Scope

- A server for this loop.
- More than three tool calls, and follow-up questions.
- Reading pages' text, or any tool that acts (opening, starting sessions).

## Further Notes

- The rejected sessions-not-searchable option 03 (search replies too) was about indexing every reply. Its reasons, size and replies burying prompts in ranking, don't apply to reading one listed session's last reply at answer time. Nothing here indexes replies.
- **Verified in the pinned package:** the chat session's tool definitions and dispatcher, its fail-closed handling of unknown tools, and the Gemma 4 tool-call parser.
- **Unverified:** Gemma 4 E2B's tool-use accuracy, and its latency over several rounds.
- Same ADR and glossary entries as option 01. The ADR would add that the model chooses the steps.
