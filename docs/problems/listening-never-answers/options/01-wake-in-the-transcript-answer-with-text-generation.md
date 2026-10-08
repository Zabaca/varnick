---
problem: listening-never-answers
title: Wake on the mic's transcript; Launchy searches and Text generation answers aloud
summary: While Listening is on, a mic phrase that starts with "Hey Launchy" becomes a spoken request. Text generation (this Mac's Gemma, or the tailnet server) picks the source and the search words. Launchy runs the panel's own `?` search with them, and Text generation writes a one- or two-sentence answer from the top rows. Launchy speaks it in the Voice setting while the panel shows the results, with the row it named selected so ↩ opens it. Nothing leaves the user's machines.
status: proposed
---

## Solution

A new switch, **Hey Launchy**, in Settings › Listening. With it on and Listening running, each final mic phrase is checked for the wake phrase at its start. The rest of the phrase is the **spoken request**, and if nothing follows, the next phrase is. Then three fixed steps run, the user's 1, 2, 3:

1. **Decide.** One Text generation call turns the request into a source (History, Bookmarks, sessions, or none of them) and a few search words.
2. **Read.** Launchy brings the panel forward on search, types `?` and the words into the field, and waits for the search to finish, as `--search-eval` does. It then takes the top rows of the chosen source: their title, site or folder, date and description.
3. **Respond.** A second Text generation call writes a short answer from those rows and names the one it means. Launchy speaks it and selects that row in the panel. ↩ opens it as it always does: a page in the browser, a session in its tab or resumed.

The answer is written from exactly the rows on screen, so a wrong answer can be seen and corrected by editing the search. Nothing opens or starts by voice alone. Text generation runs wherever Settings › Models says, so the request and the rows stay on this Mac or go to the user's own server on the tailnet, and nowhere else.

## Trade-offs

- **Private by construction.** No new service, key or network path. With Text generation on this Mac nothing leaves it. With a server, the request and the rows' text go to that server, as session prompts already do for Search embeddings on a server (ADR 0014).
- **A small model, kept on rails.** Gemma 4 E2B only fills in two short replies; Launchy runs the steps. Such a small model can pick the wrong source or poor search words. The fixed steps cap the damage at one wrong search, and that search shows in the field.
- **Answers only from what a row holds.** Launchy can say which page or session, from where and when, and what the page's own summary or the user's prompts said. It can't say what a page's text says or what Claude replied in a session.
- **Waking is unmeasured.** The match tolerates the mishearings the prototype saw that start with "launch", "lunch" or "lanch", and misses the rest. If misses are common, option 05 is the fallback.
- **Only while Listening is on,** and only on macOS 26. Listening stays off at each launch.
- **The mic hears the speakers.** Only the mic can wake it, but a video saying "hey launchy" through speakers reaches the mic too. Requiring the phrase at the start of a phrase cuts false wakes from ordinary talk about Launchy. With speakers rather than headphones, the transcript also gets `[mic]` lines of Launchy's own answer.
- **The panel comes forward and takes focus,** as the hotkey does. A false wake does the same in the middle of typing in another app.
- **Latency, estimated rather than measured.** Warm, about 3–4 s from the end of speech to the first spoken word:
  - the transcriber's final result, 1–2 s;
  - choosing the source, about 0.3 s;
  - the search, about 0.15 s, plus about 1.3 s with the relevance filter on TypeSafe;
  - the answer, about 1 s on Gemma at the reported 2,200 tokens/s prefill and 150 tokens/s generation.

  After 10 idle minutes the models have unloaded, which adds about 4 s for Gemma and 1.75 s for the embedder.
- **Memory.** Gemma holds about 2.5 GB while loaded, as for titles. The first spoken request after a launch loads it.

## User Stories

1. As a Launchy user with Listening on, I want to say "Hey Launchy, find the page about MLX shader caching" and hear which page it is, so that I find it without typing.
2. As a Launchy user, I want "Hey Launchy, which of my bookmarks is about Rust lifetimes" answered from my bookmarks only, so that what I saved on purpose comes first.
3. As a Launchy user, I want "Hey Launchy, what was I doing with Claude on the reranker" answered from my Claude sessions, naming the session and when I last used it.
4. As a Launchy user, I want the panel to show the search the answer came from, with the named row selected, so that ↩ opens it and I can see why it answered as it did.
5. As a Launchy user, I want nothing to open or start until I press a key, so that a misheard request costs nothing.
6. As a Launchy user, I want to say "Hey Launchy", hear a short sound, then say my request, as well as saying it all in one breath.
7. As a Launchy user, I want my sentence to wake Launchy only when it starts with "Hey Launchy", so that talking about Launchy on a call doesn't.
8. As a Launchy user, I want to be told when nothing matched, rather than hear a wrong page.
9. As a Launchy user, I want to hear the voice I chose in Settings › Listening.
10. As a Launchy user, I want Esc, or closing the panel, to stop Launchy talking.
11. As a Launchy user, I want my request, what it read and its answer to stay on my machines: this Mac, or my own server when I chose one for Text generation.
12. As a Launchy user, I want Hey Launchy off until I turn it on, and Settings to say when Text generation isn't set up.
13. As a Launchy user, I want the answer in today's transcript beside my request, so that the transcript keeps the whole exchange.
14. As a maintainer, I want `Launchy --ask <file>` to run a request through the three steps and print what each one did, so that I can tune the prompts.

## Implementation Decisions

**Turning it on**
- A **Hey Launchy** switch in Settings › Listening, above Voice, off by default and stored in UserDefaults like the other switches. Its detail says it answers from History, Bookmarks and Claude sessions while Listening is on.
- Text generation not set up: the switch shows the need and the link to Settings › Models, and can't be turned on, exactly as Session titles does.
- Below macOS 26 the switch is disabled with "Needs macOS 26", as `!listen` is.
- It does nothing while Listening is off. Listening stays off at each launch.

**Hearing the wake phrase**
- Only the mic's results are checked, and only final ones. System audio never wakes it.
- Listening keeps writing every final result to the transcript as today. The capture also reports each final mic result to the main actor with its text and its start and end times (the transcriber already reports audio time ranges).
- The mic analyzer gets "Launchy" and "Hey Launchy" as contextual strings. If `SpeechTranscriber` ignores them, nothing is lost.
- A result wakes it when, lowercased with punctuation dropped, the wake pattern begins within its first three words. The pattern is the prototype's:

  ```
  \b(hey|hay) (launch|lunch|lanch)\w*
  ```

- **The request** is the text after the match.
  - If none follows, Launchy plays a short system sound and takes the next mic result that starts within the wait limit (8 s).
  - Any further mic result that starts within the gap (1.5 s) of the previous one's end is appended, up to the length limit (20 s or 500 characters).
  - The wait, the gap and the limit are named constants, tuned by hand.
- One request at a time. Mic results heard while a request is decided, read or spoken never wake it or join a request; they are still transcribed.

**Deciding (step 1)**
- One Text generation call with a fixed prompt, kept in one place as the title prompt is. It asks for one line of JSON:
  - `source`: `history` (pages, History and Bookmarks together, as the panel searches them), `bookmarks` (bookmarked pages only), `sessions`, or `none`;
  - `query`: 1 to 8 search words, without filler ("find", "that page", "I was reading").
- Greedy, at most 48 new tokens. The reply is read leniently: the first `{…}` in it.
- A reply that can't be read falls back to the request's own text as the query, reading sessions and pages both.
- The search words matter: keyword search requires every word to match, so a whole spoken sentence would match nothing by keyword.
- **Where it runs** is Text generation's choice, picked as work the user waits on: the server unless it is known to have failed, otherwise this Mac's installed model. This is the rule `ModelServerState.place` already applies to searches; titles use the background rule.
  - A server failure rests the server, as a failed search embedding does, and the step runs once more on this Mac's model if installed.
  - If neither can answer, Launchy says "Text generation isn't set up" and stops.

**Reading (step 2)**
- `none`: no search. Launchy says it can search History, Bookmarks and Claude sessions.
- Otherwise:
  - It closes Settings and the session board, and goes back to search without ending anything, as ⌘N does.
  - It shows the panel the way the menu's Show Transcript does: change the model, then show. The query is set after the panel shows, since showing resets an idle search.
  - The query is `?` and the search words, so the panel runs the ordinary search: keyword, then meaning, then the relevance filter if it is on.
  - Launchy waits until neither the meaning pass nor the filter is pending, as `--search-eval` does.
- What it reads from the panel's results:
  - `sessions`: the Sessions rows, at most 3;
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
- No row at all: Launchy says it found nothing for the words it searched, and the panel shows the empty search.
- With the relevance filter on TypeSafe, the search words (not the request) and the page candidates go to TypeSafe, exactly as when the same words are typed. Sessions never do.

**Responding (step 3)**
- A second Text generation call, same place as step 1, with a fixed prompt.
  - Its input: the request and the numbered rows.
  - Its reply: on the first line, the number of the row the answer is about (0 for none); then one or two short sentences to be spoken, naming the page or session and when, and saying so if none of the rows fits.
  - Greedy, at most 96 new tokens.
  - A reply with no number leaves the top row selected. A reply with no sentences says the row's title.
- **Speaking** uses the system speech synthesizer in the Voice setting, or the system voice when it is empty.
  - The Voice row becomes a picker: System default, then the installed voices of the transcriber's language.
  - The speech plays from Launchy's own process, and the system audio tap now leaves Launchy's process out, so Launchy's own voice is never transcribed as `[system]`.
  - Whether the synthesizer plays in-process is unverified. If it doesn't, Launchy renders the speech to buffers and plays them itself.
- **On screen:** the panel keeps the search with the named row selected. Nothing opens until the user presses ↩, and then it opens as a typed search's row would.
- Speech stops when the panel hides (Esc, clicking away, the hotkey) and when Listening stops.
- The spoken answer is written to the transcript as a `[launchy]` line. The request is already there as the `[mic]` line it came from. The `[launchy]` source's comment changes from "a failure" to "what Launchy said or a failure".

**Privacy and logs**
- The request, the search words, the rows and the answer are never logged, as with session titles. A failure logs its kind only.
- With Text generation on a server, the request and the rows' text go to that server.
  - The Text generation server row's text in Settings › Models says so, beside the first prompt it sends today.
  - `where-it-breaks.md`'s list of what goes to a model server adds them.
- Nothing goes to any other service, apart from TypeSafe's existing share above.

**Command line**
- `Launchy --ask <file>` treats the file's text as a request after the wake phrase. It runs the three steps against the app's own search without showing or speaking, and prints the source, the search words, the rows' titles, the answer and each step's time.
- It follows Text generation's choice as `--title` does. Request files are personal: keep them out of the repo.

**State**
- One new UserDefaults key for the switch.
- The existing `voice` key holds the picked voice's identifier, and empty still means the system voice.
- `sessions.json` is unchanged.

## Testing Decisions

- There is no test target. Two steps are pure and are the seams for a first test once there is one:
  - the wake match: a final result's text goes in, and the request's text or nothing comes out;
  - reading the decide step's reply: the model's text goes in, and a source and search words, or the fallback, come out.
- By hand, after the user restarts Launchy, with Hey Launchy and Listening on:
  - Say "Hey Launchy, find the page about" and a page you visited. The panel shows `?` with the words, the answer names the page, its row is selected, and ↩ opens it.
  - Say "Hey Launchy", wait for the sound, then ask which bookmark is about something you bookmarked. The answer comes from a bookmark row.
  - Ask about a past Claude session. The answer names it and when. ↩ switches to its tab or resumes it.
  - Ask about something nothing in the store is about. Launchy says it found nothing.
  - Say a sentence with "Launchy" in the middle ("I think Launchy is slow"). Nothing wakes.
  - Press Esc while it speaks. It stops.
  - Today's transcript has the `[mic]` request and a `[launchy]` answer, and no `[system]` line of the answer.
  - With Text generation set to a server that is off, the request is answered by this Mac's model when it is installed.
  - Launchy's log (Console, process Launchy) holds no request, words, titles or answer.
  - The panel's height is right in the search it shows: the existing search layout, nothing new.
- `--ask` on a dozen made-up requests, to tune the two prompts and the wait, gap and limit.
- Before relying on it, run the survey's wake measurement on the user's own voice: about 50 takes of "Hey Launchy" in different ways, and an hour of ordinary desk audio. Count misses and false wakes. Many misses point to option 05.

## Out of Scope

- Waking while Listening is off (option 05).
- Starting a Claude session, or opening anything without ↩ (option 04 covers starting one, with a key press).
- Follow-up questions that rely on the last answer ("and the one before that?"). Each request stands alone.
- Several searches for one request, reading a page's text or a session's replies (options 02 and 03).
- Dates as filters ("yesterday"). The dates reach the answer, not the search.
- Interrupting the answer by speaking, echo cancellation on the mic, and languages other than the transcriber's.
- A text answer drawn in the panel. The panel shows the results, and the answer is spoken and written to the transcript.

## Further Notes

- **ADR on acceptance:** spoken requests are answered by Launchy's own steps around the Text generation role, on the user's own machines, and are heard through Listening. It extends ADRs 0012 and 0014 to a second consumer of Text generation.
- **Glossary, proposed:**
  - **Spoken request**: what the user says after "Hey Launchy", answered from History, Bookmarks and sessions. _Avoid_: ask, prompt (a prompt starts a session), command, query.
  - **Wake phrase**: "Hey Launchy" at the start of something said into the mic while Listening is on.
- **`where-it-breaks.md` items this touches:**
  - Search store: MLX shared by the process, never logging what the user said, and what goes to a model server.
  - Focus and keys: showing the panel, and Esc stopping speech.
  - Panel size: no new rows. The answer uses the ordinary search layout.
  - Sessions and tabs: opening a session row is unchanged.
- **Verified in the code:**
  - the search covers History, Bookmarks and sessions, and runs only as the panel's query;
  - `--search-eval` drives it by setting the query and waiting;
  - Text generation's single call shape and its place rule;
  - the Voice setting and its row;
  - the transcriber setup, finals only, and the tap excluding no process;
  - Settings' gating of Session titles on Text generation.
- **In the SDK:** contextual strings on the analyzer, and turning a process id into the tap's process object.
- **Inferred, not measured:**
  - all latency figures (from the reported Gemma speeds and the prototype's transcription delays);
  - Gemma 4 E2B's accuracy at choosing the source and the words;
  - whether the synthesizer plays in Launchy's process;
  - whether contextual strings help `SpeechTranscriber`.
