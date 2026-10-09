---
problem: spoken-answers-skip-the-relevance-filter
title: One relevance search that the panel and Hey Launchy both call
summary: The panel's ranking (keyword, meaning, then the relevance filter over the first 20 pages) moves into one module that returns ranked rows with the filter's verdicts and shows nothing. The panel calls its passes one at a time and keeps its pauses, statuses and selection; a spoken request calls them back to back and reads only the pages judged relevant when there are any. The filter runs where Settings › Search says, for a spoken request as for a typed one, so on TypeSafe a spoken request's search words and its first 20 pages' titles, sites and descriptions now go to TypeSafe, which ADR 0016 ruled out. The answer names up to three results when the request asks for several.
status: proposed
---

## Solution

**One module, three passes.** A relevance search takes search words and returns a ranking: up to 3 sessions and up to 40 pages, fused apart as today, and once filtered, each judged page's probability, how many pages lead as relevant and who judged. Its passes:

1. keyword matches;
2. the same with the words' meaning fused in, or nothing when no embedder can answer;
3. the relevance filter: the first 20 pages go to the judge Settings picks. Pages at 0.5 or more move to the top, best first, and the rest keep their order below. Sessions are never judged, and words under 3 characters aren't filtered.

The module holds the ranking rules: the fusion, the session floor, sessions open here first, the 20-page cut, the threshold, and which judge runs. It shows nothing, sets no status, waits for nothing and logs nothing about the words. Each caller does those its own way.

**The panel** calls the passes as its search does today: keyword on the keystroke, meaning after its 120 ms pause, the filter after the judge's own pause (1 s after the last keystroke on TypeSafe, none on this Mac). It keeps its statuses, who answered, the selection, the task a keystroke cancels and its log lines. Nothing the panel shows changes.

**A spoken request** calls the three passes back to back with no pause, since nobody is typing. It skips the filter when it reads sessions only. A pass that fails costs only itself, as in the panel: meaning failing leaves the keyword matches, and the filter failing leaves the fused order.

**What it reads.** When the filter judged any page of the chosen kind relevant, only those are read, best first, up to five. When it judged none, or didn't run, the top pages as ranked are read, as today. Sessions are read as listening-never-answers option 01 says: alone, ahead of the pages or behind them.

**What it says.** For a request about one thing, the answer names the one result that fits best in one or two sentences, as today. For a request for several, or for others like something ("are there any other…", "which pages…"), it names up to three that fit, best first, in up to three short sentences. When none fits it says so.

**Where data goes.** The filter goes where Settings › Search sends it, for a spoken request as for a typed one:

- On TypeSafe: a spoken request's search words, and the title, site and the page's own description of its first 20 pages, go to TypeSafe, as a typed `?` search's do. This is new: ADR 0016 sent the request text alone and rejected sending rows.
- On this Mac, or off: nothing leaves, as today.

Sessions, folder and project names still never go to any judge. The decide step is unchanged.

## Trade-offs

- **Fixes the case seen,** where the filter was on TypeSafe, and wherever the filter already helps typed searches.
- **One home for the ranking rules.** A change to the panel's passes reaches Hey Launchy without being copied by hand, which where-it-breaks asks for today.
- **Privacy.** With the filter on TypeSafe, every spoken request now sends page rows to a third party, which ADR 0016 promised it wouldn't. The filter's backend stays the one switch for what TypeSafe sees, typed or spoken. With the filter On this Mac or off nothing changes.
- **Latency.** The filter is a pass the user now waits on:
  - TypeSafe: a round trip of 0.12 s at the median (0.16 s p90), measured on 2026-10-03 before descriptions were added, and up to 5 s when it fails;
  - this Mac: tens of milliseconds warm, measured on an M3 Ultra, more on smaller Macs, plus about 0.2 s and shader setup to load after 10 idle minutes.

  Reading only the relevant pages shortens the answer prompt, which may win some of it back. An answer naming three results takes more tokens.
- **Memory.** On this Mac, a spoken request can now load the relevance model (about 0.85 GB at peak) beside Gemma and the embedder.
- **Trusts the filter's no.** A page wrongly judged irrelevant isn't heard when another was judged relevant. The panel still shows it under "Less relevant"; speech has no room for that.
- **Little gain On this Mac on descriptive requests.** The checkpoint measured no gain over no filter on searches that describe a page (relevance-filter-needs-typesafe), and spoken requests are mostly of that kind.
- **The panel's search is restructured.** It must behave exactly as before, and the eval checks that.

## User Stories

1. As a Launchy user, I want Hey Launchy to name the page the panel would put first for the same words, so that the answer matches what I'd find by typing.
2. As a Launchy user who asks "are there any other pages like this one", I want to hear up to three named, best first, so that I hear the alternatives.
3. As a Launchy user who asks for one thing, I want one answer, as short as today's.
4. As a Launchy user with the filter On this Mac, I want spoken requests filtered on this Mac too, with nothing leaving it.
5. As a Launchy user with the filter on TypeSafe, I want Settings and the README to say that a spoken request sends its search words and top pages to TypeSafe, as a typed search does.
6. As a Launchy user with the filter off, I want spoken requests to work as they do today.
7. As a Launchy user, I want a spoken request about my Claude sessions to send nothing to a judge, since sessions are never judged.
8. As a maintainer, I want the ranking rules in one place, so that the panel and spoken requests can't drift.
9. As a maintainer, I want `--ask` and the timing line to show the filter's time and who filtered, so that I can see what it costs.

## Implementation Decisions

- **The module's interface:** a ranking value and its three passes, each taking the last ranking and giving the next, plus the judge Settings picks for some words. The keyword matches ride inside the value so the meaning pass can fuse them again. The module picks the judge, so the rule "TypeSafe only with the filter on TypeSafe and a key; On this Mac never falls back to TypeSafe" has one home.
- **Its dependencies come in:** the search store, the query embedding call the panel uses now (the server-or-this-Mac rules stay in that call), the rows of the sessions open in a pane here, and this Mac's relevance model.
- **No pauses inside.** The 120 ms debounce and the judge's own pause are the panel's: they exist so that typing doesn't pay for a pass. A spoken request is already final.
- **The panel's state stays in the panel:** results, selection, the semantic and relevance statuses, who answered and who judged, the cancelled task, and the "no results" log lines, which print the query and so must never run for a spoken request.
- **The prompt's sessions under the prompt line** use the module's fusion and are never filtered: a prompt never reaches a judge.
- **The spoken request's own search goes.** It calls the module's passes, so there is one search, not a copy.
- **The filter's query on a spoken request is its search words,** as the panel's filter gets what was searched. The request text still goes only to the decide step.
- **Which rows are read** is a pure rule over the plan, the sessions, the pages and how many pages lead as relevant, so a first test can cover it.
- **The answer:** up to three short sentences, with a token budget about half again today's, tuned with `--ask`.
- **The timing line and `--ask`** gain the filter's time and who filtered, or why it didn't run (off, sessions only, the failure's kind). Durations and kinds only, as now.
- **Documents:** a new ADR amending ADR 0015 (whose "the relevance filter does not run on a spoken request" no longer holds) and ADR 0016 (what goes to TypeSafe); the README's Privacy section, SECURITY.md, the Settings text for Hey Launchy and both TypeSafe rows, the Relevance filter entry in the glossary, and where-it-breaks.

## Testing Decisions

- There is no test target. The seams for a first test: the module's three passes with a made-up store, embedder and judge; and the rule for which rows a spoken request reads.
- **The panel must not change.** Before any code, record `--search-eval` and `--search` on made-up terms with the filter off and On this Mac. After the move they must match exactly. On TypeSafe, MRR within its run-to-run noise (about 0.02).
- **`--ask` on made-up requests** with each filter setting: the filter's line, the rows read and the answer. A sessions-only request shows the filter skipped. A request for several names up to three; one for one thing names one.
- **By hand, after the user restarts Launchy:** a spoken request that describes a page by what it does rather than its name, with the filter on TypeSafe and then On this Mac; and the timing line for it.

## Out of Scope

- Showing the filter's verdicts or the answer in the panel.
- A shorter deadline for the filter on a spoken request. TypeSafe's request waits up to 5 s where the decide step gives Jev 1.5 s; revisit once the timing line shows how often it matters.
- Filtering only the chosen kind's pages, such as 20 bookmarks for a bookmarks request. The first 20 pages are judged, as in the panel.
- Judging sessions.
- Changing the filter itself: its question, threshold or number of candidates.
- Latency work beyond timing the new pass.

## Further Notes

- **Asked for by the user on 2026-10-08,** relayed by the coordinator: Hey Launchy ranks with the same mechanism as the panel, the relevance filter on TypeSafe or this Mac per the user's setting, through one relevance search module that both use. Whether that includes sending a spoken request's page rows to TypeSafe is this option's open point; option 02 is the same module without it.
- Listening-never-answers option 01 left the filter out by default ("the answer step already judges which of the few rows fit"). The case above shows the answer step can't judge a page that isn't among the few rows.
