---
title: Spoken answers sound robotic
description: Varnick speaks every Hey Varnick answer with Apple's on-device synthesizer, in the voice Settings › Listening › Voice names. Even the best installed voice, a Premium one such as Ava, sounds flat and synthetic beside current neural voices. On 2026-10-10 the user listened to four ElevenLabs voices (Sarah, River, George and Brian, on the Flash v2.5 model) against Ava (Premium), the voice they use, and found all four much better.
impact: Speech is the whole of a spoken request's response (ADR 0015): nothing is shown, so every answer is heard in the voice Varnick has. A voice that is tiring to listen to makes each answer worse, and makes Hey Varnick feel like a demo rather than an assistant. No answer is lost or wrong because of it.
severity: low
evidence: The user's listening comparison of 2026-10-10. Single calls to the ElevenLabs API on 2026-10-10 with a Starter-plan key, not a benchmark (figures under "Measured"). The code was read on 2026-10-10 at 0b289b0.
status: closed
---

## Today

All of this was read in the code at 0b289b0.

**How Varnick speaks** (`Speaking.swift`)
- `Speaker.speak` is the only way Varnick speaks. Hey Varnick's answers, its fixed lines ("I couldn't answer that.", the off-topic line, the line said when the wake phrase comes alone) and nothing else go through it. The wake sound is a system sound played apart from it.
- `AVSpeechSynthesizer` renders the text to buffers, and `SpeechPlayback` plays them on Varnick's own `AVAudioEngine` as they arrive. A voice that renders nothing is spoken by the synthesizer directly instead, the one path that may play from a system process.
- `SpeechSpans` is opened before anything is rendered and closed after the last sound. Listening drops mic results whose audio began inside a span, plus a 0.5 s tail, so Varnick never hears or wakes itself. The system audio tap leaves Varnick's own process out, which is why the sound must come from this process (ADR 0015).
- `SpeechPlayback` gives up when nothing has arrived after 5 s, and ends any speech after 90 s.
- The spoken request timing line logs when speaking began, the render time and the first sound. The answer is never logged; it is written to the day's transcript as a `[varnick]` line.

**Choosing a voice** (`SpokenVoices`, `VoicePicker`, `Settings.voice`)
- Settings › Listening › Voice offers "System default" and the installed voices whose language starts "en", without the novelty voices, each named with its language and Premium or Enhanced. A saved voice that is no longer installed shows as "Not installed".
- The choice is one UserDefaults string, `voice`: an `AVSpeechSynthesisVoice` identifier, or empty for the system voice.

**Keys** (`Keychain.swift`, Settings › Models › Keys)
- The TypeSafe key and the model server key are entered in Settings and kept in the login Keychain. The TypeSafe key also falls back to `TYPESAFE_API_KEY` from the environment or, in a checkout, `.env`, and is held in memory. The model server key is Keychain only, checked for without being read, and read when a request is sent.

**How a request is heard** (`Listening.swift`, `SpokenRequests.swift`): Apple's `SpeechTranscriber`, on this Mac, transcribes the mic; a final result that starts with the wake phrase begins a request, which collects the final results that follow within 1.5 s and is held 1 s after the last. Whether Apple mishears requests in ways that change the answer is unmeasured: the wake rule was measured on synthesized speech only, and recordings of a real voice are pending.

**What leaves the Mac for speech:** nothing. With the relevance filter On this Mac or off, Hey Varnick sends nothing to a third party: Text generation and Search embeddings run on this Mac or the user's own server.

## Measured

Single calls to the ElevenLabs API on 2026-10-10, on a Starter-plan key. They show what is possible, not a distribution.

| What | Result |
|---|---|
| Streaming text to speech (`POST /v1/text-to-speech/{voice_id}/stream`), Flash v2.5, warm connection | first audio 0.24 to 0.32 s after the request |
| The same, first (cold) call | first audio 1.35 s after the request |
| The same, Multilingual v2 | first audio about 1.46 s after the request |
| `output_format=pcm_24000` | works: raw PCM, no decoder needed |
| `GET /v1/voices` | 21 premade voices; the account has no cloned ones |
| Scribe v2 batch speech to text, a 1 s clip | text 0.58 s after the request |

The key needs the Text to Speech and Voices Read permissions. User Read is optional, for showing the remaining quota. Speech to text has a permission of its own (not checked here).

For comparison, Apple's synthesizer takes about half a second to render a sentence before the first sound (a comment in `SpokenRequests`, not measured here).
