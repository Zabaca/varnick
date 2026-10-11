# Spoken answers can be voiced by ElevenLabs, and the installed voice is the fallback

Hey Varnick spoke with Apple's on-device synthesizer, and even a Premium voice sounded flat beside a current neural voice (the user's listening comparison of 2026-10-10). Varnick can now speak in an ElevenLabs voice. The key is entered in Settings › Models › Keys and kept in the Keychain; Settings › Listening › Voice then lists the account's voices beside the installed ones. With one chosen, `Speaker.speak` streams each line from ElevenLabs' Flash v2.5 model as 24 kHz PCM and plays it on Varnick's own audio engine, where the synthesizer's buffers played, so the sound still comes from this process and the span `SpeechSpans` still covers it (ADR 0015's constraint holds). The installed voice already saved stays, as the **fallback voice**: an ElevenLabs error, no audio within 1.5 s, or a stream that breaks mid-line, and the whole line is spoken in it. The problem and its options are in `docs/problems/spoken-answers-sound-robotic/`.

Decisions: ElevenLabs speaks with Flash v2.5 only, pinned in code, with no model picker; the installed voice is the fallback, in a row of its own; the key is Keychain only, with no environment variable or `.env`; choosing an ElevenLabs voice is the consent to send what Varnick speaks.

## Considered Options

- **Multilingual v2, or a model picker:** rejected. Multilingual v2's first audio, measured on the user's machine (figures kept locally), left nothing under the fallback's deadline.
- **The ElevenLabs Agents platform:** rejected. It runs the whole conversation on ElevenLabs' side, the user's audio and the model that answers included, against ADR 0015's rule that Text generation answers on this Mac or the user's own server.
- **Always falling back to "System default":** rejected. It would lose the voice the user chose before.
- **Keep-alive requests all day:** rejected. A request to `GET /v1/voices/{id}` when "Hey Varnick" is heard opens the connection ahead of the answer and sends nothing while Hey Varnick is idle.
- **Reading the key from the environment or `.env`, as TypeSafe's does:** rejected. A key found in a file would send every spoken line to a third party without the user having chosen ElevenLabs in Settings.

## Consequences

- **The key leaves the Mac, alone, once it is saved:** to list the account's voices when it is saved and when Settings › Listening opens. Saving it is the consent to that request.
- **The answer's text leaves the Mac,** with an ElevenLabs voice chosen and a key saved: every line Varnick speaks, the voice's id and the key. An answer names pages, sites, descriptions, session titles and folders, and can repeat words of the request. Never audio from the Mac, rows, or the request except as the answer repeats it. The installed voices send no line, and are what speaks with no ElevenLabs voice chosen or no key. `docs/privacy-and-security.md` says so.
- **Varnick must still never hear itself.** ElevenLabs audio plays only through `SpeechPlayback` inside `Speaker.speak`, and the span opens before the request and closes after the last sound, the fallback's included. (Amends ADR 0015's "rendered by the system synthesizer".)
- **The mic is deaf a little longer:** up to 1.5 s more than before when ElevenLabs is slow, since the span covers the wait.
- **A line is spoken once in each voice at most.** A stream that breaks after sound began stops what played and repeats the whole line in the installed voice. A stopped line goes to no fallback.
- **It needs the network and the plan's quota.** Each line uses characters from the plan; when they run out every line falls back and the Voice row says why. Nothing rests ElevenLabs after failures: each line tries it again.
- **The key needs the Text to Speech and Voices Read permissions.** A key without one is told apart from a wrong key in the Voice row.
