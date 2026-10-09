# A spoken request is filtered as a typed search is

A spoken request runs the relevance filter wherever Settings › Search says, as a typed `?` search does, through one module, `RelevanceSearch`, that the panel and the spoken request both call. This amends ADR 0015, whose "the relevance filter does not run on a spoken request" no longer holds, and ADR 0016, whose "only the request text goes to TypeSafe; no rows, no search words" no longer holds. The user chose it after a descriptive request was answered from pages the filter would have demoted: the answer step only judges the few rows it is given, and the page that fit was not among them. The problem and its options are in `docs/problems/spoken-answers-skip-the-relevance-filter/`; this records option 01.

## What goes to TypeSafe

- **With the filter on TypeSafe and a key saved:** the request text for the decide step (ADR 0016, unchanged), then the request's search words and the title, site and the page's own description of its first 20 pages, as a typed search sends them. New: ADR 0016 rejected sending rows.
- **With the filter On this Mac, or off:** nothing leaves, as before. On this Mac never falls back to TypeSafe.
- **A request that reads sessions only skips the filter.** Sessions, folder and project names never go to any judge.

## What it reads and says

When the filter judged any page of the chosen kind relevant, only those pages are read, best first, up to five; otherwise the top pages as ranked are read, as before. An answer to a request for several results (it asks for others or similar ones, or "which pages") names up to three in up to three short sentences; one thing gets one or two.

## The module

`RelevanceSearch` holds the ranking rules (fusion, the session floor, sessions open here first, the 20-page cut, the threshold, which judge runs) as three passes that each take the last ranking and give the next: keyword, meaning, filter. It sets no status, waits for nothing and logs nothing. The panel calls the passes one at a time with its own debounce and the judge's pause between them, and keeps its statuses, selection and log lines; a spoken request calls them back to back, since nobody is typing. A pass that fails costs only itself.

## Considered Options

- **Option 02: filter a spoken request only On this Mac.** Keeps ADR 0016's promise that only the request text reaches TypeSafe, but the checkpoint On this Mac measured no gain over no filter on searches that describe a page, which is most spoken requests. The user chose option 01.
- **Judge sessions too.** Rejected: a session holds the user's prompts, which never go to a judge.
- **A shorter deadline for the filter on a spoken request.** Left for later: TypeSafe's request waits up to 5 s where the decide step gives Jev 1.5 s; the timing line shows how often it matters.

## Consequences

- With the filter on TypeSafe, every spoken request sends page rows to a third party. The filter's backend is the one switch for what TypeSafe sees, typed or spoken. Settings, the README and SECURITY.md say so.
- The filter is a pass the user waits on, shown in the timing line and in `Launchy --ask` with who filtered. On this Mac a spoken request can load the relevance model beside Gemma and the embedder.
- A page wrongly judged irrelevant is not heard when another was judged relevant. The panel still shows it under "Less relevant"; speech has no room for that.
- A change to the panel's passes now reaches Hey Launchy without being copied by hand. The panel must behave as it did: `--search-eval` and `--search` before and after.
- The wording of the answer prompt is tuned for a small model and brittle: a one-clause change flipped answers to requests that nothing fits and to requests for several. Re-check with `--ask` after touching it.
- Amends ADR 0015 and ADR 0016.
- Decide, search and filter start when the request's last final result arrives and run through the wait that ends it (`SpokenRequests.hold`); only the answer and the speech wait for the end. More speech cancels the run and starts another on the new text, so a partial request may be sent to Jev, and its search words and pages to TypeSafe, and then discarded. It is the same data as an unhurried request sends, for text that was not the whole request.
