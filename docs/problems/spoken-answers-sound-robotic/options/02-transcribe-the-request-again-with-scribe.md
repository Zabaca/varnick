---
problem: spoken-answers-sound-robotic
title: Transcribe the request again with ElevenLabs' Scribe v2 after "Hey Varnick"
summary: Unmeasured, and only worth building if a measurement shows it pays. Apple's transcriber still listens, wakes Varnick and writes the transcript. Once a spoken request has begun, Varnick also sends just that request's audio, kept in memory, to ElevenLabs' Scribe v2 batch speech to text. When Scribe's text comes back in time and differs from Apple's, Varnick answers Scribe's text instead. Nothing shows that Apple mishears requests today; the wake rule was measured on synthesized speech only, and recordings of a real voice are still pending. The request's audio, the user's voice and anything else the mic heard in those seconds, goes to ElevenLabs.
status: proposed
---

## Solution

A switch in Settings › Experimental, **Transcribe requests with ElevenLabs**, off by default, needing an ElevenLabs key (option 01's Keys row) with the Speech to Text permission.

With it on, Listening keeps the last 30 s of mic audio in memory while Hey Varnick is on, timed by the same audio clock its results use. While a request is being collected, each final mic result sends the audio from the wake phrase's start to that result's end to Scribe v2's batch endpoint. Varnick finds the request in Scribe's text with the same wake rule it applies to Apple's. When that text differs from Apple's beyond case and punctuation, Varnick starts preparing the answer on Scribe's text, as it already does each time Apple's text changes. When the hold ends, the answer waits for Scribe until 1.5 s after the last audio was sent, and otherwise goes with Apple's text.

The transcript keeps Apple's text: Scribe only replaces the request.

## Trade-offs

- **The benefit is unmeasured.** No data says Apple mishears requests in ways that change the answer. The wake rule's measurement used synthesized speech, and the real-voice recordings it awaits would also answer this. Until then, this option could add cost and latency for nothing.
- **The user's voice leaves the Mac.** Every spoken request sends a recording of the user saying it, the wake phrase included, and whatever else the mic heard in those seconds: someone else in the room, a call or a video through the speakers. A request said in several phrases is sent several times, a longer clip each time. A voice recording is more sensitive than the answer text option 01 sends.
- **Slower when the texts differ.** Scribe returned a 1 s clip in 0.58 s; a three-to-six-second request, uploaded, is unmeasured. Sending at each final result hides some of it inside the 1 s hold, but when Scribe's text differs the preparation restarts later and loses its head start.
- **It touches Listening,** though not its transcription: the mic's feed gains an in-memory buffer. Listening's own behaviour, and what it writes, stay as they are.
- **Cost:** speech to text is billed by audio time from the plan (rates not checked).
- **Waking still depends on Apple.** A request Apple never wakes on is not helped.

## User Stories

1. As a Varnick user, I want my spoken request understood as I said it, so that the answer is about what I asked.
2. As a Varnick user, I want Apple's text used when ElevenLabs is slow or fails, so that a request is never lost to it.
3. As a Varnick user, I want this off unless I turn it on, and Settings to say my request's audio goes to ElevenLabs, so that I choose it knowingly.
4. As a Varnick user, I want my transcript and Listening to work as they do now.
5. As a maintainer, I want the timing line to say whether Scribe's text was used and how long it took, so that I can tell whether it pays.

## Implementation Decisions

- **Measure first.** Before this is built, a measurement compares Apple's and Scribe's text on real spoken requests in the user's own voice, and whether the difference changes the decide step, the search or the answer. It runs in the lab where every eval here lives, with the recordings kept private. Build only if it shows requests misheard often enough to matter.
- The mic buffer is filled only while the switch, Hey Varnick and Listening are all on, is never written to disk, and is dropped when any of them turns off.
- Audio goes as 16 kHz mono 16-bit, in a WAV, or raw if Scribe takes raw PCM (not checked). "Varnick" goes as a key term if Scribe's batch endpoint takes one (not checked).
- A Scribe reply that holds no wake phrase, or comes for audio older than the latest sent, is ignored.
- Scribe's request uses option 01's kept connection, so it is warm from the wake's warm-up.
- The logs carry Scribe's time, whether its text was used, and a failure's kind; never either text.
- Docs on acceptance: an ADR (Listening's audio leaves the Mac for the first time, for the request only), the privacy page's ElevenLabs section, the Settings text, and Where Varnick breaks.

## Testing Decisions

No test target. `make build`, then by hand after a restart: a request said clearly (Scribe's text used or matching, the answer unchanged), a request with a proper noun Apple misspells, Wi-Fi off (Apple's text answers with no extra wait beyond the failure), and the switch off (nothing sent). The measurement above is the real test.

## Out of Scope

- Waking on Scribe's text, or anything that sends audio before the wake phrase is heard.
- Writing Scribe's text to the transcript.
- Speaking in an ElevenLabs voice (option 01); this option needs option 01's key row and connection, not its voice.

## Further Notes

**Considered and rejected: replacing Listening's transcription with Scribe.** Streaming speech to text all day would send all the mic's and the system audio's sound to ElevenLabs, whenever Listening is on. That ends "What you say and hear stays on your Mac" for everyone who wants a better request, and bills hours of audio a day. The user is not asking to change Listening.

**Verified in the code at 0b289b0:** Listening times mic results with an audio clock and drops those inside a `SpeechSpans` span; a request is collected from final mic results within a 1.5 s gap and held 1 s after the last; `SpokenRequests` restarts the preparation each time the request's text changes. **Inferred:** Scribe's batch latency for clips longer than 1 s; its input formats and key-term support.
