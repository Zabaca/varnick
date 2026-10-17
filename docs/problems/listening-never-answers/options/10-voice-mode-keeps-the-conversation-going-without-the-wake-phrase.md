---
problem: listening-never-answers
title: Voice mode on a Mac, started by Hey Varnick or a key, sends every line the mic hears to the voice session until a minute after Varnick last spoke
summary: Listening stays the always-on transcription it is. Voice mode is a state on top of it. "Hey Varnick" or a new global key (⌃⌥V to start with) turns it on. While it is on, every finished mic line is a request to the voice session with no wake phrase needed, and a leading "Hey Varnick" is dropped. It ends on the same key, on End Voice mode in the menu bar's menu, 60 s after Varnick last finished speaking with no new line from the user, when another app takes the microphone (a call), or when Claude calls an end tool because the user is done. The minute doesn't run while Varnick works or speaks. A sound marks entering and leaving, and the transcript gets "Voice mode on." and "Voice mode off." lines. The menu bar's Fold gets three states that read at a glance: off, listening and voice mode. This is for the voice session on a Mac only. Today's pipeline, now experimental, keeps one request per wake, and the phone's Voice mode keeps its Start and End. No protocol change.
status: proposed
---

## Solution

**Listening is unchanged.** It transcribes the mic and the Mac's audio into the day's transcript, and the menu, `!listen` or ⌃⌥L turn it on and off as today.

**Voice mode** is a state of Hey Varnick on this Mac. It is off at each launch and kept in memory. It needs Hey Varnick on and the voice session answering, which is the default once today's pipeline moves to Settings › Experimental.

- **Starting it.**
  - A Hey Varnick request ("Hey Varnick, what was I doing yesterday") is answered as today, and voice mode is on from then. The wake phrase alone turns it on too, in place of "Ask me something.".
  - A new global key, **Start / end Voice mode (anywhere)**, ⌃⌥V by default, beside Listening's ⌃⌥L. With Listening off, it starts Listening first, and voice mode begins once Listening runs (question (d)).
  - Entering plays Tink, today's wake sound.
- **While it is on**, every final mic result is a request, collected as today's are: the 1.5 s gap, the 0.5 s hold, 20 s and 500 characters at most.
  - A leading wake phrase is dropped: the text after it goes, or the whole line when it has none. A line that is empty after that counts as the user's line and goes nowhere.
  - Each request goes to the voice session as a Hey Varnick request does, with one more sentence in the voice hint (below).
  - No sound marks a line: "Let me check." already says it was taken.
- **The minute.** Voice mode waits for the next line until 60 s after Varnick's last line finished playing, or 60 s after it was entered when nothing has been said yet.
  - It doesn't count while a request is out or a line is being spoken.
  - Speech heard just before the deadline holds it open until that speech's final result arrives, as today's wait after the wake phrase alone does.
- **Ending it.** Any of these ends it:
  - the key again, or End Voice mode in the menu bar's menu (under Start Listening);
  - the minute running out;
  - another app taking the microphone (a call, below);
  - Claude calling `end_voice_mode` (question (a));
  - "Claude needs your OK in Varnick.", or a refusal or failure line, once said (question (e)): the next line would start a new session or fail the same way;
  - Listening stopping, Hey Varnick turned off, or the pipeline chosen.

  Ending stops Varnick's voice if it is speaking and ends the spoken request; the session's turn goes on, as 09's cancel has it. A leaving sound plays, a second short system sound distinct from Tink. "Voice mode off." goes to the transcript, as entering writes "Voice mode on.", so the file shows which `[mic]` lines went to Claude.

**What the user sees.** Today the icon barely changes when Listening starts: the Fold's right half moves up by 1.5 pt (Further Notes). This option gives the icon three states, all small variants of the Fold (question (c)):

| State | A: weight (recommended) | B: colour |
|---|---|---|
| Off | the Fold at rest, halves apart, as an outline | today's: solid, halves apart |
| Listening | solid, halves lined up (today's listening cut) | solid, lined up, with a short bar under the V |
| Voice mode, waiting for the user | a solid rounded tile with the lined-up Fold cut out of it | the lined-up Fold and bar in red |
| Voice mode, Varnick working or speaking | the cut-out right half steps between apart and lined up, about twice a second | the red pulses |

- **A** is template images throughout, so the menu bar colours them for light, dark and highlighted, and colour stays the notice dot's alone. **B** keeps today's off look exactly, but its red image isn't a template: it doesn't invert when the menu opens, needs checking on light, dark and tinted menu bars, and sits beside the orange notice dot and macOS's own orange microphone indicator.
- The steady voice-mode state means "your turn, the minute is counting". The moving one means "Varnick has it, nothing is counting".
- The notice dot keeps its place and colours. In A, the tile is notched around the dot while a notice stands, so the dot stays a mark of its own.
- The icon's accessibility description and tooltip name the state ("Varnick, listening", "Varnick, in voice mode").
- The menu gets Start Voice mode or End Voice mode with the key's label. When voice mode can't start, the item is disabled and says why.

Nothing is drawn on the screen: the icon, the sounds and the voice say it.

**The voice hint** gains one sentence for a request made in voice mode, a starting point kept in the hint's one place: "Voice mode is on: this was heard without a wake phrase and may not be meant for you. When the user is done, or it wasn't meant for you, call end_voice_mode."

**The end tool.** `end_voice_mode` is a second tool in the voice session's own set, beside `search`.
- It ends the Mac's voice mode once the turn's answer has been spoken.
- After it, an answer that cleans to nothing is silent, not "I couldn't answer that.": the leaving sound is enough.
- It doesn't touch the phone's Voice mode.

**A call ends it.** While voice mode is on, Varnick watches whether any other process holds the microphone, through Core Audio's list of processes and whether each is running input, leaving out Varnick's own.
- When one does (a call in a call app or a browser tab, or anything else recording), voice mode ends at once and its voice stops, so no answer is spoken into the call.
- While one does, the key gives the refusal sound, and Hey Varnick answers its one request as today without entering voice mode.
- It can't tell a TV, a call on another device, or someone else in the room.

## Trade-offs

- **For a minute at a time, everything the mic hears goes to a Claude session that runs commands without asking.** Without the wake phrase, these all become requests: a TV, a radio, a video through the speakers, a call on the other side of the desk, someone else in the room. Something that keeps talking, like the TV, keeps voice mode on indefinitely, since each line starts the minute over.
  - The guards are the icon, the sounds, the transcript's lines, the call watch, and Claude ending it (prompted by the hint) when lines aren't meant for it.
  - The strong guard would be speaker verification, accepting only the user's voice. It isn't built: transcript-cant-tell-callers-apart's speaker model is measured on the Mac's audio, not the mic. Question (b).
- **Claude ending it costs a model turn.** "Thanks, that's all" goes to the session and its reply is spoken first. But it is Claude deciding, as it decides everything else in the voice session, with no word list (ADR 0037).
  - A fixed phrase would end it at once, and would work when Claude can't answer. But it is the kind of list ADR 0037 rules out, and it would need the exemption the wake phrase has.
- **A quick reply can be lost.** A line whose audio begins within 0.5 s of Varnick's last sound is dropped whole as echo (the tail). In a conversation the user answers sooner than after a wake phrase. The hand test checks it, and the tail stays.
- **Lines said while Varnick works are transcribed and not sent,** as today: the session holds one request at a time.
- **The call watch is unmeasured.** Nobody has checked which apps hold the mic without a call (dictation, a browser tab with the mic allowed, an app that keeps its input open) or whether every call app holds it for the whole call. A false call refuses voice mode, which is the safe side.
- **The minute is the user's figure.** The mode's other numbers are today's (the hold, the gap).

## User Stories

1. As a Varnick user, I want "Hey Varnick" to start a conversation, so I can follow up without saying it again.
2. As a Varnick user, I want a key that starts and ends voice mode from anywhere.
3. As a Varnick user, I want voice mode to end by itself a minute after Varnick last spoke if I've said nothing, and never while it is still working on my request.
4. As a Varnick user, I want to hear when voice mode starts and ends, and to see at a glance in the menu bar whether Varnick is off, listening or in voice mode.
5. As a Varnick user, I want to say I'm done and have voice mode end.
6. As a Varnick user, I want voice mode to end when a call starts, so the call is never sent to Claude or answered aloud.
7. As a Varnick user, I want Listening's transcription to stay as it is, turned on and off by itself.
8. As a Varnick user, I want Varnick never to take its own voice for my next request.

## Implementation Decisions

**Sibling: today's wait after the wake phrase alone.** This is the `.waiting(until:)` phase of `SpokenRequests`, with `wakeWait` and the volatile grace. Voice mode is that wait, 60 s long and entered again after every answer. In it, a final phrase needs no wake phrase, and the wait running out ends voice mode instead of saying "Ask me something.". So:
- `SpokenRequests` keeps whether voice mode is on (published, for the menu bar) and when the minute began.
- When `answerByVoiceSession` returns, after `voice.finished()`, it enters the wait again if voice mode is on.
- The `.answering` phase, which drops every mic result, is unchanged. That is what keeps the minute from running while Varnick works or speaks.
- In the wait, a final phrase goes to `collect` with the rest that `SpokenText.request(in:)` gives, or with the whole text when it holds no wake phrase.
- **One pure function** decides two things.
  - Which ending ends voice mode: an answer, no answer, the deadline and busy keep it on; needs you, a refusal and a failure end it; the end tool ends it after the answer.
  - When the minute runs out, given when the last line ended and the volatile speech heard.

  It sits in the shared package beside `VoiceWatch`, so `check-voice` covers it, though only the Mac uses it.

**The key.** A fourth global action beside Show / hide, Pin and Listening (`isGlobal`). It is registered as a `HotKey` with an id of its own, listed in Settings › Shortcuts, and shown in the menu item's title.
- Its default must not take a key a user already gave another action. `Settings.combo` has that guard for the swap defaults alone today, and it covers this action too (where-it-breaks, Focus and keys).
- Pressed while voice mode is off, it starts it, starting Listening first if it is off.
- Pressed while voice mode is on, it ends it, whatever Varnick is doing.
- When voice mode can't start (Listening unavailable, Hey Varnick off, the pipeline chosen, a call), it beeps as ⌃⌥L does below macOS 26, and the menu item says why.

**The menu bar.** `showListening` becomes one place that draws the icon from Listening's state, voice mode's state and whether Varnick is busy. The notice dot keeps its own update.
- The variants are new `FoldMark` drawings, or a stroke and a tile around today's two cuts. The master and the site's mark are untouched.
- The animation is an image swap on a timer while Varnick is busy, stopped otherwise.
- `NoticeDot`'s comment still names the old search and waveform images, and is corrected with the change.

**The call watch.** Core Audio's process list, and each process's "running input" property.
- It is read when voice mode starts and on a timer while it is on (1 s, a named constant), or through property listeners if they fire for it.
- Varnick's own process is left out, using the lookup Listening already does for its tap.
- The reading runs off the main actor. The log says only that a call ended voice mode, never which app.

**The voice hint.** `VoiceHint.text` takes whether voice mode is on. The phone's hint is unchanged.

**The end tool.** It copies the search tool's two halves (`VoiceSearchMCP`, `VoiceSearchAccess`) and is listed in the same set. The app half checks that the calling pane is the voice session, then tells `SpokenRequests` to end voice mode after this request's answer. A voice session started before this build lacks the tool until a new one starts.

**What is logged.**
- The timing line adds whether the request was made in voice mode.
- When voice mode ends, one line says how (key, menu, minute, call, Claude, needs you, failure) and how many requests it carried.
- Never a line's words.

**State.**
- Voice mode is in memory, off at each launch.
- UserDefaults: nothing new. The key's binding is saved in the shortcut overrides only if the user changes it.
- `sessions.json`: unchanged.
- The transcript gains two `[varnick]` lines, "Voice mode on." and "Voice mode off.". Nothing reads a `[varnick]` line back.

**Settings and the privacy doc.** Hey Varnick's detail and the voice session's privacy section both say this: after Hey Varnick or the key, every line the mic hears goes to the session until a minute after Varnick last spoke, a TV or another voice included, and here is what ends it. The two change together.

**Today's pipeline** (now behind Settings › Experimental): voice mode doesn't apply. Hey Varnick there keeps one request per wake, and the key and the menu item say voice mode needs the voice session. The reasons:
- the pipeline carries nothing from one request to the next, so a follow-up has no context;
- its route call runs while each line is said, so every line it overheard would go to Jev;
- nothing could end it but the key and the minute.

**The phone's Voice mode.**
- Unchanged, it shares the session, its 10 minutes and its one-request rule. A Mac line while the phone's request is out gets "I'm still on your last request.", and voice mode stays on.
- It keeps its own ends: Start, End and the page's own ends, with no minute, since it is held on a screen the user is looking at.
- The end tool ends the Mac's voice mode only.
- No protocol change.

**The voice session's 10 minutes** are unchanged and separate: the minute belongs to the surface, the 10 minutes to the host. Ending voice mode ends no session, and a Hey Varnick within the 10 minutes reuses it.

## Testing Decisions

- **No test target.** `make check-voice` gains cases:
  - the ending rule's table;
  - the minute's end, from the last line's end, with volatile speech at the deadline;
  - the wake phrase dropped, or absent;
  - the hint with and without voice mode.
- **`make check-mcp`:** the end tool is listed in the voice session's set only, and refused from any other pane.
- **`make build`.**
- **By hand, after the user restarts Varnick,** with Hey Varnick on and the voice session answering. The user speaks and presses the keys; agents don't drive the screen. Start with a fresh voice session, since the end tool is listed when a session starts.
  1. ⌃⌥V with Listening off: Listening starts, Tink plays, and the icon shows voice mode. A question with no wake phrase is answered.
  2. A follow-up with no wake phrase within the minute is answered in context, and the timing line says the session was reused.
  3. Silence: about 60 s after the answer finished, the leaving sound plays, Listening stops again (it was off before), the icon goes back to off, and the transcript has "Voice mode off.".
  4. A request that takes Claude 30 s or more: voice mode ends about 60 s after the answer ends, not after the request was said, and the icon moves while Varnick works.
  5. "Hey Varnick, …" with Listening on enters voice mode. A follow-up that starts "Hey Varnick" reaches the session without the phrase; opening the session at the end shows it.
  6. ⌃⌥V while Varnick is speaking: the voice stops and the leaving sound plays.
  7. "Thanks, that's all": Claude ends voice mode after its reply (if (a) is the tool).
  8. A call in a call app, or a browser tab using the mic, with voice mode on: voice mode ends at once. During the call, ⌃⌥V beeps, and Hey Varnick answers one request without entering voice mode.
  9. Speakers loud, no headphones: Varnick's replies never come back as requests, and the transcript has no `[mic]` line in Varnick's words.
  10. A reply begun right as Varnick stops: note whether it is dropped (the tail).
  11. The icon's states are readable with a notice dot standing, in light and dark menu bars.
  12. Restart Varnick: voice mode is off at launch.
  13. With the pipeline chosen: ⌃⌥V beeps, the menu item says why, and Hey Varnick answers one request as before.

## Out of Scope

- Speaker verification of mic lines, so that only the user's voice becomes a request.
- Talking over Varnick to stop it, and queuing lines said while Varnick works.
- A minute, or an end tool, for the phone's Voice mode.
- Voice mode with today's pipeline.
- An overlay on the screen.
- A cap on how long voice mode lasts (question (b)).

## Further Notes

- **Asked by the user, 2026-10-17** (relayed by the coordinator): "differentiate listening and voice mode. Listening turns on the overall listening. Voice mode is triggered by Hey Varnick, and the key binding. It stays on until I manually turn it off or a 1 minute timeout of inactivity. Inactivity should be counted from Varnick responding. So if I keep the conversation going, it doesn't end and I don't have to continuously say hey Varnick." Added the same day: an indicator while voice mode is on, and Listening made clearly visible, since the Fold doesn't show it well today.
- **Builds on** option 09 (shipped) and on the user's decision of 2026-10-17, being built now, that the voice session is the default way Hey Varnick answers and today's pipeline moves behind Settings › Experimental.
- **Verified in the code at main `fd0fc29`**, into which the voice session was merged:
  - **The menu bar** shows the Fold as a 16 pt template image.
    - Off draws the halves apart, the right half 6 of 64 units lower (1.5 pt at 16 pt); Listening draws them level. Same weight, no colour: those 1.5 pt are the only difference.
    - The notice dot is a 7 pt overlay at the top right, orange for Needs you or an error, else blue.
    - The accessibility description is "Varnick" in every state.
    - The menu holds Start or Stop Listening with its key, and Show Transcript.
  - **Keys:** there are three global actions: Show / hide (⌃Space), Pin (⌃⇧Space) and Listening (⌃⌥L). None is for Hey Varnick or a mode, and no default uses ⌃⌥V. The guard on new defaults covers the swap actions only.
  - **Hey Varnick** takes only final mic results, and the Mac's audio never reaches it.
    - `.answering` drops every mic result until the last line has played.
    - The wake phrase alone waits 8 s, kept open by volatile speech, then says "Ask me something." on the voice session.
  - **Echo.** Each spoken line opens a span from before its first sound until 0.5 s after its last (the tail), and a mic result whose audio began inside one is dropped, judged by the audio's own time. No span is open between lines.
    - The tap leaves Varnick's own process out, so the wake sound and the voice are never `[system]` lines.
    - A system sound Varnick plays (Tink) comes from its own process.
  - **The pipeline:** `SpokenPipeline.prepare` takes the request alone, so nothing carries over between requests, and it runs while the request is being said.
  - **The phone's Voice mode** ends on End, Back, the Media Session's pause or stop, a microphone gone silent, and Open. It has no idle timer.
  - **The voice session's own MCP set** holds `search`, listed for that session only, and the app refuses a call from any other pane.
  - **Nothing in Varnick detects a call.** The macOS SDK's Core Audio header has the process list and each process's running-input property; this was read in the header, not run.
- **Inferred, not measured:**
  - that macOS shows its own orange microphone indicator whenever Listening runs (not checked on macOS 26);
  - that call apps hold the mic input for the length of a call, and which other apps hold it;
  - that Core Audio's listeners fire for those properties;
  - how readable each variant is at 16 pt (a Scratch prototype can show both before building);
  - the effort.
- **ADR, on acceptance:** one new ADR. On a Mac, Hey Varnick or a key starts voice mode, in which every mic line is a request to the voice session, until the key, the menu, Claude's end tool, a call, or a minute after Varnick last spoke. It amends:
  - ADR 0015: while voice mode is on, a request needs no wake phrase;
  - ADR 0042: a surface may hold a conversation, and the session's own set gains the end tool;
  - ADR 0043: Voice mode names the Mac's state as well; the phone's rules are unchanged.

  It stays within ADR 0037, since no word list decides anything; if the user picks a fixed phrase in (a), ADR 0037 is amended to exempt it as the wake phrase is.
- **Glossary, proposed:**
  - **Voice mode** widens to: a conversation by voice with a host's **Voice session**, without a wake phrase for each request. On a Mac, Hey Varnick or its key starts it, every line the mic hears is a request, and it ends by the key, a call, Claude, or a minute after Varnick last spoke. On a Mac host's Phone page, a button starts it and End ends it.
  - **Wake phrase** adds: it also starts Voice mode.
- **`where-it-breaks.md` items this touches:**
  - Listening and spoken requests: echo and the tail (`SpeechSpans`), which voice mode leans on harder; `.answering` dropping mic results; every line through `Speaker.queue`; a cancel ends the request, not the turn; no line's words logged.
  - The voice session: anything the mic hears can run commands, now with no wake phrase; the Settings text and the privacy doc change together; the session's set lists the end tool for it alone.
  - Focus and keys: a new default shortcut must not take a user's key.
  - Screen access and Panel access: `--mcp` never acts; the end tool is relayed like the search tool.
- **Defaults, not asked of the user,** which they can overrule:
  - no switch of its own: with the voice session answering, Hey Varnick starts voice mode;
  - ⌃⌥V;
  - Tink to enter and another short system sound to leave, with no sound per line;
  - the two transcript lines;
  - the 0.5 s tail is kept;
  - the call watch's 1 s.
- **Effort, rough:** 450 to 600 lines with the docs, in two slices.
  1. The menu bar's states for off and listening, then voice mode's. This stands alone and fixes the Listening complaint first.
  2. Voice mode: the wait, the key, the menu item, the sounds and transcript lines, the call watch, the hint, the end tool, `check-voice` cases, and the docs.

  No protocol bump, no eval.
- **Open questions,** each recommendation first:
  - **(a) A spoken end?** Recommended: Claude ends it through `end_voice_mode`, prompted by the hint. Other choices: a fixed phrase matched locally like the wake phrase (instant, but a word list, which needs an ADR 0037 exemption), or no spoken end at all (key, menu, the minute and a call only).
  - **(b) Which guards against overheard audio?** Recommended: the minute, the icon and sounds, the call watch, and Claude's end tool. Not recommended: a cap on voice mode's length, which goes against "stays on until I turn it off". Offered if the hand test shows videos on the Mac being sent: no line is sent while the Mac's own audio is speech (a rule over audio times, not words), which also drops the user's own lines then.
  - **(c) Menu bar: A (weight) or B (colour)?** Recommended: A. A Scratch prototype of both is quick if the user wants to see them first.
  - **(d) The key with Listening off?** Recommended: it starts Listening, and voice mode's end stops it again, only when voice mode was what started it. Other choices: it beeps and does nothing, or it starts Listening and leaves it on.
  - **(e) Does needs-your-OK, or a failure, end voice mode?** Recommended: yes, after its line. The user has to go to the screen, or the next line would fail the same way. Busy and the deadline keep it on.
