---
problem: spoken-requests-get-words-wrong
title: ElevenLabs' Scribe v2 Realtime streams each request as it is said
summary: The same switch and names list as option 01, with ElevenLabs' streaming model in place of its batch one. The Mac keeps a stream open to ElevenLabs while a request is being made and passes on the audio as it arrives: each phone segment chunk by chunk, and at the Mac the request from the wake phrase's line until "over". ElevenLabs commits the text at each pause, about 150 ms after it, so the wait after "over" shrinks to that plus the network. It costs about 1.7 times option 01 per hour, takes 50 names of up to 20 characters, and adds the app's first WebSocket client, which must be kept alive and recovered. Apple's text stands by as in option 01.
status: proposed
---

## Solution

Settings › Listening gets the switch and the names list of option 01, with the same consent, the same per-Mac rule and the same note under it.

With the switch on, the Mac opens a stream to ElevenLabs' Scribe v2 Realtime when a request starts being made, and closes it when the request is taken or abandoned:

- **On the phone,** a stream opens at the first chunk of a Voice mode run and passes each chunk on as it reaches the Mac. When a segment's last chunk arrives, the Mac commits it, and the committed text is the segment's words when it comes within the deadline; Apple's otherwise, as in option 01. The stream closes when the run ends (End, a new Start) or after a quiet spell, and reopens at the next chunk.
- **At the Mac,** once Apple hears the wake phrase, the stream gets that line's audio from Listening's in-memory window (option 01's) and then the microphone's audio live until Apple hears "over", when the Mac commits and uses the committed text, wake phrase and "over" taken off by today's rules. In Voice mode the stream stays open from the first line until Voice mode ends or goes quiet.

Everything else is as option 01: Apple runs as today, "over" and the wake phrase are decided as today, and nothing is sent before the wake phrase.

## Trade-offs

- **Faster after "over", by an unmeasured amount.** ElevenLabs gives about 150 ms median from a commit to its text, measured on its side. Option 01's batch request for the last segment is unmeasured beyond a 1 s clip in 0.58 s; the difference is likely a few tenths of a second per request, against an answer that takes several seconds.
- **About 1.7 times option 01's price.** $0.39 an hour plus $0.08 for names, $0.47 against $0.27. At 30 requests a day of 10 s each (about 2.5 hours a month) that is about $1.20 a month. Billing is per second sent, silence included: at the Mac the stream carries the pauses between the lines of a request, and in Voice mode the whole stretch it stays open, so a Voice mode session at the desk is billed for its length, not its speech.
- **Fewer, shorter names.** 50 keyterms of up to 20 characters each, against option 01's 100 used of the 1,000 allowed, each up to 50 characters.
- **A new kind of connection to keep healthy.** The app has no WebSocket client today. A stream can drop mid-segment, hit ElevenLabs' session time limit (an error the API names; its length is not in what was read) or lag behind; each case must fall back to Apple for the segment and reopen for the next. ElevenLabs warns that committing several times in quick succession can degrade results; the phone's segments come seconds apart, a burst of short ones does not.
- **The same privacy change as option 01,** with more of it at the Mac: the stream there carries everything the microphone hears between the wake phrase and "over", pauses and background included, not only Apple's finished lines.
- **More to get wrong at the Mac.** The committed text replaces the whole request rather than line by line, so a stream that lagged or dropped a stretch replaces a whole request with Apple's.

## User Stories

1. As the user, I want one switch on the Mac for both surfaces, so that I turn it on once.
2. As the user, I want my request's words back as soon as I stop speaking, so that the conversation in the car feels quick.
3. As the user, I want Apple's words used whenever the stream fails, so that a request is never lost to it.
4. As the user, I want the stream closed when I'm not making a request, so that I am not billed for silence.
5. As the user, I want the names I list listened for, so that names come out right.
6. As the user, I want the switch's text to say what is streamed and that ElevenLabs keeps it, so that I choose knowingly.
7. As a maintainer, I want each stream's opening, drops and reopenings in the log by kind and time, never a word, so that I can tell whether it holds up.

## Implementation Decisions

- **The switch, the names list (cut at 50, each at most 20 characters), the consent text, the note, the choice of text and the records** are option 01's.
- **One stream at a time per phone and Voice mode run,** opened at the first chunk and closed when the run changes or after a quiet spell (a named constant). Commits are manual, one per segment, at its last chunk.
- **At the Mac, one stream per request,** or per Voice mode stretch, fed first from option 01's in-memory window and then live from the microphone's callback through the same serial-queue hand-off.
- **The stream carries** 16 kHz mono 16-bit PCM, English, the names as keyterms, the key in its header and nothing else; it follows no redirect.
- **Every failure falls back to Apple for what the stream had not committed,** and the stream reopens for the next segment or request. Nothing rests ElevenLabs.
- **Logs:** opened, committed, dropped and reopened by kind and time; which text was used per segment or request and why. Never audio, text or names.

## Testing Decisions

- The choice of text and the names list as option 01, by `make check-voice`, with the Realtime limits.
- The stream's lifecycle by a pure state machine in the shared package (opened, sending, committed, dropped, closed), checked by cases; the connection itself by hand.
- By hand after a restart: option 01's six steps, plus a stream dropped mid-segment (the Mac's network off while speaking): that segment in Apple's words, the next in Scribe's.

## Out of Scope

As option 01: Listening's day transcript, waking on ElevenLabs' text, a switch on the phone, Varnick's own steps, a headless host, keeping audio.

## Further Notes

- **Not recommended:** it buys a few tenths of a second per request with a second kind of connection, a higher rate, a smaller names list and billing for the pauses at the Mac. Worth it only if option 01's measured wait after "over" turns out too long.
- **Siblings:** option 01's; the phone page's own WebSocket to its server (in the page, not the app) is the nearest stream in the codebase.
- **Read in ElevenLabs' documentation on 2026-11-02:** the Realtime price and its keyterm price, the 50-keyterm and 20-character limits, the 150 ms median and what it measures, manual and automatic commits and the warning on frequent commits, the session time limit error.
- **Inferred:** the latency difference against option 01; how often a stream would drop over the Mac's connection.
