# A spoken request's decide step asks TypeSafe's Jev

The first step of a spoken request, where to look and what to look for, is decided by TypeSafe's Jev only when the relevance filter is set to TypeSafe and a key is saved; otherwise Text generation (ADR 0015's Gemma) decides and nothing goes to TypeSafe. The user chose this after a spike on made-up requests: measured locally, Jev picked the right source for more of them than Gemma did, in about a tenth of the time, and flagged requests that are about none of the user's things (the weather, a timer). Gemma still reads the rows and writes the spoken answer. This amends ADR 0015, whose "nothing goes to TypeSafe" held for every step.

## What goes to TypeSafe

- **Only the request text**, as heard after the wake phrase and cut to 500 characters. No history, bookmark or session titles, no folder or project names, no rows, no search words and no answer.
- **Only with the relevance filter on TypeSafe.** A key alone isn't enough: with the filter On this Mac or off, or with no key, Gemma decides. The user's choice of the filter's backend is the choice of whether TypeSafe sees anything.
- Two questions are asked of it in one call, on a pinned model version (the alias moves, and the questions were measured on one version): which source fits the request, and whether it is about none of the user's things. Jev gives a probability for each source. The request's search words are not asked of it: Varnick strips filler words in code, which matched Jev's own word-by-word judgments in the spike.
- **Project names stay here.** Jev reads a name it has not heard of as a web topic, so "what is <a project>" went to History. Varnick corrects this locally and sends nothing to do it: a request that holds the words of one of the user's session folders, or a chance of sessions of 0.1 or more, adds sessions to the rows read.

## Off-topic

When Jev puts the request at "other" (0.5 or more), Varnick says "I only look up your pages, bookmarks and Claude sessions." at once, with no search and no Gemma, and writes it to the transcript like the other spoken lines. When Gemma decides there is no such signal and every request is searched, as ADR 0015 says.

## Fallback

No key, the filter not on TypeSafe, a network error, a status other than 200, no source in the reply, or an answer slower than a short timeout all give the Gemma decide ADR 0015 describes. The spoken request never waits on TypeSafe longer than the timeout.

## Considered Options

- **Keep Gemma for decide.** Cheaper on privacy: nothing leaves the machine. The user chose Jev for accuracy and time, but only where the filter is already on TypeSafe.
- **Jev whenever a key is saved.** Rejected by the user: a key stored for another reason would send what the user says to a third party, against a filter set to On this Mac.
- **Send the rows or project names so Jev can judge them.** Rejected: History, Bookmarks and session text are the user's most private data, and ADR 0015 kept them out of any cloud service.
- **Ask Jev for the search words too.** Rejected: no better than the local strip, one question more per word.
- **Search an off-topic request anyway.** Tried first; the answer step said plainly that nothing fit, but only after a search and a second model call. A fixed line is faster.

## Consequences

- Hey Varnick is no longer wholly local when the filter is on TypeSafe. The request, in the user's own words, reaches a third party on every spoken request. Settings › Listening and the TypeSafe rows say so, and so do the README and SECURITY.md.
- The decide step then needs the network. Without it, or on the other filter settings, it costs what it cost before, 1 to 2 s on this Mac.
- Jev's source probabilities shift a little between runs; a chance of sessions near the floor can fall on either side of it from one run to the next, so the same request may read sessions in one and not the other.
- The `spoken request timing` log line names who decided and, when Text generation did instead, why Jev was not used. It logs durations and kinds only.
- Amended by ADR 0017: after the decide step the request is searched and filtered as a typed search is, so with the filter on TypeSafe the search words and the title, site and description of the first 20 pages also go to TypeSafe. "Only the request text" holds for the decide step alone; Jev's call still carries nothing else.
- Amended by ADR 0019: with Point at the screen on, the decide step's questions gain `screen` and `point`. A screen request makes a second Jev call carrying the window's title and its elements' labels, kinds, groups and nearby text. Pointing needs this same gate, and Gemma never points.
- Amended 2026-10-09 by the user's principle: choosing TypeSafe is consent to send what a TypeSafe-backed feature needs, Launchy's own panel and session or project names included. Keeping things private is the On this Mac setting. Each new kind of data still gets a line in Settings, the README and SECURITY.md. This lifts "Project names stay here" and the rejected "send the rows or project names" for TypeSafe-backed features.
- Amended by ADR 0036: the route no longer decides where to look. Every request searches every source; Jev's probabilities only order the rows, "other" cuts a thing to do short with a fixed line, and the screen choice sends a request about the screen to the screen. The Text generation fallback for the decide step is gone, and so is the off-topic refusal: an off-topic request is searched like any other, and what the rows can't answer goes to the web when the user has turned that on. A second Jev call judges the rows (ADR 0036).

## Amendment, 2026-10-16: the voice session

With Voice session on, no decision of a spoken request is asked of Jev: the route is not asked, and Claude decides in the voice session. See [ADR 0042](0042-a-spoken-request-is-answered-by-the-hosts-voice-session-one-hidden-claude-session-in-home-with-permissions-skipped.md).
