---
problem: spoken-answers-sound-robotic
title: Speak answers in an ElevenLabs voice, with the installed voice as fallback
summary: An ElevenLabs key is entered in Settings › Models › Keys and kept in the Keychain. Settings › Listening › Voice then lists the account's ElevenLabs voices beside the installed ones. With one chosen, Varnick streams each line it speaks from ElevenLabs' Flash v2.5 as raw PCM and plays it on its own audio engine, where the synthesizer's buffers play today, so the sound still comes from Varnick's process and Varnick still never hears itself. One kept connection, warmed when "Hey Varnick" is heard, puts the first sound about a quarter of a second after the request. If ElevenLabs fails, or sends no audio within 1.5 s, the line is spoken in the installed voice, so an answer is never lost. Choosing an ElevenLabs voice is consent to send every line Varnick speaks to ElevenLabs.
status: accepted
---

## Solution

A new **ElevenLabs** row in Settings › Models › Keys takes the key and keeps it in the login Keychain. With a key saved, the Voice picker in Settings › Listening lists the account's ElevenLabs voices in a section of their own, below the installed voices. Picking one makes it Varnick's voice. The installed voice that was chosen before stays saved, as the **fallback voice**, in a row that appears below.

Each line Varnick speaks then goes to ElevenLabs' streaming text-to-speech endpoint on the Flash v2.5 model, asking for 24 kHz PCM. `Speaker` turns the bytes into audio buffers as they arrive and plays them on its own audio engine, exactly as it plays the synthesizer's buffers today. ADR 0015's constraint holds: the sound comes from Varnick's process, which the system audio tap leaves out, and the `SpeechSpans` span opens before the request and closes after the last sound.

One connection to ElevenLabs is kept and reused, and opened when "Hey Varnick" is heard, so it is warm by the time the answer is written. When ElevenLabs answers with an error, can't be reached, or sends no audio within 1.5 s, the line is spoken in the fallback voice through the synthesizer, as today.

## Trade-offs

- **The answer's text leaves the Mac.** With an ElevenLabs voice chosen, every line Varnick speaks goes to ElevenLabs. An answer names pages, sites, page descriptions, session titles and folders, and what the user's prompts said, and can repeat words of the request. With the relevance filter On this Mac or off, Hey Varnick sent nothing to a third party; with an ElevenLabs voice it does. Choosing the voice is the consent (the user's rule: choosing a provider counts as consent, with no per-item splits). The installed voices stay the default and send nothing.
- **A much better voice,** by the user's own comparison on 2026-10-10.
- **Usually faster than today, sometimes slower.** Warm, the first audio came 0.24 to 0.32 s after the request, against about half a second for Apple's render. Cold, it came after 1.35 s; the warm-up at the wake is meant to hide that (unverified). On a fallback the first sound comes up to 1.5 s later than it does today, plus Apple's render.
- **The mic is deaf a little longer.** The span covers the wait for ElevenLabs, as it covers Apple's render today, so what the user says in that time is dropped from the transcript. That is up to 1.5 s more than today when ElevenLabs is slow.
- **It needs the network and the plan's quota.** Offline, the request fails at once and the fallback speaks (inferred: a failed connection doesn't wait for the deadline). Each line uses its characters from the plan's monthly quota; once it runs out, every line falls back, and the Voice row says why.
- **Pronunciation is unchecked.** Whether Flash v2.5 reads dates, times, numbers and site names as a person would hasn't been tried with Varnick's answers. A hand check.
- **One more provider and one more key** in Settings, the privacy page and the README.

## User Stories

1. As a Varnick user, I want to hear Hey Varnick's answers in a natural voice, so that listening to them isn't tiring.
2. As a Varnick user, I want to enter my ElevenLabs key once in Settings and have it kept in the Keychain, so that it isn't sitting in a file.
3. As a Varnick user, I want the ElevenLabs voices my account has to appear in the same Voice picker as the installed ones, so that choosing a voice stays one choice.
4. As a Varnick user, I want my installed voice kept as the fallback when I switch to an ElevenLabs voice, so that a failure sounds like the voice I chose before, not a stranger's.
5. As a Varnick user, I want to change the fallback voice without leaving my ElevenLabs voice.
6. As a Varnick user, I want an answer spoken in the fallback voice when ElevenLabs fails, is offline or is slow, so that I never lose an answer.
7. As a Varnick user, I want the first word to come as quickly as it does today or quicker, so that the better voice doesn't cost me waiting.
8. As a Varnick user, I want Varnick never to hear or wake itself, whichever voice speaks.
9. As a Varnick user, I want Settings to tell me when ElevenLabs refused my key or I ran out of characters, so that I know why the voice changed.
10. As a Varnick user, I want Settings and the privacy page to say plainly that an ElevenLabs voice sends what Varnick says to ElevenLabs, so that choosing it is an informed choice.
11. As a Varnick user, I want the installed voices to keep working exactly as now, with nothing sent, while no ElevenLabs voice is chosen.
12. As a Varnick user, I want stopping Hey Varnick or Listening to stop an ElevenLabs answer at once, with no fallback following it.

## Implementation Decisions

**Decided by the user (2026-10-10)**
- ElevenLabs speaks with **Flash v2.5** only, pinned in code like `SpokenRouter.pinnedModel`, with no model picker. Multilingual v2's measured 1.46 s to first audio leaves no room under the fallback's deadline.
- **Fallback:** an ElevenLabs error, or no audio within about 1.5 s, and the line is spoken in the installed voice.

**The key**
- A row **ElevenLabs** in Settings › Models › Keys, below TypeSafe, built as the model server key's row is: a secure field and Save, then "Key saved" and Remove key, with a save error shown in the row. Kept in the login Keychain under its own account (`ELEVENLABS_API_KEY`, beside `TYPESAFE_API_KEY`). Settings checks that it exists without reading it; it is read when a request is sent.
- No environment variable and no `.env`. TypeSafe's `.env` fallback serves runs from a checkout such as `--search-eval`, and nothing here runs without Settings. A key picked up from a file would send every spoken line to a third party without the user having chosen ElevenLabs in Settings, and that choice is the consent.
- The row's detail says it is for ElevenLabs voices in Settings › Listening, that the key needs the Text to Speech and Voices Read permissions, and that it is kept in the macOS Keychain.
- The key goes only in the `xi-api-key` header to ElevenLabs' API, and is never logged.

**Choosing a voice**
- The Voice picker lists "System default", then the installed voices as today, then a section **ElevenLabs** with the account's voices, each by its name and "ElevenLabs".
- The list comes from `GET /v1/voices`: every voice the account has, premade or not, whatever its language. It is fetched off the main thread when Settings › Listening appears with a key saved, and again after a key is saved. The last list is kept in UserDefaults (`elevenLabsVoices`, each voice's id and name) and shown meanwhile, and offline.
- With no key saved, the row shows a link beside the picker, "ElevenLabs voices: add a key in Settings › Models", as Point at the screen links to Settings › Search.
- Saved state: `voice` keeps its meaning, the installed voice or empty for the system voice, and is the fallback voice. A new string, `elevenLabsVoice`, holds the chosen ElevenLabs voice's id; empty means the installed voice speaks. Picking an installed voice sets `voice` and empties `elevenLabsVoice`. Picking an ElevenLabs voice sets `elevenLabsVoice` and leaves `voice` as it was.
- With an ElevenLabs voice chosen, a **Fallback voice** row appears below Voice, holding the installed-voice picker bound to `voice`: "Speaks on this Mac when ElevenLabs fails or is slow."
- A chosen voice that the last list lacks shows as "Not available", as a missing installed voice shows "Not installed", and is still asked for; a refusal falls back.
- Data already saved: nothing changes until an ElevenLabs voice is picked, and then the installed voice already saved becomes the fallback as it stands.
- Removing the key leaves `elevenLabsVoice` saved. With no key, the installed voice speaks without anything being sent, and the row shows the link.

**Speaking**
- It all happens inside `Speaker.speak`, after the span opens. With an ElevenLabs voice chosen and a key saved, it posts the line, the model and the voice to `POST /v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000` and reads the body as it arrives.
- The body is 16-bit signed little-endian mono PCM at 24 kHz (ElevenLabs' documented layout, not checked byte by byte; "works" was measured). It is turned into float buffers of one fixed format, 24 kHz mono, and handed to a `SpeechPlayback` as the synthesizer's buffers are, with an empty buffer when the body ends. A byte left over at the end of a chunk is carried to the next. Chunks are gathered into buffers of at least about 50 ms, so the player is never handed slivers.
- `SpeechPlayback` is unchanged in role: one format per speech, the first sound's time, stop. Its 5 s and 90 s limits stay.
- `speak` still returns the first sound's time, and also says who spoke, for the timing line.
- `stop()` cancels the request as well as the playback. A line that was stopped goes to no fallback, as the `stops` count ensures today.
- Every line goes this way: answers and the fixed lines alike. There is one voice, not one per kind of line.

**A warm connection**
- One `URLSession` for ElevenLabs, made once and kept, as `SpokenRouter`'s and `Reranker`'s are. The voice list, the warm-up and every line share it and its connections.
- When "Hey Varnick" is heard, where the wake sound plays, and only with an ElevenLabs voice chosen and a key saved, Varnick sends `GET /v1/voices/{voice_id}` for the chosen voice. It needs only Voices Read, uses no characters and carries nothing of the user's. Its reply is ignored, and a failure logs only its kind. The answer comes at least the hold later, so the connection is open by then.
- No keep-alive requests between spoken requests: Hey Varnick can sit idle for hours, and the warm-up at the wake covers the first line after any idle.
- Unverified: whether the cold call's 1.35 s is all connection setup, which the warm-up removes, or partly ElevenLabs' side warming a voice. The first sound in the timing line, on the first request after a long idle, says.

**The fallback**
- The line is spoken in the installed voice, through the synthesizer exactly as today (its own render-nothing fallback included), when there is no key, the request fails to connect, the status is not 200, the body holds no audio, or no audio has arrived 1.5 s after the request was sent. On the deadline the request is cancelled and its playback stopped, so late audio never plays over the fallback.
- The span stays open across both, from before the request to after the installed voice's last sound.
- A stream that breaks after sound began (an error, or no new bytes for 1.5 s) stops what was playing, and the whole line is spoken again in the installed voice. Answers are one or two sentences, so repeating one is cheap, and a half-heard answer is a lost one.
- Each line tries ElevenLabs afresh. Nothing rests it after failures.
- The Voice row shows the last failure under the picker until a line plays from ElevenLabs again: "ElevenLabs refused the key" for 401, "ElevenLabs answered <status>" for another status, "ElevenLabs not answering" or "ElevenLabs too slow". Held in memory, not saved.

**Logs**
- The spoken request timing line names who spoke: ElevenLabs with its time to first audio, or the installed voice with the failure's kind (the status code, the error's `logKind`, or "slow"). The line's text, the voice's name and the key are never logged.

**What leaves the Mac, and the docs it changes**
- With an ElevenLabs voice chosen and a key saved: the text of every line Varnick speaks, the voice's id and the key, to ElevenLabs. Never audio from the Mac, rows, or the request except as the answer repeats it. The warm-up sends only the voice's id and the key.
- A new ADR once accepted (the next number, 0028 today): spoken answers can be voiced by ElevenLabs and are still played by Varnick's own engine, the answer's text leaves the Mac with that voice, and the installed voice is the fallback. ADR 0015's Consequences gains an "Amended by" line where it says the speech is rendered by the system synthesizer.
- Privacy and security › "What leaves your Mac" gains an **ElevenLabs** section in the TypeSafe section's shape: choosing an ElevenLabs voice is consent to send every line Varnick speaks, what such a line can hold, the warm-up, and that the installed voices are the private choice.
- The README's Privacy list gains a bullet, and the guide's Listening section a sentence on voices.
- Settings texts: the Voice and Fallback voice rows, the Keys row, and Hey Varnick's detail, which says that with an ElevenLabs voice its answers go to ElevenLabs.
- Where Varnick breaks › "Listening and spoken requests" gains the rules: ElevenLabs audio plays only through `SpeechPlayback` inside `Speaker.speak`; the span covers the wait and the fallback; the fallback's triggers and its 1.5 s deadline; nothing of the line or the key in the logs.

## Testing Decisions

There is no test target. Verification is `make build`, then by hand after the user restarts Varnick:

- With an ElevenLabs voice and a key, ask a spoken request: the answer is in that voice, the timing line says ElevenLabs and its first audio, and the transcript has the `[varnick]` line with no `[system]` line of the answer and no `[mic]` echo of it.
- The first request after Varnick has been idle at least ten minutes: the first sound in the timing line, against the 1.5 s deadline.
- Wi-Fi off: the fallback voice speaks at once, the timing line names the failure, and the Voice row says ElevenLabs is not answering.
- A wrong key saved: the fallback speaks, and the row says the key was refused.
- Key removed: the installed voice speaks and nothing is sent.
- Hey Varnick turned off while an ElevenLabs answer plays: it stops, and no fallback follows.
- Answers with dates, times and numbers, to hear how Flash v2.5 reads them.
- Settings › Listening opened offline: the last voice list shows.

Once a test target exists, the pure parts are worth tests: PCM bytes into buffers (an odd byte at a chunk's end, tiny chunks), the voice list's decoding, and the fallback rule (status, error and timeout to installed voice).

## Out of Scope

- A model picker, and voice settings such as stability, speed or style.
- Speaking while Text generation writes the answer (ElevenLabs' WebSocket input): the answer is written whole before it is spoken today.
- Caching the fixed lines' audio.
- Showing the remaining quota, which would need the optional User Read permission.
- Resting ElevenLabs after repeated failures, as `ModelServerState` rests a server.
- Cloning a voice, and other speech providers.
- Listening, the wake sound, and speech to text (option 02).

## Further Notes

**Considered and rejected**
- **The ElevenLabs Agents platform.** It runs the whole conversation on ElevenLabs' side: the user's audio, the model that answers and the voice. That conflicts with ADR 0015, where Text generation answers on this Mac or the user's own server and the rows go to no cloud model.
- **Multilingual v2 or a model picker.** The user chose Flash v2.5 only.
- **Keep-alive requests all day.** The warm-up at the wake does the same for the request that matters, and sends nothing while Hey Varnick is idle.
- **Reading the key from `.env` or the environment,** as TypeSafe's does: see The key.

**For the user to confirm**
- **The fallback is the installed voice already chosen,** kept in its own row. Simpler, with no extra row: fall back to "System default" always, at the cost of the user's chosen voice (Ava, Premium) not being the fallback.
- **A broken stream repeats the whole line** in the fallback voice. The other choice is to stop where it broke.
- **The fixed lines go to ElevenLabs too.** The other choice is to keep them in the installed voice, which would mix two voices.

**Verified in the code at 0b289b0:** every spoken line goes through `Speaker.speak`; the span opens before rendering and closes after the last sound; `SpeechPlayback` takes any PCM buffers of one format, with an empty one as the end; the model server key's Keychain-only row; `SpokenRouter`'s kept session and 1.5 s timeout; the wake sound's place in `SpokenRequests`. **Inferred:** ElevenLabs' byte layout and endpoints from its documentation and the measurements in `problem.md`; that the warm-up removes the cold cost; that an offline request fails before the deadline.
