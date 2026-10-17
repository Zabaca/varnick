---
title: Hey Varnick answers from results the relevance filter would demote
description: A spoken request reads the top five pages of the panel's ranking as they stand before the relevance filter, the pass that moves the pages that match a search to the top. The panel's `?` search runs the filter and Hey Launchy doesn't, so the spoken answer can name a page the panel shows under "Less relevant" and miss the one the panel puts first. The answer also names one result even when the request asks for several.
impact: The user hears a confident answer that names the wrong page, and has to open the panel and type the search to find the right one, which is what Hey Launchy is meant to spare them. Spoken requests tend to describe a page rather than name it, and that is where the filter helps most (on TypeSafe, +0.115 to +0.191 MRR on searches that describe a page without its title's words; see relevance-filter-needs-typesafe).
severity: mid
evidence: One spoken request on 2026-10-08, at commit f210f1f with the relevance filter on TypeSafe, that described a programming language by what it is for rather than by name. The five pages read left out the page the user meant, and the answer named another. The same words typed as a `?` search put the meant page among the relevant ones and the named page under "Less relevant". The request and the pages are the user's and are kept locally. Code read on 2026-10-08 at f210f1f.
status: closed
---

## Today

All of this was read in the code at f210f1f.

**The panel's `?` search** runs three passes, each refining the last:

1. keyword matches, at once;
2. matches by meaning fused in, after a 120 ms typing pause;
3. the relevance filter. The first 20 pages go to the judge Settings › Search picks: TypeSafe with a key, or this Mac's relevance model when it is installed. TypeSafe is asked 1 s after the last keystroke, so a keystroke cancels it before it is paid for; this Mac's model right after the meaning pass. Pages judged 0.5 or more move to the top, best first. The rest keep their order below, under "Less relevant". Sessions are never judged, and a search under 3 characters isn't filtered.

The filter's pick of judge, its 20-page cut, the threshold and the reordering live in the panel's own code, beside its statuses, selection and pauses. Only the fusion of passes 1 and 2 is shared.

**A spoken request** (listening-never-answers option 01, ADR 0015, ADR 0016):

1. decides where to look: TypeSafe's Jev with the filter on TypeSafe and a key, otherwise Text generation;
2. runs passes 1 and 2 apart from the panel, with no relevance filter (a default of option 01, not the user's choice), and takes the top rows of the chosen source: up to 5 pages, up to 3 sessions;
3. has Text generation write one or two sentences naming the one result that fits best, which Launchy speaks.

So the answer step judges only the five rows it is given. When the page the user meant is ranked sixth or lower before the filter, the answer can't name it.

**What leaves the Mac today.** With the filter on TypeSafe, a typed `?` search sends its words and the title, site and own description of its first 20 pages to TypeSafe. A spoken request sends only its text, for the decide step; ADR 0016 rejected sending rows. With the filter On this Mac or off, neither sends anything to TypeSafe.

**One answer only.** The answer prompt asks for the page or session that best fits, in one or two sentences, so a request for several ("are there other pages like this one") hears one.
