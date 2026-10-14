---
problem: listening-never-answers
title: A web answer searches Exa with the user's own key, and Text generation writes it
summary: Option 07's web step splits in two. Varnick searches Exa itself with the user's Exa key, sending only the request's words. The writer the user set in Settings › Text generation (Claude Code, this Mac's Gemma or their server) then turns the top results into one or two spoken sentences naming the source, from the numbered results only. A reply that names no result is not spoken as an answer. Exa replaces Claude Code's WebSearch, so the web no longer needs Claude Code logged in, the text helper goes back to no tools, and the request no longer goes to Anthropic's search provider. Exa's own answer endpoint is not used. When the web is asked, the switch, "Looking that up." and the spoken form stay as option 07 has them.
status: accepted
---

## Solution

Option 07 decides when a spoken request is asked of the web. This option changes how. Today the request goes to the user's own `claude` with WebSearch as its one tool, which searches and writes in one call; the user's hand test took 9 s and 16 s. Instead:

1. **Search.** Varnick calls Exa's search API itself, with the user's Exa key. It sends the request's words and nothing else of the user's, and asks for the top 5 results with Exa's highlights: the passages of each page that bear on the query.
2. **Write.** The writer the user set in Settings › Text generation writes the answer, the same writer that answers from local rows:
   - Claude Code (the default) writes it on the user's plan;
   - this Mac's Gemma writes it on this Mac;
   - a model server writes it there.

   It reads the numbered results only. It answers in one or two spoken sentences, naming the source in a few words, and starts with the number of the result it used. A reply that names no result is spoken as "I couldn't confirm that on the web.", so a writer can't pass off its own knowledge as a source.
3. **Speak.** As today: option 06's cleaning, the first two sentences, after "Looking that up.".

Exa's own `/answer` endpoint, which writes an answer with Exa's model, is not used. The writer is the user's Text generation choice, as decided.

## Trade-offs

- **Much faster, estimated.** An Exa search is one HTTPS call, estimated at 0.5–1.5 s, and the writer then makes one call of its own. A web answer is estimated at about 4–6.5 s after speech ends with Claude Code writing, and about 3–5 s with Gemma. The hand test of Claude Code with WebSearch took 9 s and 16 s. None of this is measured yet (the eval below).
- **One web path for every writer.** A Gemma or server user gets web answers too, without Claude Code logged in. Their words then go to Exa and to nowhere else.
- **Who sees the request changes:**
  - Before: Anthropic got the request with the date, time and units, and Anthropic's search provider got Claude's search words.
  - Now: Exa gets the request's words alone. Whoever runs Text generation gets the request, the date, the time, the units and the results: Anthropic with Claude Code, nobody else with this Mac's model, the user's own server with a server.
  - Exa keeps what it is sent under its own terms. It offers no-retention only on its Enterprise plan.
- **A key and a small cost per answer.** Exa is pay-as-you-go:
  - about $0.007 per `fast` search and $0.004 per `instant`, at its published rates of 2026-10-14;
  - each response states its exact cost;
  - a free $10 a month covers about 1,400 `fast` searches.

  With no key saved there are no web answers. The writer's call counts toward Claude Code's plan, as a local answer does: one call, not the two or three turns and the search call WebSearch made.
- **Exa replaces Claude Code's WebSearch,** the planner's recommendation, for the user to confirm.
  - Keeping WebSearch as a second path, for Claude Code users with no Exa key, would keep the text helper's tool, its turn limit, its own deadline and a second privacy story, for one setup.
  - Dropping it brings the helper back to ADR 0029's no-tools lever.
- **Quality is unmeasured.** WebSearch let Claude search twice and read Anthropic's search provider's results. Here the writer reads Exa's top 5 highlights once. A question whose answer isn't in those passages gets "I couldn't confirm that on the web." The eval compares the two.
- **Gemma's weakness, honestly.** The judge eval found this Mac's Gemma 4 E2B answering from its own knowledge as if from a page: "The capital of Australia is Canberra. This information was last visited 3 weeks ago."
  - The prompt answers only from the numbered results, and the result tag catches a reply that names no result.
  - It does not prove the claim is in the result it names. A small model can still name [1] and state what it remembers.
  - It also costs answers when a writer forgets the tag.
  - The eval counts both. Until then, a Gemma web answer is the weakest kind of answer Varnick gives.

## User Stories

1. As a Varnick user, I want a web answer in a few seconds, not ten or more.
2. As a Varnick user with Text generation on this Mac or on my server, I want web answers too, written by the model I chose, without Claude Code.
3. As a Varnick user, I want only the words I said sent to the web search, with my own Exa key, and nothing from my history, bookmarks, sessions or screen.
4. As a Varnick user, I want a web answer to say where it came from, and to say it couldn't confirm when the results don't say, rather than guess.
5. As a Varnick user, I want to save my Exa key once in Settings, kept in the Keychain and never shown again.
6. As a maintainer, I want `Varnick --ask` to print the Exa results' titles and sites, the search's time and cost, the writer's place and time, and the reply's kind.

## Implementation Decisions

**Where it sits.** Option 07's "Answer from the web" step, unchanged in when it runs:
- nothing kept, or the writer escalates;
- never for a request that stays local;
- only after the hold;
- "Looking that up." said as 07 says.

What runs is this search and this writer, in place of the text helper's call with WebSearch.

**The search** (Exa's `POST /search`; the user's own code in another project already calls it this way)
- **The key** goes in the `x-api-key` header to `https://api.exa.ai`, and nowhere else. No redirect is followed.
- **The request body:**
  - `query`: the request's words as said after the wake phrase, cut to `SpokenText.maxRequestCharacters`. It is the same text option 06 sent to Anthropic. Exa reads natural language, so filler is left in.
  - `type`: `fast`, Exa's mode for user-facing search, as a named constant. `instant`, the mode Exa names for voice agents, is cheaper and quicker and may be shallower; the eval compares the two.
  - `numResults`: 5, the most the writer reads.
  - `contents`: highlights, with a character cap per result (a named constant, about 600) so five results fit a small model's prompt. Default freshness: cached pages when Exa has them, fetched otherwise.
- **Not sent:**
  - No date filter: Varnick can't tell a question whose page changes daily (a score) from one whose old page is right (opening hours), and a filter would drop the latter. The results' published dates go to the writer instead.
  - No location, domain or category filter.
  - Nothing from History, Bookmarks, sessions or the screen.
- **Deadline 4 s** (a named constant). Past it: "I couldn't look that up."
- **No results:** "I couldn't find that on the web."
- **Logs:** never the query, the results or the key. The timing line has the search's time, Exa's own `searchTime`, the result count, `costDollars`, and a failure's status code.
- **Failures:**
  - A 401, 402 or 403 is the key's problem, a rejected key or an empty balance: "Exa didn't accept the key." It also shows in Settings beside the key, as an ElevenLabs failure does.
  - Any other failure: "I couldn't look that up."

**The writer**
- `TextGeneration.generateNow`, as for an answer from local rows: whichever writer Settings › Models chooses, with its usual fallback to this Mac's model when Claude Code fails or rests.
- **Its prompt** (one place, tuned with `--ask`) carries over option 06's rules for speech:
  - one or two short sentences, with no lists, markdown, links or addresses;
  - today's date and time, and the unit system;
  - times, numbers and units written as they are said;
  - name where the answer comes from in a few words;
  - say when the results disagree or look out of date;
  - say which place is needed when the question names none;
  - reply only UNABLE for something to do.
- What changes: there is no searching, and it reads numbered results.

  ```
  Results:
  [1] <title> (<site>, published <date in words, when known>)
  <highlights, cut>
  [2] ...

  Answer only from the results above, never from what you know.
  Start your reply with the number of the result you used, in brackets, such as [2].
  If the results don't say, reply with only NOT_CONFIRMED.
  If the answer depends on a place the question doesn't name, reply with only NEED_PLACE.
  ```

- **Reading the reply:**

  | Reply | Said |
  |---|---|
  | UNABLE | the can't-do line |
  | NOT_CONFIRMED | "I couldn't confirm that on the web." |
  | NEED_PLACE | "Which place do you mean? Ask me again with it." |
  | Starts with the number of one of the results | the rest, through option 06's cleaning and its two-sentence cut, with the tag removed |
  | Anything else, including a number that isn't a result | "I couldn't confirm that on the web." |

  Writer failures are said as Text generation's are today ("Text generation isn't set up.", and the rest).
- Up to 5 results, each cut to the highlight cap.
  - With Claude Code writing, the prompt is about 1,500 tokens.
  - With this Mac's model, the prompt's size is what costs time: prefill dominates.

**The text helper**
- If the user confirms Exa replaces WebSearch, the helper's tools, turn limit and per-request deadline go, and so do Claude Code's web call and its "Claude Code isn't answering, so I can't look that up." line.
  - Every helper call is then a Text generation call again, with no tools.
  - The helper's check script keeps its no-tools check, and its with-a-tool checks go.

**Settings**
- **Keys:** an **Exa** row under Settings › Models › Keys.
  - The key is kept in the Keychain only (account `EXA_API_KEY`), as ElevenLabs's is: never read from the environment or a `.env`, never logged, never shown after saving.
  - Saving it sends nothing. The first call is the first spoken question that reaches the web.
- **Answer from the web needs:**
  - Hey Varnick;
  - the relevance filter on TypeSafe with a key (option 07's judge);
  - an Exa key saved;
  - Text generation able to write, as Hey Varnick needs.

  Claude Code logged in is no longer one of them. Each need shows beside the switch, as today.
- **The switch's detail,** in substance: what your pages, bookmarks and sessions can't answer is looked up on Exa with your key, and written by the Text generation you chose. Only the words you say go to Exa. Your words and the results go to wherever Text generation runs. Each search uses your Exa credits.
- Turning the switch on with a key saved is the consent to send the request's words to Exa, as choosing TypeSafe is for TypeSafe. There is no prompt per request.

**Privacy and logs**
- **Exa:** the request's words, at most 500 characters, with the key. Nothing else of the user's.
- **The writer:** the request, today's date and time, the unit system, and the results' titles, sites, published dates and highlights, to wherever Text generation runs.
- **No longer:** the request to Anthropic's search provider, and Claude Code's WebSearch description with the current month.
- **The docs:**
  - The privacy doc's Answer from the web section is rewritten for Exa.
  - Its Text generation section says web answers go wherever Text generation runs.
  - The Settings text changes as above, and README's list of services gains Exa.
- **Logs:** never the request, the query, a result, the reply or the key.

**Command line**
- `--ask` prints a `web:` line with:
  - the search's time and `costDollars`;
  - each result's title and site;
  - the writer's place and time;
  - the reply's kind (answer with its result number, UNABLE, NOT_CONFIRMED, NEED_PLACE, untagged).

  Then `says:`. Nothing is spoken. Request files are personal.

**Latency, estimated** (from the end of speech, for a request whose rows kept nothing; the eval measures it)
- The hold ends at about 1.5–2.5 s, with the search and judge done during it (option 07). "Looking that up." is heard from about 2–3 s.
- The Exa search, estimated at 0.5–1.5 s with `fast`, less with `instant`. Exa's docs give no figure, so this is a guess to be measured.
- **The writer:**
  - Haiku through Claude Code took 1.65 s at the median and 2.41 s at p90 for local answers in the judge eval. With a longer prompt, call it 1.8–2.6 s.
  - This Mac's Gemma, mostly prefill at the reported 2,200 tokens per second: about 0.7–1.2 s.
  - A server: unmeasured.
- **The answer is heard** at about 4–6.5 s with Claude Code and about 3–5 s with Gemma. Against that, today's call measured 9 s and 16 s in the user's hand test, and option 06 estimated 6–10 s.
- When the writer escalated first (option 07), add that first call: about 1.7–2.4 s with Haiku, and about 0.2–0.3 s with Gemma.

**State**
- One Keychain item, `EXA_API_KEY`. No new UserDefaults key: the switch is option 06's. `sessions.json` is unchanged.

## Testing Decisions

- **An eval next, for information, not a gate** (agent-lab, through the `eval` agent, with the user's Exa key; Varnick pinned by commit).
  - **The set:** the routing eval's 30 world questions. The eval writes an answer key from the live web when it runs and notes the date, since hours and scores change.
  - **The arms:**
    - Exa `fast` with Haiku 5.5 writing;
    - Exa `fast` with this Mac's Gemma 4 E2B writing;
    - Exa `instant` with each;
    - option 06's Claude Code with WebSearch, as the baseline.
  - **What it measures:**
    - each step's time and the total;
    - how many answers are right;
    - how many are grounded, with the claim found in the cited result's highlights;
    - how often the result tag is missing;
    - how often the answer is "couldn't confirm";
    - Gemma's answers from its own knowledge;
    - the cost, from `costDollars` and the writer's usage.
  - It informs `fast` against `instant`, the highlight cap, and whether the result tag stays for Gemma.
- **No test target.** Pure seams for a first test:
  - the Exa request body for a request;
  - the results to the writer's numbered block;
  - reading the writer's reply (tag, markers, untagged) into what is said;
  - Exa's failure statuses to their lines.
- **By hand, after the user restarts Varnick,** with an Exa key saved, Answer from the web on and Text generation on Claude Code. The user speaks; agents don't drive the screen.
  - A world question: "Looking that up.", then an answer naming its source, sooner than before.
  - "What's the weather": "Which place do you mean? Ask me again with it."
  - Something unlikely to be on the web: "I couldn't confirm that on the web."
  - Text generation on this Mac: a world question is written by Gemma, and the timing line names this Mac.
  - Claude Code logged out, Text generation on this Mac: web answers still work.
  - A wrong key: "Exa didn't accept the key.", and Settings shows it.
  - Network off: a request whose rows kept nothing gets "I couldn't look that up." within the deadline.
  - Varnick's log holds no request, result or key.
- **Hand checks for the builder** (unverified; with the user; figures and requests stay in `.scratch/listening-never-answers/`):
  1. Latency on about 10 world questions, with Claude Code and with Gemma writing, from the timing line.
  2. How often Gemma's web answers are untagged or "couldn't confirm".

## Out of Scope

- Exa's `/answer` endpoint: it writes the answer with Exa's model, which decision 2 rules out.
- Reading a whole page (`/contents`), or a second search when the first doesn't answer.
- Sending a location, a date filter or domain lists to Exa (Later, if the eval or use shows the need).
- Any other search provider, and WebSearch as a second path (unless the user chooses to keep it).
- Changing when the web is asked (option 07).

## Further Notes

- **Decided by the user on 2026-10-14,** relayed by the coordinator:
  1. "I have an Exa key, let's introduce this as something we accept." Exa becomes a web search source Varnick calls itself, with the user's own key.
  2. "The text generation should be something we set, and it's used based on what is set." The writer of a web answer follows Settings › Text generation, as answers from local rows do.
- **The planner's choices,** which follow from those:
  - The search and the writing are split, and `/answer` is not used, since it would make Exa the writer.
  - Exa replaces WebSearch, for the user to confirm (below).
  - The result tag and NOT_CONFIRMED guard against a writer answering from memory.
  - No date filter and no location are sent.
- **Siblings:**
  - The key copies ElevenLabs's (ADR 0033): Keychain only, header only, no redirect, a failure note in Settings.
  - The call copies the user's own Exa client in another project: `POST /search` with highlights, reading `costDollars` and `searchTime`.
  - The writer is `TextGeneration.generateNow`, as option 07's answers use it.
- **Branch: build on `main` after option 07 merges,** on a branch of its own tied to option 08.
  - Option 07 is in hand test and works. This changes one step behind a clear seam: the web answer's call and the helper's tools.
  - Joining 07's branch would hold 07's merge for Exa and mix two reviews.
  - The cost is that `main` carries the WebSearch path until 08 removes it.
  - Option 07's text is not edited now, so its merge stays clean. After the merge, 07's web step gets a note that option 08 replaces it.
- **ADR, to write now that this is accepted:** web answers search Exa with the user's own key and are written by the Text generation writer, with only the request's words sent to Exa. It amends:
  - ADR 0036's web step (option 06's call through Claude Code);
  - ADR 0029: the text helper goes back to no tools, if WebSearch goes.
- **Glossary, proposed:** a **Web answer** is the answer to a **Spoken request** written from Exa's results by the Text generation writer. _Avoid_: Exa answer (Exa's `/answer` is not used).
- **`where-it-breaks.md` items this touches:**
  - **The Exa key:** Keychain only, header only, no redirect.
  - **What goes to Exa:** the request's words only. Anything more is a privacy change, needing the privacy doc and the Settings text.
  - **The writer's reply:** read by its tag and markers; an untagged reply is never spoken as an answer.
  - **The text helper:** back to no tools.
- **Left to the user,** recommendation first:
  1. **Exa replaces Claude Code's WebSearch entirely?** Yes: one path for every writer, faster, a simpler privacy story, and the text helper back to no tools. Otherwise WebSearch stays as the path for Claude Code users with no Exa key, at the cost of two paths.
- **Verified:**
  - **Exa's docs, read 2026-10-14:**
    - `POST /search` takes `x-api-key` or a Bearer token;
    - `type` is `instant`, `fast`, `auto` or the deep types, and `instant` is the one Exa names for voice agents;
    - highlights are passages Exa picks per page, with a character cap;
    - `maxAgeHours` and published-date filters exist;
    - `userLocation` exists;
    - each response has `costDollars` and `searchTime`;
    - the prices are as above, and the free tier is $10 a month;
    - `/answer` is a separate endpoint at $5 per 1,000.
  - **In Varnick, on option 07's branch at `6550890`:**
    - the web call is `ClaudeCodeState`'s, through the text helper with `tools` and `maxTurns` and a 15 s deadline;
    - the switch needs Claude Code logged in;
    - the web prompt and its cleaning are in one place.
  - **On `main`:**
    - `TextGeneration.generateNow` picks the writer from Settings at each use;
    - ElevenLabs's key is Keychain only.
- **Inferred, not measured:**
  - every latency figure, Exa's above all;
  - the answers' quality against WebSearch's;
  - how well each writer keeps to the results and the tag;
  - whether highlights add to Exa's per-request price;
  - Exa's status codes for a rejected key and an empty balance.
