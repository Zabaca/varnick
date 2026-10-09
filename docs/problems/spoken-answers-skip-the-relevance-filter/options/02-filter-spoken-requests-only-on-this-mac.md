---
problem: spoken-answers-skip-the-relevance-filter
title: The same relevance search, but a spoken request is filtered only On this Mac
summary: Option 01's module, rows and answer, with one difference. A spoken request runs the relevance filter only when it is set to On this Mac. With the filter on TypeSafe the spoken search stays unfiltered, so ADR 0016's promise holds and only the request text goes to TypeSafe. The case seen, with the filter on TypeSafe, isn't fixed unless the user switches the filter to On this Mac.
status: proposed
---

## Solution

Everything is option 01's (the module, the panel's use of it, the rows read, the answer for several results, the timing) except which judge a spoken request may use:

- **On this Mac:** the spoken request runs the filter on this Mac, as option 01.
- **On TypeSafe:** the spoken request skips the filter and reads the top pages as ranked, as today. Nothing more goes to TypeSafe than the request text for the decide step.
- **Off:** no filter, as today.

The panel is unchanged by this: a typed search is filtered wherever Settings says.

## Trade-offs

- **Keeps ADR 0016 as written.** No page row of a spoken request leaves the Mac. No privacy text changes beyond saying that spoken requests use the filter On this Mac.
- **Misses where the filter helps most.** On searches that describe a page, TypeSafe gained +0.115 to +0.191 MRR and the checkpoint on this Mac gained nothing measurable (relevance-filter-needs-typesafe). Spoken requests are mostly of that kind, and the case seen was on TypeSafe.
- **One setting, two meanings.** "The relevance filter on TypeSafe" would filter typed searches and not spoken ones, which Settings has to explain, and which differs from what the user asked for: the same mechanism as the panel.
- Latency and memory as option 01, but only with the filter On this Mac.

## User Stories

1. As a Launchy user with the filter on TypeSafe, I want what I say to send nothing to TypeSafe beyond the request text, as ADR 0016 promised.
2. As a Launchy user with the filter On this Mac, I want spoken requests filtered on this Mac.
3. As a maintainer, I want the ranking rules in one place, as in option 01.

## Implementation Decisions

- As option 01, with the spoken request asking the module for its judge only when the filter is On this Mac.
- The timing line and `--ask` say "TypeSafe, not used for spoken requests" when that is why no filter ran.
- Documents: where-it-breaks, the glossary and the Settings text for Hey Launchy. ADR 0015 is amended; ADR 0016 stands.

## Testing Decisions

As option 01, plus: with the filter on TypeSafe, `--ask` shows the filter skipped, and nothing but the decide call goes to TypeSafe.

## Out of Scope

As option 01.

## Further Notes

- The privacy-preserving reading of the user's request of 2026-10-08. If the user accepts option 01, this one is rejected.
