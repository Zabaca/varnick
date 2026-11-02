---
title: Spoken requests are heard with wrong words and names, worst in the car
description: Every spoken request, Hey Varnick at a Mac and Voice mode on a Mac's Phone page alike, becomes text through Apple's on-device transcriber on that Mac. The user reports that it hears him but gets words and names wrong, most of all in the car, where Car mode now opens the phone's microphone without echo cancellation and more road noise reaches it. The Voice session then works on a request he didn't make.
impact: A misheard request is answered wrongly or not at all and has to be said again, by voice, while driving. Names (people, projects, Varnick itself) are what it gets wrong, and they are what most requests turn on. The Voice session runs with permissions skipped (ADR 0042), so a wrong word can also run the wrong command without asking.
severity: mid
evidence: The user's ask of 2026-11-02, relayed by the coordinator ("can we build a flag/toggle to use ElevenLabs for transcription of my audio vs Apple?"), and his answers the same day (below). Code and docs read at fe1cf87 (main). ElevenLabs' speech to text documentation and API price page, read 2026-11-02. Apple's time per segment and the user's Voice mode use, read from Varnick's log on the user's machine on 2026-11-02; figures kept locally. No recording of a misheard request exists, so how often Apple gets a request wrong, and whether ElevenLabs does better on the user's voice in the car, are unmeasured.
status: open
---

## What the user wants

1. **A switch that has ElevenLabs, not Apple, turn his speech into text.**
2. **One setting for both surfaces:** Voice mode on a Mac's Phone page (relayed to that Mac's Voice session, ADR 0043) and Hey Varnick at the Mac, Voice mode there included (Listening, ADR 0044). Not the phone alone.
3. **The symptom it is for: wrong words and names.** Not requests cut off, and not speech missed.

## Today

Verified in the code at fe1cf87 unless marked.

- **Voice mode on the phone.** The page cuts **segments** at each pause and sends each to the Mac as 16 kHz mono 16-bit audio, with 300 ms before the first word and up to 900 ms of quiet after the last. The Mac runs each whole segment through Apple's speech transcriber (English, US) in one pass, several at once, with no vocabulary hint. A segment quieter than a fixed floor is not transcribed. The segment's words join the request the Mac is collecting for that phone; one that ends with "over" ends it. Apple's pass takes a fraction of a second per segment (measured on the user's machine; figures kept locally).
- **Hey Varnick and Voice mode at the Mac.** Listening runs Apple's transcriber on the microphone all day, and another on the Mac's own audio, and writes the day's transcript. The wake phrase, each line of a request and "over" are all read from its final microphone results, which carry their audio's time on Listening's clock. The audio is not kept once transcribed, except to files with Save audio on.
- **Apple's vocabulary hint was tried.** Listening gives its microphone analyzer four contextual strings (Varnick, Hey Varnick, Jev, TypeSafe); a comment there records that they changed no transcript on macOS 26.5.1. The phone's segments get none. Apple's other on-device model in macOS 26, the dictation transcriber, takes a far-field hint and a custom language model built from phrases and pronunciations (read in the macOS 26 SDK); Varnick doesn't use it.
- **The wake rule already absorbs Apple's misspellings of "Varnick"** (varnik, Varnet, Varney, Barnick), taken from real misses. Other names have no such net.
- **ElevenLabs already speaks** (ADR 0033): its key is entered in Settings › Models › Keys and kept in the Keychain; one kept connection follows no redirect; a failure is sorted into a kind shown under the Voice picker; the installed voice is the fallback. The key is documented as needing Text to Speech and Voices Read. Speech to text needs a permission of its own, not checked on the user's key.
- **No audio leaves a Mac today.** The privacy page says what you say and hear stays on your Mac; ElevenLabs gets "never audio from your Mac"; the phone's audio "goes to the Mac over the tailnet and nowhere else", where the transcriber is on-device (ADR 0043). Sending audio to ElevenLabs reverses all three, so it needs an ADR and the privacy page; `where-it-breaks.md` already says anything more in an ElevenLabs request is a privacy change needing the privacy page and the Settings text.
- **Car mode** (merged at fe1cf87) opens the phone's microphone without echo cancellation, keeping noise suppression and gain control, so sound stays on the car's Bluetooth. More road noise, and music from the car's speakers, can now reach the microphone. The user has tested the routing; how much noise reaches the microphone is unmeasured.
- **An earlier option proposed this for Hey Varnick alone.** `spoken-answers-sound-robotic`, option 02 (proposed 2026-10-10, its problem closed), would transcribe Hey Varnick's request again with Scribe v2, to be built only if a measurement showed Apple mishears. Its reason to wait now has the user's report, and the request flow it was written for (a 1 s hold, Varnick's own steps) has since become the Voice session's, which ends only at "over". The options here cover both surfaces and replace it; its status is the user's to set.

## ElevenLabs speech to text, as documented on 2026-11-02

| | Scribe v2 (batch) | Scribe v2 Realtime |
|---|---|---|
| How it is called | one request per piece of audio, its text in the reply | a WebSocket: audio streamed in, partial then committed text out |
| Price | $0.22 an hour of audio | $0.39 an hour |
| Names to listen for (keyterms) | up to 1,000, each under 50 characters and 5 words; $0.05 an hour more; over 100 of them, each request is billed at least 20 s | up to 50, each up to 20 characters; $0.08 an hour more |
| Latency | no published figure: ElevenLabs says it is built for quality, not real time | about 150 ms median to a committed transcript, server side |
| Input | any common format, or raw 16 kHz mono 16-bit, which it says is faster | streamed PCM |

- **Billing** is by the second of audio sent, silence included. A self-serve plan's monthly price is an allowance shared by every product, spoken answers included (a $6 Starter plan covers 27 hours of Scribe v2 if nothing else used it). Which plan the user's key is on now is not checked.
- **Retention.** ElevenLabs keeps request data under its privacy policy; turning that off (zero retention) is for enterprise customers only.
- **Measured once,** on 2026-10-10 (`spoken-answers-sound-robotic`, Measured): Scribe v2 batch returned a 1 s clip's text 0.58 s after the request. Nothing longer was measured.
