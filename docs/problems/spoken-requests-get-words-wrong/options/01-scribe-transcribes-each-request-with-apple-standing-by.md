---
problem: spoken-requests-get-words-wrong
title: ElevenLabs' Scribe v2 transcribes each spoken request, with Apple's text standing by
summary: A switch in Settings › Listening on each Mac, Transcribe requests with ElevenLabs, off by default, with a list of names to listen for. With it on, each segment the phone's Voice mode sends, and each line of a Hey Varnick request or of Voice mode at the Mac, goes to ElevenLabs' Scribe v2 (batch) while Apple's transcriber runs on it as today. Scribe's text is used when it comes back within 2 s; on a failure, a slow reply or no network, Apple's is. The wake phrase stays Apple's, so nothing leaves the Mac before "Hey Varnick". The request's audio, the user's voice and anything else the microphone heard in those seconds, goes to ElevenLabs and is kept there under its policy. Estimated under $3 a month at 30 requests a day; about half a second to a second more per request, unmeasured.
status: shipped
---

## Solution

A new row in Settings › Listening, **Transcribe requests with ElevenLabs**, off by default, needing the ElevenLabs key already saved for spoken answers, with the Speech to Text permission added to it. Under it, **Names to listen for**: the names the user hears Varnick get wrong, one per line. The switch is per Mac: a phone's Voice mode follows the switch of the Mac whose page it is on, and Hey Varnick follows its own Mac's.

With the switch on, every piece of audio that becomes part of a request is transcribed twice at once: by Apple on the Mac, as today, and by ElevenLabs' Scribe v2, told to expect English and to listen for "Varnick" and the user's names. When Scribe's text comes back within 2 s, Varnick uses it; otherwise it uses Apple's, which is ready by then. Nothing else about a request changes: it still ends at "over" or the cap, the phone still shows what was heard as it is collected, and the Voice session gets the request as today.

- **On the phone,** a piece is a segment. The segment's words, as the phone's view shows them and as the request collects them, are Scribe's when it answered in time.
- **At the Mac,** Listening keeps the last minute of microphone audio in memory. Once Apple hears the wake phrase, that line's audio and each later line of the request go to Scribe as Apple finishes them, and in Voice mode every line taken as a request does. "Over" is still heard by Apple and still ends the request at once; the request's text is then made from Scribe's lines, with Apple's for any line Scribe hasn't answered within its 2 s.

When the switch is off, no key is saved, or ElevenLabs refuses or fails, Varnick works as today. The last failure shows under the switch, as the Voice row shows one.

## Trade-offs

- **The user's voice leaves the Mac, and is kept by ElevenLabs.** Every segment the phone sends while Voice mode runs goes, which is everything said since Start that the Mac has not yet taken: a passenger, a podcast or the radio included (with Car mode, music from the car's speakers can reach the microphone). At the Mac, each line from the wake phrase to "over" goes, and in Voice mode every line the microphone hears that becomes a request. Never anything before the wake phrase, the Mac's own audio, or Listening's day transcript. ElevenLabs keeps request data under its privacy policy, and the user's plan can't turn that off.
- **Better words are expected, not measured.** No recording of a misheard request exists, so whether Scribe does better on the user's voice in the car is the user's judgment once it runs. The names list is the main lever on names, and Apple has no working equivalent (its four contextual strings changed nothing).
- **A little slower.** Apple takes a fraction of a second per segment on the user's Mac (figures kept locally). Scribe returned a 1 s clip in 0.58 s once (2026-10-10); a 5 to 10 s segment is unmeasured, and ElevenLabs publishes no latency for batch. Earlier segments are transcribed while the user goes on talking, so the wait is added once, on the segment that ends with "over": aimed at half a second to a second, and never more than 2 s, since Apple's text is then used. At the Mac, Scribe gets a line only when Apple has finished it, so the same holds. The answer itself takes several seconds.
- **It costs a little, per second sent.** $0.22 an hour of audio plus $0.05 for the names: $0.27 an hour, drawn first from the plan's monthly allowance that spoken answers also use. Estimates (assumptions, not the user's figures): 30 requests a day of about 10 s of audio each is about 2.5 hours a month, about $0.70; 20 minutes a day sent from the car is about 10 hours, about $2.70; a ceiling of 2 hours a day, every second of it sent, is 60 hours, about $16.20. Silence is billed too, so each segment's 300 ms lead-in and up-to-900 ms tail count. A plan that runs out stops ElevenLabs until it renews or more is bought, and Apple's text is used meanwhile.
- **Two texts of one request.** The day's transcript keeps Apple's `[mic]` lines; the Voice session's prompt and the phone's view have the chosen text.
- **Waking still depends on Apple** at the Mac. A wake phrase Apple misses is not helped, and "over" is still Apple's there.
- **It touches Listening's microphone feed:** an in-memory window is filled from the microphone's audio callback, under the same rule Save audio follows (`where-it-breaks.md`, Listening).

## User Stories

1. As the user, I want to turn on ElevenLabs transcription with one switch on the Mac, so that Voice mode on my phone and Hey Varnick at my desk both use it.
2. As the user, I want it off until I turn it on, and the switch's text to say my request's audio goes to ElevenLabs and is kept there, so that I choose it knowingly.
3. As the user, I want to list the names Varnick gets wrong, so that ElevenLabs listens for them.
4. As the user, I want "Varnick" listened for without adding it, so that the app's own name is always right.
5. As the user in the car, I want my request heard with the right words and names, so that I don't have to say it again while driving.
6. As the user, I want the phone's view to show the words ElevenLabs heard as I speak, so that I can see what will be asked before I say "over".
7. As the user, I want Apple's words used when ElevenLabs fails, is slow or can't be reached, so that a request is never lost to it.
8. As the user, I want a fallback never to cost me more than about 2 s, so that a bad connection doesn't stall the conversation.
9. As the user, I want Varnick to tell me in Settings why ElevenLabs isn't hearing me (a refused key, a missing permission, an empty allowance, no answer), so that I can fix it.
10. As the user, I want nothing sent before "Hey Varnick" at the Mac, so that the rest of my day stays on my Mac.
11. As the user, I want Listening's day transcript unchanged, so that turning this on doesn't change what is written there or send it anywhere.
12. As the user, I want silent stretches not sent, so that I am not billed for nothing.
13. As the user, I want "over" to keep ending my request at once, so that the new transcriber doesn't change how I talk to Varnick.
14. As the user, I want each Mac to have its own switch, so that I choose per machine, as I choose its voice.
15. As the user, I want turning the switch off to stop all sending at once, so that I can stop it mid-drive from the Mac's Settings.
16. As a maintainer, I want the timing lines to say, per segment or line, which transcriber's text was used, why Apple's was if it was, and how long each took, so that I can tell whether it pays.
17. As a maintainer, I want none of the audio, either text, or the names list in a log, so that the logs stay as private as today.
18. As a maintainer, I want the rule that picks a text, and the rule that makes a Mac request from its lines, to be pure and checked by cases, so that a change to either is caught without a restart.
19. As a maintainer, I want the key to go only to ElevenLabs, with no redirect followed, so that adding a request type keeps ADR 0033's guarantee.

## Implementation Decisions

- **The switch** is a new setting, absent reads off, shown in Settings › Listening near the Voice row. With no key saved, the row links to Settings › Models, as the Voice row does. Its text says what is sent, that ElevenLabs keeps it, and that it is billed per minute of audio; it changes together with the privacy page. **Names to listen for** is a text field under it, kept with the settings. The last transcription failure shows under the switch in memory only, cleared by the next segment or line Scribe answers, as `elevenLabsNote` does for the voice.
- **The transcription request** joins the existing ElevenLabs module beside speaking, using its kept connection (no redirect, the key only in its header) and its failure sorting, with the quota failure worded for minutes, not characters. It sends the audio as raw 16 kHz mono 16-bit PCM (the API's `pcm_s16le_16`, the format the phone already sends), the model pinned in code (`scribe_v2`, as Flash v2.5 is for speaking, with no picker), the language as English (from the language Listening uses), the names as keyterms, and asks for no audio-event tags, no speaker labels and no timestamps. It reads the reply's text.
- **The names as keyterms:** "Varnick", then the user's list, trimmed, de-duplicated, without the characters the API refuses, each kept only if under 50 characters and at most 5 words, cut at 100 in all, so the 20 s minimum per request never applies. A pure function in the shared package.
- **The choice of text** is a pure function in the shared package: given Apple's outcome and Scribe's (text, failure, or not back yet) and the time since both were started, Scribe's text when it came back within the deadline, even blank (it heard noise, not words); Apple's otherwise; Scribe's when Apple failed and Scribe answered; a failure when both failed, which the phone's segment reports as today. The deadline is a named constant, 2 s from the start, to be set by the hand test. Each piece tries ElevenLabs afresh and nothing rests it after failures (ADR 0033's rule for lines).
- **Audio quieter than the existing silence floor goes to neither,** as Apple's pass skips it today.
- **The phone's segments.** Where the Mac turns a finished segment into words, it starts Apple's pass and the Scribe request together and takes the choice. Everything after it is unchanged: the order segments are added in, the collector and "over", the cap, the ledger and the events. No protocol change and nothing on the page.
- **The Mac's lines.**
  - Listening keeps a window of the last 60 s of microphone audio in memory, in the speech format, timed on the same audio clock its results use. The microphone's callback only hands each converted buffer to a serial queue (the Save audio rule). The window exists only while the switch, Listening and Hey Varnick are on and the Voice session answers; it is never written to disk and is dropped when any of them turns off.
  - A **line** is a final microphone result that becomes part of a request: the one with the wake phrase, each one collected until "over", and in Voice mode each one taken as a request line (after the echo check). Its audio, cut from the window by its audio time range with a small pad and converted to 16 kHz mono 16-bit with the conversion Listening already uses, goes to Scribe as soon as the result arrives.
  - Collecting is unchanged and runs on Apple's text: the wake phrase, "over", the cap, the minute, the echo check and the call watch.
  - When the request is dispatched, its text is made again from its lines by a pure function beside the "over" rule: each line's chosen text, the first with the wake phrase taken off by the same rule as today and the last with "over" taken off by the same rule. A line whose Scribe text lacks what Apple's had there (the wake phrase in the first line, the closing "over" in the last) uses Apple's. Dispatch waits only for lines still out, each up to its deadline.
  - Varnick's own steps (Settings › Experimental) keep Apple's text: their search runs on the request while it is being said.
- **The connection is warmed** when it will be needed: at the wake phrase whatever voice is chosen, and at the first chunk of a phone segment, with a request that carries only the key (or the chosen voice's id, as the warm-up does today).
- **Logs:** the phone's segment timing line and the Mac's Voice session timing line gain, per segment or line, which text was used, why Apple's when it was (off, no key, a failure's kind, late) and both durations. Never the audio, either text, a name from the list or the key.
- **The records** (the builder writes them, at acceptance):
  - **A new ADR:** a spoken request's audio can be transcribed by ElevenLabs' Scribe v2 (batch), per Mac, off by default, with Apple's text standing by; the wake phrase stays on the Mac; Listening's transcript stays Apple's. It amends ADR 0015 (a spoken request's audio can now leave the Mac), ADR 0033 ("never audio from the Mac" holds only with the switch off) and ADR 0043 (speech becomes text with Listening's transcriber, or with ElevenLabs; "what the transcriber hears is on-device"), each with a dated amendment line.
  - **`docs/privacy-and-security.md`:** What stays on your Mac (what you say and hear, except a request's audio with the switch on), ElevenLabs (a new "What you say" entry: the segments and lines above, the names list, that ElevenLabs keeps them, the key's Speech to Text permission), and Voice mode on the phone (the audio goes to the Mac and, with the switch on, from the Mac to ElevenLabs).
  - **Settings text:** the switch, and the ElevenLabs key row's list of permissions.
  - **`CONTEXT.md`:** Voice mode's Phone page bullet and **Segment** ("the Mac turns each into text": with Apple's transcriber, or ElevenLabs with the switch on).
  - **`docs/agents/where-it-breaks.md`:** Voice mode on the phone (its transcriber bullet) and Listening and spoken requests (the window and its thread rule, the lines, what a transcription request carries, the logging rule).

## Testing Decisions

- **The pure functions, by `make check-voice` cases** (the shared package's `voice-check`, where the "over" rule and the collector are checked today):
  - the choice: Scribe in time; Scribe blank in time; Scribe late; Scribe failed; Apple failed and Scribe answered; both failed;
  - a Mac request made from its lines: one line holding the wake phrase, the request and "over"; several lines; Scribe's first line without the wake phrase; Scribe's last line without "over"; a line still out at its deadline; Voice mode lines with no wake phrase;
  - the names: trimming, duplicates, refused characters, a name over 50 characters or 5 words, the cut at 100, "Varnick" always first.
- **`make build`.** The request to ElevenLabs and the window are checked by hand, as speaking's were (no test target).
- **By hand, after the user restarts the Mac on the build** (agents don't drive the screen, and the Voice session runs with permissions skipped):
  1. Switch off: a phone request and a Hey Varnick request; the logs show no transcription request.
  2. Switch on, at the desk, phone Voice mode: a request naming someone Apple gets wrong; the view shows the name right, and the log says Scribe's text was used and how long it took.
  3. The same by Hey Varnick, and in Voice mode at the Mac.
  4. The Mac's network off: Apple's text, with no wait beyond the failure.
  5. A key without the Speech to Text permission: Apple's text, and the note under the switch names the permission.
  6. In the car with Car mode on: several requests with names, judged by the user against before; the log's added time on the last segment.

## Out of Scope

- **Listening's day transcript.** It stays Apple's and stays on the Mac (Further Notes has the cost of the alternative).
- **Waking, or "over" at the Mac, on Scribe's text.** Nothing is sent before the wake phrase.
- **A switch on the phone page.** The phone follows the Mac's switch.
- **Varnick's own steps,** which keep Apple's text.
- **Scribe v2 Realtime** (option 02) and **Apple's dictation model** (option 03).
- **A headless host,** which has no transcriber and no Voice mode.
- **Keeping any audio,** on the Mac or the phone.

## Further Notes

- **Siblings:**
  - ElevenLabs speaking (ADR 0033): the module, its kept connection with no redirect, its failure sorting, the note under the Voice picker, the warm-up, and the rule that each line tries afresh;
  - the phone's per-segment transcription, which this wraps;
  - Save audio's hand-off from the microphone callback to a serial queue, which the window copies;
  - the Voice row in Settings › Listening, for the switch and its note;
  - the "over" rule and the request-text rule in the shared package, beside which the new pure functions go.
- **Assumptions:**
  - The audio Scribe gets is the audio Apple gets: the phone's segment after the browser's noise suppression, and at the Mac the speech format Listening converts to. Nothing is cleaned further.
  - English only, as Listening.
  - Scribe's blank reply wins over Apple's words: in road noise a blank is likelier noise than a missed request.
  - The deadline is 2 s from the start of both, set by the hand test.
  - "Varnick" is always a keyterm, so the $0.05 an hour for keyterms is always paid.
  - At the Mac, a line goes to Scribe only once Apple has finished it, so Apple decides where lines begin and end.
- **Open questions for the user, each with a recommendation:**
  - *Spending.* ElevenLabs bills per minute of audio sent; estimated under $3 a month at 30 requests a day, and drawn first from the plan's allowance. Recommend yes.
  - *Privacy.* The request's audio, and anyone else's the microphone hears in Voice mode, goes to ElevenLabs and is kept there. Recommend yes, with the switch off by default.
  - *Where the switch is.* On the Mac only; the phone follows it. Recommend Mac only: the Mac holds the key and does the transcribing, and a phone switch would need a new request from the phone to change a Mac setting (as the phone's automation switch does). A later option can add it.
  - *Requests only, or Listening's whole day too.* Recommend requests only. Every word the Mac's microphone hears all day would go to ElevenLabs, against "what you say and hear stays on your Mac" for everyone who only wants better requests, and streaming 10 hours a day is about 300 hours a month, about $117 at the Realtime price before names.
  - *The names.* The user lists the names Varnick gets wrong; recommend starting with the ones he has heard it miss.
  - *The key.* The ElevenLabs key needs the Speech to Text permission added in ElevenLabs; until then, Apple's text is used and the switch's note says why.
  - *The earlier option.* `spoken-answers-sound-robotic` option 02 is replaced by this; recommend setting it `abandoned` with that reason.
- **Considered and not chosen:**
  - *Sending each Mac request's whole audio once, after "over".* One call and full context, but the wait is one call over the whole request, and silences between lines are billed. The lines go as they finish instead.
  - *Calling Apple only when Scribe fails.* Apple's text would then cost its own pass after Scribe's failure; running both at once makes the fallback free of waiting.
- **Verified in the code at fe1cf87:** the phone's segments are transcribed one pass each, several at once, with no hint, and a quiet segment skipped; Listening's results carry their audio time on its clock, and its microphone callback hands Save audio's buffers to a queue; the four contextual strings and the comment that they changed nothing; the Voice session's request ends only at "over", decided on each final line; the ElevenLabs module's kept connection, no redirects and failure sorting; the app has no WebSocket client.
- **Read in ElevenLabs' documentation on 2026-11-02:** the endpoint's parameters (raw 16 kHz input, keyterms and their limits, the 20 s minimum over 100 keyterms, language code), the prices, the retention rule, the absence of a published batch latency.
- **Inferred:** Scribe's latency on segments longer than 1 s; that Scribe does better than Apple on the user's voice in the car; the name of the key's Speech to Text permission as ElevenLabs reports it.
