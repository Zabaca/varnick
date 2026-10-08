# Spoken requests are answered locally, aloud only, through Listening

While Listening is on, a mic phrase that starts "Hey Launchy" is a spoken request. Launchy's own three steps answer it: Text generation picks the source and the search words, Launchy runs the panel's ranking apart from the panel, and Text generation writes a one- or two-sentence answer that Launchy speaks in the Voice setting (the system voice unless picked otherwise). The wake phrase is matched on the final text of the mic transcript Listening already produces, so nothing listens while Listening is off. The answer is only heard: the panel doesn't come forward, nothing is selected, nothing opens or starts. Text generation runs wherever Settings › Models says (ADR 0012, ADR 0014), so the request and the rows it reads stay on this Mac or go to the user's own server on the tailnet, and nowhere else. The problem and its options are in `docs/problems/listening-never-answers/`; this records option 01.

## Considered Options

- **A local model calling the sources as tools (option 02)**, **Claude calling them (option 03)** and **a local router that hands work to a Claude session (option 04)**: not built. A fixed three-step flow keeps a 2 B model on rails, needs no tool-call format, and sends nothing to a cloud model, which no Launchy feature does today. They stay proposed.
- **A wake listener of its own (option 05)**: not built. It would keep the mic open without Listening. It is the fallback if wake accuracy on the transcript is poor (a hand check).
- **Showing the answer in the panel and opening it with ↩**: left for later. The user chose speech only, so a misheard request costs a sound and a sentence and never disturbs the app in front.

## Consequences

- **Launchy must never hear itself.** The system audio tap excludes Launchy's own process. Mic results whose audio began while Launchy spoke, plus a short tail, are neither transcribed nor checked for the wake phrase (`SpeechSpans`). The speech is rendered by the system synthesizer and played by Launchy's own audio engine, so it always comes from this process; the span is opened before the first sound and closed after the last. Anything that moves the speech out of the process breaks the tap's exclusion, and a long answer, a slow device or a late final all depend on the span.
- **The panel's ranking is shared.** `LauncherModel.searchApart` runs the panel's keyword and meaning passes and the same fusion, and sets nothing the panel shows. The relevance filter does not run on a spoken request, so nothing goes to TypeSafe.
- **Answers only from what a row holds** (title, site or folder, date, description or prompts), never a page's text or Claude's replies, and never the address.
- **Waking is unmeasured.** The match tolerates the mishearings of "Launchy" that start "launch", "lunch" or "lanch" and misses the rest, and the mic also hears speakers. Latency is estimated at 2.5 to 3.5 s warm. Both are hand checks.
- Text generation gains a second consumer that the user waits on, so it uses the interactive rule of `ModelServerState.place` (a server not known to have failed, else this Mac's model) where titles use the background rule. With a server chosen, the request and the rows' text go to it, as session prompts do for Search embeddings.
- The answer is written to the transcript as a `[launchy]` line. This was a default, not the user's choice, and is one call to remove.
- Amended by ADR 0016: the decide step asks TypeSafe's Jev when the relevance filter is on TypeSafe with a key saved, so the request text can leave this Mac. The rows, the answer and the other steps stay as written here.
