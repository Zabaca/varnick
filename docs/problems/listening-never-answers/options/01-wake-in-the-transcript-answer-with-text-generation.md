---
problem: listening-never-answers
title: Wake on the mic's transcript; Launchy searches and Text generation answers aloud
summary: While Listening is on, a mic phrase that starts with "Hey Launchy" becomes a spoken request. TypeSafe's Jev picks the source (Text generation, this Mac's Gemma or the tailnet server, does when there is no key or Jev fails) and Launchy strips the search words. Launchy runs the same search the panel runs, without touching the panel, and Text generation writes a one- or two-sentence answer from the top rows. Launchy speaks the answer in the Voice setting, and that is the whole response: the panel isn't shown and nothing opens. Launchy's own voice is kept out of the transcript and can't wake it. Only the request text leaves the user's machines, to TypeSafe, and only for the decide step.
status: accepted
---

## Solution

A new switch, **Hey Launchy**, in Settings › Listening. With it on and Listening running, each final mic phrase is checked for the wake phrase at its start. Launchy plays a short sound when it wakes. The rest of the phrase is the **spoken request**, and if nothing follows, the next phrase is. Then three fixed steps run, the user's 1, 2, 3:

1. **Decide.** TypeSafe's Jev turns the request into a source (History, Bookmarks or sessions); Launchy takes the search words from the request itself. Text generation does both when Jev can't be asked (ADR 0016).
2. **Read.** Launchy runs the panel's search with those words (keyword and meaning, the same ranking), but apart from the panel: nothing on screen changes. It takes the top rows of the chosen source: their title, site or folder, date and description.
3. **Respond.** A second Text generation call writes a short answer from those rows. Launchy speaks it.

The spoken answer is the whole response. The panel doesn't come forward, focus stays where it was, and nothing opens or starts. Text generation (the answer, and the decide step when Jev can't be asked) runs wherever Settings › Models says, so the rows stay on this Mac or go to the user's own server on the tailnet, and nowhere else. The request text also goes to TypeSafe for the decide step.

Launchy's voice must not be heard back as speech:

- the system audio tap leaves Launchy's own process out;
- mic phrases heard while Launchy speaks are neither transcribed nor checked for the wake phrase.

## Trade-offs

- **Private by construction** (amended by ADR 0016: the request text goes to TypeSafe for the decide step when a key is saved). No new service, key or network path. With Text generation on this Mac nothing leaves it. With a server, the request and the rows' text go to that server, as session prompts already do for Search embeddings on a server (ADR 0014). The relevance filter doesn't run on a spoken request's search, so nothing goes to TypeSafe.
- **Nothing on screen is disturbed.** The panel and the app in front stay as they were, and a false wake costs a sound and a sentence. The flip side: the user only hears the answer. To open the page or session, they bring up the panel and search, or type its name.
- **A small model, kept on rails.** Gemma 4 E2B only fills in two short replies; Launchy runs the steps. Such a small model can pick the wrong source or poor search words. Since the answer is only heard, a wrong search can't be seen. The answer prompt asks the model to say so when no row fits rather than guess.
- **Answers only from what a row holds.** Launchy can say which page or session, from where and when, and what the page's own summary or the user's prompts said. It can't say what a page's text says or what Claude replied in a session.
- **Waking is unmeasured** (a hand check below). The match tolerates the mishearings the prototype saw that start with "launch", "lunch" or "lanch", and misses the rest. If misses are common, option 05 is the fallback.
- **Only while Listening is on,** and only on macOS 26. Listening stays off at each launch.
- **The mic hears the speakers.** Only the mic can wake it, but a video saying "hey launchy" through speakers reaches the mic too. Requiring the phrase at the start of a phrase cuts false wakes from ordinary talk about Launchy.
- **Speech covers what the user says while Launchy talks.** Mic phrases heard while Launchy speaks are dropped, so with headphones on, anything the user says in those few seconds is lost from the transcript too.
- **Latency, estimated rather than measured** (a hand check below). Warm, about 2.5–3.5 s from the end of speech to the first spoken word:
  - the transcriber's final result, 1–2 s;
  - choosing the source, about 0.3 s;
  - the search, about 0.05 s warm;
  - the answer, about 1 s on Gemma at the reported 2,200 tokens/s prefill and 150 tokens/s generation.

  After 10 idle minutes the models have unloaded, which adds about 4 s for Gemma and 1.75 s for the embedder.
- **Memory.** Gemma holds about 2.5 GB while loaded, as for titles. The first spoken request after a launch loads it.

## User Stories

1. As a Launchy user with Listening on, I want to say "Hey Launchy, find the page about MLX shader caching" and hear which page it is and when I saw it, so that I find it without typing.
2. As a Launchy user, I want "Hey Launchy, which of my bookmarks is about Rust lifetimes" answered from my bookmarks only, so that what I saved on purpose comes first.
3. As a Launchy user, I want "Hey Launchy, what was I doing with Claude on the reranker" answered from my Claude sessions, naming the session and when I last used it.
4. As a Launchy user, I want to hear the answer without the panel appearing or my focus moving, so that asking doesn't interrupt what I'm doing.
5. As a Launchy user, I want nothing to open or start when I ask, so that a misheard request costs nothing.
6. As a Launchy user, I want a short sound when Launchy hears "Hey Launchy", so that I know it is listening for my request.
7. As a Launchy user, I want to say "Hey Launchy", hear the sound, then say my request, as well as saying it all in one breath.
8. As a Launchy user, I want my sentence to wake Launchy only when it starts with "Hey Launchy", so that talking about Launchy on a call doesn't.
9. As a Launchy user, I want Launchy's own voice never to wake it or end up in the transcript as something heard.
10. As a Launchy user, I want to be told when nothing matched, rather than hear a wrong page.
11. As a Launchy user, I want to hear the voice I chose in Settings › Listening.
12. As a Launchy user, I want my request, what it read and its answer to stay on my machines: this Mac, or my own server when I chose one for Text generation.
13. As a Launchy user, I want Hey Launchy off until I turn it on, and Settings to say when Text generation isn't set up.
14. As a Launchy user, I want the answer in today's transcript beside my request, so that the transcript keeps the whole exchange.
15. As a maintainer, I want `Launchy --ask <file>` to run a request through the three steps and print what each one did, so that I can tune the prompts.

## Implementation Decisions

**Turning it on**
- A **Hey Launchy** switch in Settings › Listening, above Voice, off by default and stored in UserDefaults like the other switches. Its detail says it answers out loud from History, Bookmarks and Claude sessions while Listening is on.
- Text generation not set up: the switch shows the need and the link to Settings › Models, and can't be turned on, exactly as Session titles does.
- Below macOS 26 the switch is disabled with "Needs macOS 26", as `!listen` is.
- It does nothing while Listening is off. Listening stays off at each launch.
- Turning the switch off, or stopping Listening, cancels a request under way and stops Launchy speaking.

**Hearing the wake phrase**
- Only the mic's results are checked, and only final ones. System audio never wakes it.
- Listening keeps writing every final result to the transcript as today, except mic results heard while Launchy speaks (below). The capture also reports each final mic result to the main actor with its text and its start and end times (the transcriber already reports audio time ranges).
- The mic analyzer gets "Launchy" and "Hey Launchy" as contextual strings. If `SpeechTranscriber` ignores them, nothing is lost.
- A result wakes it when, lowercased with punctuation dropped, the wake pattern begins within its first three words. The pattern is the prototype's:

  ```
  \b(hey|hay) (launch|lunch|lanch)\w*
  ```

- On waking, Launchy plays a short system sound.
- **The request** is the text after the match.
  - If none follows, Launchy takes the next mic result that starts within the wait limit (8 s). A wait that ends with nothing said is an empty request: no search, and Launchy says "Ask me to find a page, a bookmark or a Claude session." Speech heard just before the wait ends is waited for, since its final result comes late. A result of only punctuation counts as nothing.
  - Any further mic result that starts within the gap (1.5 s) of the previous one's end is appended, up to the length limit (20 s or 500 characters).
  - The wait, the gap and the limit are named constants, tuned by hand.
- One request at a time. Mic results heard while a request is decided, read or spoken never wake it or join a request.

**Keeping Launchy's own voice out**
- **System audio.** The system audio tap excludes Launchy's own process: its process id is turned into the audio process object, which goes in the tap description's excluded list. Neither the wake sound nor the speech reaches the `[system]` transcript. System audio never wakes it anyway.
- **The mic.** With speakers rather than headphones, the mic hears the speech, and an echo phrase could be transcribed or even match the wake phrase.
  - Launchy keeps the span of its last speech: from when the synthesizer starts to when it finishes, plus a short tail (0.5 s, a named constant).
  - The capture can read that span safely from its result loop, as it reads whether writes are on.
  - A mic result whose audio starts inside the span is dropped: not written to the transcript, not checked for the wake phrase, not added to a request.
  - The check uses the result's audio time, not when the result arrives, since finals arrive 1–2 s late.
- **The answer itself** goes into the transcript once, as a `[launchy]` line (below).

**Deciding (step 1)** (amended: Jev decides, [ADR 0016](../../../adr/0016-a-spoken-requests-decide-step-asks-typesafe-jev.md))
- **With a TypeSafe key saved, TypeSafe's Jev decides** (`SpokenRouter`), on a pinned model version. One call carries the request text and nothing else, with two questions:
  - `source`, a choice over `history`, `bookmarks` and `sessions`, each with a rubric: bookmarks only when the request says bookmarked or saved; sessions for what the user was doing, fixed, planned or decided, and for a name that isn't a well-known public thing (probably one of their projects);
  - `action`, a choice over `answer`, `open`, `start` and `other`. Only `other` is read, as the off-topic signal (the weather, a timer). Opening and starting by voice stay out of scope.
- **The search words are not Jev's.** Launchy strips filler in code: words of asking, finding and remembering, words naming only a kind (page, bookmark, session) or a time, and small grammatical words. If nothing is left, the request itself is the query. (Measured locally, this matched Jev's own word-by-word judgments.)
- **From Jev's probabilities to the rows read:**
  - the likeliest source leads, as before;
  - sessions are also read when a search word is the whole folder name of one of the user's Claude sessions (compared here, never sent), and their rows come first; or when Jev gave sessions at least 0.1, and their rows come after the pages;
  - sessions read beside pages take up to 3 rows ahead, or 2 behind, and the pages fill the 5 rows in all, so each kind is heard when it has any;
  - "other" at 0.5 or more reads sessions, then pages, as the fallback below does. The request is still searched and the answer step says plainly when nothing fits: the user's earlier decision that every request is a search stands.
- **Fallback to Text generation:** no key, a network error, a status other than 200 or no answer within 1.5 s. The relevance filter falls back the same way.
- Where each decide ran is in the timing log line and in `--ask`, which prints Jev's probabilities. `LAUNCHY_ASK_DECIDER=text` makes `--ask` skip Jev to try the fallback.

*The fallback, Text generation as first specified:*
- One Text generation call with a fixed prompt, kept in one place as the title prompt is. It asks for one line of JSON:
  - `source`: `history` (pages, History and Bookmarks together, as the panel searches them), `bookmarks` (bookmarked pages only), or `sessions`;
  - `query`: 1 to 8 search words, without filler ("find", "that page", "I was reading").
- Greedy, at most 48 new tokens. The reply is read leniently: the first `{…}` in it.
- A reply that can't be read, or that names no source ("none" included), falls back to the request's own text as the query, reading sessions and pages both. Every request is a search: the prompt offers no way to decline.
- The search words matter: keyword search requires every word to match, so a whole spoken sentence would match nothing by keyword.
- **Where it runs** is Text generation's choice, picked as work the user waits on: the server unless it is known to have failed, otherwise this Mac's installed model. This is the rule `ModelServerState.place` already applies to searches; titles use the background rule.
  - A server failure rests the server, as a failed search embedding does, and the step runs once more on this Mac's model if installed.
  - If neither can answer, Launchy says "Text generation isn't set up" and stops.

**Reading (step 2)**
- **The panel's search without the panel.** A method on the launcher model runs the first two passes of the panel's search and returns the sessions and pages:
  - keyword for pages and for sessions;
  - the query's embedding, through the same server-or-this-Mac pick;
  - meaning for both;
  - the same fusion, limits, session similarity floor and open-sessions-first.

  It sets nothing the panel shows: not the results, the selection, the search statuses or who answered the last semantic search. The panel's own search keeps its code path and behaves exactly as before.
- No relevance filter: the answer step already judges which of the few rows fit, and the words go nowhere.
- What it reads:
  - `sessions`: the sessions, at most 3;
  - `history`: the top 5 pages;
  - `bookmarks`: the top 5 pages whose source is `bookmark`, which may be fewer than 5;
  - fallback: sessions, then pages, 5 in all.
- **Each row, as the model sees it:**
  - its number;
  - its kind (page, bookmark, Claude session);
  - its title;
  - its site (host) or, for a session, its folder's name and its Mac when it is a paired Mac's;
  - its date in words ("today", "3 days ago"): last visit, date added, or last used;
  - its description, cut to 300 characters. For a session that is its prompts, oldest first.
- Never the URL: URLs are long, read badly aloud, and can carry ids.
- No row at all: Launchy says it found nothing for the words it searched.

**Responding (step 3)**
- A second Text generation call, same place as step 1, with a fixed prompt.
  - Its input: the request and the numbered rows.
  - Its reply: one or two short sentences to be spoken, naming the page or session and when, and saying so if none of the rows fits.
  - Greedy, at most 96 new tokens. Only the first two sentences are spoken.
  - A reply with no text is spoken as "I couldn't answer that."
- **Speaking** uses the system speech synthesizer in the Voice setting, or the system voice when it is empty.
  - The Voice row becomes a picker: System default, then the installed voices of the transcriber's language.
  - The speech has to play from Launchy's own process, so the tap's exclusion covers it. Whether the synthesizer plays in-process is unverified (a hand check below). If it doesn't, Launchy renders the speech to buffers and plays them itself.
- **Nothing else happens.** The panel isn't shown, focus doesn't move, no search appears in the field, and nothing opens or starts.
- **Transcript (a default, not the user's choice):** the spoken answer is written to the transcript as a `[launchy]` line. The request is already there as the `[mic]` line it came from. The `[launchy]` source's comment changes from "a failure" to "what Launchy said or a failure".

**Privacy and logs**
- The request, the search words, the rows and the answer are never logged, as with session titles. A failure logs its kind only.
- With Text generation on a server, the request and the rows' text go to that server.
  - The Text generation server row's text in Settings › Models says so, beside the first prompt it sends today.
  - `where-it-breaks.md`'s list of what goes to a model server adds them.
- Nothing goes to any other service, except the request text to TypeSafe for the decide step (ADR 0016). The relevance filter does not run.

**Command line**
- `Launchy --ask <file>` treats the file's text as a request after the wake phrase. It runs the three steps against the app's own search without speaking, and prints the source, the search words, the rows' titles, the answer and each step's time.
- It follows Text generation's choice as `--title` does. Request files are personal: keep them out of the repo.

**State**
- One new UserDefaults key for the switch.
- The existing `voice` key holds the picked voice's identifier, and empty still means the system voice.
- `sessions.json` is unchanged.

## Testing Decisions

- There is no test target. Two steps are pure and are the seams for a first test once there is one:
  - the wake match: a final result's text goes in, and the request's text or nothing comes out;
  - reading the decide step's reply: the model's text goes in, and a source and search words, or the fallback, come out.
- **The search apart from the panel** must not change the panel's search. `--search` prints the same rows before and after for a few queries, and `--search-eval` on the user's eval terms gives the same MRR.
- **By hand, after the user restarts Launchy,** with Hey Launchy and Listening on:
  - Say "Hey Launchy, find the page about" and a page you visited. A sound plays, then the answer names the page. The panel stays hidden, and the app in front keeps focus.
  - With the panel open and something typed in it, ask again. The field, the results and the selection don't change.
  - Say "Hey Launchy", wait for the sound, then ask which bookmark is about something you bookmarked. The answer comes from a bookmark.
  - Ask about a past Claude session. The answer names it and when.
  - Ask about something nothing in the store is about. Launchy says it found nothing.
  - Say a sentence with "Launchy" in the middle ("I think Launchy is slow"). Nothing wakes.
  - Turn Listening off while Launchy speaks. It stops.
  - With Text generation set to a server that is off, the request is answered by this Mac's model when it is installed.
  - Launchy's log (Console, process Launchy) holds no request, words, titles or answer.

**Hand checks for the builder.** These are unverified. Run them with the user (they speak), and keep figures and anything personal in `.scratch/listening-never-answers/`, never in the repo.

1. **Launchy's speech plays in its own process and is never heard back.**
   - With headphones and Listening on, get an answer. Today's transcript has the `[mic]` request and one `[launchy]` answer, and no `[system]` line of the answer or the wake sound.
   - If a `[system]` line appears, the synthesizer plays outside Launchy's process: render to buffers, play them from Launchy, and check again.
   - Then with speakers: no `[mic]` line of the answer, and no second wake after it.
2. **Wake accuracy.**
   - About 20 takes of "Hey Launchy, …": normal voice, quieter, from a step back, with music playing.
   - About 15 minutes of ordinary talk, including "Launchy" mid-sentence.
   - Count misses and false wakes. More than about 1 miss in 5, or any false wake from talk, goes back to the user with option 05.
3. **Latency.**
   - About 10 requests warm, and one after 10 idle minutes.
   - Time each from the end of speech to the first spoken word, and note `--ask`'s per-step times for the same requests.
   - A warm median well over 5 s goes back to the user before any tuning.

- `--ask` on a dozen made-up requests, to tune the two prompts and the wait, gap and limit.

## Out of Scope

- Showing anything on screen (see Later).
- Opening a page or resuming a session by voice.
- Waking while Listening is off (option 05).
- Starting a Claude session (option 04).
- Follow-up questions that rely on the last answer ("and the one before that?"). Each request stands alone.
- Several searches for one request, reading a page's text or a session's replies (options 02 and 03).
- Dates as filters ("yesterday"). The dates reach the answer, not the search.
- The relevance filter on a spoken request's search.
- Interrupting the answer by speaking, a stop control other than turning Listening or the switch off, echo cancellation on the mic, and languages other than the transcriber's.

## Further Notes

- **Decided by the user on 2026-10-08,** relayed by the coordinator:
  - this option, local only, with the three fixed steps; options 02–05 stay proposed;
  - the wake phrase heard only while Listening is on, from the mic's final results;
  - the response is speech only, with no panel, no selection and nothing opened.
- **Defaults, not asked of the user:**
  - the `[launchy]` transcript line;
  - dropping mic phrases heard while Launchy speaks;
  - no relevance filter on spoken searches;
  - no stop control beyond turning Listening or the switch off.
- **Later, if the user wants more than speech:**
  - Show the search in the panel with the answer's row selected, so that ↩ opens it. The answer step would then name its row by number again, and the panel would come forward the way the menu's Show Transcript does.
  - A "Stop speaking" item in the menu bar.
- **ADR, to write now that this is accepted:** spoken requests are answered by Launchy's own steps around the Text generation role, on the user's own machines, are heard through Listening, and are answered only aloud. It extends ADRs 0012 and 0014 to a second consumer of Text generation.
- **Glossary, proposed:**
  - **Spoken request**: what the user says after "Hey Launchy", answered aloud from History, Bookmarks and sessions. _Avoid_: ask, prompt (a prompt starts a session), command, query.
  - **Wake phrase**: "Hey Launchy" at the start of something said into the mic while Listening is on.
  - **Transcript**'s entry adds that Launchy's spoken answers are in it, and that what the mic hears while Launchy speaks isn't.
- **`where-it-breaks.md` items this touches:**
  - Search store: MLX shared by the process, never logging what the user said, and what goes to a model server.
  - Focus and keys and Panel size are untouched: nothing is shown.
- **A new where-it-breaks entry for Listening:**
  - the tap must keep excluding Launchy's process;
  - the speech span must cover the synthesizer's whole output, plus its tail;
  - the panel's search and the spoken search must share one ranking.
- **Verified in the code:**
  - the search covers History, Bookmarks and sessions;
  - the panel's first two passes (keyword, the query's embedding and meaning, fusion) set panel state only where `runSearch` writes the results and statuses, so they can be run without it;
  - Text generation's single call shape and its place rule;
  - the Voice setting and its row;
  - the transcriber setup, finals only, and the tap excluding no process;
  - Settings' gating of Session titles on Text generation.
- **In the SDK:** contextual strings on the analyzer, turning a process id into the tap's process object, and rendering speech to buffers.
- **Inferred, not measured:**
  - the latency figures (from the reported Gemma speeds and the prototype's transcription delays);
  - Gemma 4 E2B's accuracy at choosing the source and the words;
  - how well the wake phrase is heard;
  - whether the synthesizer plays in Launchy's process;
  - whether contextual strings help `SpeechTranscriber`.

  Latency, how well the wake phrase is heard and the synthesizer are hand checks 3, 2 and 1 above. The model's accuracy is tuned with `--ask`.
