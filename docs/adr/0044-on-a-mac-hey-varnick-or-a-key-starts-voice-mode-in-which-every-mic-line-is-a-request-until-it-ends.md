# On a Mac, "Hey Varnick" or a key starts voice mode, in which every line the microphone hears is a request to the voice session, until the key, the menu, Claude, a call or a minute after Varnick last spoke

Builds on [ADR 0042](0042-a-spoken-request-is-answered-by-the-hosts-voice-session-one-hidden-claude-session-in-home-with-permissions-skipped.md) (the voice session), [ADR 0015](0015-spoken-requests-are-answered-locally-aloud-only-through-listening.md) (the wake phrase and Listening) and [ADR 0043](0043-voice-mode-on-the-phone-page-talks-to-a-macs-voice-session-through-its-relay-and-is-kept-alive-by-a-quiet-tone.md) (the phone's Voice mode). Option 10 of `listening-never-answers` is the spec, and the user's answers of 2026-10-17 are recorded in it.

Listening stays what it is: the always-on transcription, turned on and off by itself. **Voice mode** is a state on top of it, on a Mac, for the voice session. "Hey Varnick" or a new global key (⌃⌥V) turns it on; while it is on, every final mic line is a request to the voice session with no wake phrase, so the user can follow up without saying it again. It ends on the key (which also starts it), the menu bar's End Voice mode, a minute after Varnick last finished speaking with nothing new from the user (not counted while Varnick works or speaks), another app taking the microphone (a call), Claude calling an `end_voice_mode` tool, the session needing the user's OK or failing, or Listening, Hey Varnick or the voice session being switched off. It is in memory and off at each launch.

- **It is the wait after the wake phrase alone, a minute long and entered again after each answer.** The phase that drops every mic result while a request is out and spoken is what keeps the minute from running then; nothing new is built for the clock.
- **The key with Listening off starts Listening and, when voice mode ends, stops it again,** only when the key started it.
- **A spoken end is Claude's decision, not a phrase.** `end_voice_mode` is a second tool in the voice session's own set, beside `search`, relayed to the app and refused from any other pane. The hint tells Claude that voice mode is on and that the line may not have been meant for it. No word list decides anything, which keeps this within [ADR 0037](0037-every-decision-in-a-spoken-request-is-asked-of-jev-then-of-the-text-generation-model-never-of-word-lists.md). A fixed phrase was offered and not chosen.
- **A call ends it.** Core Audio's list of processes and whether each runs input, with Varnick's own left out, is read when voice mode starts and every second while it is on. While a call holds the microphone the key and the menu item refuse, and Hey Varnick answers its one request as before without entering voice mode.
- **The guards against overheard audio** are the minute, the icon, the sounds, the transcript's "Voice mode on." and "Voice mode off." lines, the call watch and Claude's tool. No cap on its length and no check of whose voice it is: neither was chosen, and neither is built.
- **The menu bar shows it.** The Fold stays the logo, with three looks: today's mark when off, the halves lined up with a bar under the V when Listening, and the same in red in voice mode, pulsing while Varnick works or speaks. Entering plays Tink and leaving a second system sound.
- **Only the voice session.** With Varnick's own steps chosen, Hey Varnick keeps one request per wake: that pipeline carries nothing between requests, and its route call would send every overheard line to Jev. The phone's Voice mode keeps its own Start and End and shares the session; the end tool ends the Mac's voice mode only. No protocol change.

## Amends

- [ADR 0015](0015-spoken-requests-are-answered-locally-aloud-only-through-listening.md): while voice mode is on, a request needs no wake phrase.
- [ADR 0042](0042-a-spoken-request-is-answered-by-the-hosts-voice-session-one-hidden-claude-session-in-home-with-permissions-skipped.md): a surface may hold a conversation, and the session's own set gains `end_voice_mode`.
- [ADR 0043](0043-voice-mode-on-the-phone-page-talks-to-a-macs-voice-session-through-its-relay-and-is-kept-alive-by-a-quiet-tone.md): Voice mode names the Mac's state as well; the phone's rules are unchanged.

## Considered Options

- **A fixed spoken phrase to end it,** matched locally like the wake phrase. Instant, and it would work when Claude can't answer, but it is a word list and needed an exemption from ADR 0037. Not chosen.
- **Weight as the icon's difference (outline, solid, a cut-out tile),** all template images. The user chose colour instead.
- **No line is sent while the Mac's own audio is speech,** a rule over audio times that would also drop the user's own lines then. Offered if the hand test shows videos on the Mac being sent; not built.
- **Speaker verification,** accepting only the user's voice: the speaker model is measured on the Mac's audio, not the microphone.

## Consequences

- **For a minute at a time, everything the microphone hears goes to a Claude session that runs commands without asking.** A TV, a radio, a video, a call across the desk or someone else in the room becomes a request, and something that keeps talking keeps voice mode on. The Settings text and `docs/privacy-and-security.md` say so and change together.
- **The red icon is not a template image:** it doesn't invert in an open menu and needs checking on light, dark and tinted menu bars, beside the orange notice dot and macOS's own microphone indicator.
- **Claude ending it costs a model turn,** and the reply is spoken first.
- **A quick reply can be lost:** a line whose audio begins within 0.5 s of Varnick's last sound is dropped whole as echo. The hand test notes it.
- **The call watch is unmeasured:** which apps hold the microphone without a call, and whether every call app holds it for the whole call, are not known. A false reading refuses or ends voice mode, the safe side; a missed one sends a call to Claude. It can't tell a TV, a call on another device or someone else in the room.
- **A voice session started before this build lacks the end tool** until a new one starts.
- **Amended 2026-10-17 ([ADR 0042](0042-a-spoken-request-is-answered-by-the-hosts-voice-session-one-hidden-claude-session-in-home-with-permissions-skipped.md), see its amendment of that date):** the voice session says nothing when it takes a request, so in voice mode the first sound after a request is its answer or a closing line, and the minute counts from it.
