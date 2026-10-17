---
problem: phone-page-is-only-a-browser-tab
title: Voice mode on a host's Phone page talks back and forth with that host's voice session
summary: A Voice mode button on a Mac host's Phone page starts that Mac's voice session, or reuses it within its 10 minutes. This is the same session Hey Varnick reaches (listening-never-answers option 09), in the Mac's Home. The user talks back and forth by voice, with each exchange shown as text too. The phone sends its microphone's audio in chunks, and the Mac turns it into text with Listening's transcriber and makes the reply's audio in its Voice setting's voice, which the phone plays; three new relay requests (protocol 30) send audio, send text and poll for what happened. A headless host has no Voice mode at first. Voice mode works in the foreground and, by a quiet tone the page plays for as long as it runs, in the background (a spike on a Pixel found a hidden silent page frozen at 60 s and a tone-playing one alive for 132 s); a locked screen is not supported and a native Android shell for it is deferred. The mic is one getUserMedia stream with a wake lock; a page that is frozen anyway reconnects on resume and says so. A prompt that needs the user's OK is answered in the page's own terminal view.
status: shipped
---

## Solution

This builds on listening-never-answers option 09: a host's **voice session** has a text-in, events-out seam in the shared package. This option is the phone's surface for it.

1. **Pick a machine.** The user opens that host's Phone page, as today, from the links to the other hosts' pages. Home gets a **Voice mode** button.
2. **Voice mode** fills the screen with a view of its own:
   - the exchange so far as text, the user's requests and Varnick's answers;
   - a state line: listening, sent, "Working…", "Searching the web…", or needs your OK (the first two as state text only: ADR 0042's amendment of 2026-10-17);
   - a button to end the mode.

   It asks for the mic once, holds a screen wake lock and sets Media Session controls. It stays in the mode until ended, the page is hidden for too long, or the phone is locked.
3. **A request** is one utterance. The phone decides where it ends, by the silence after speech, a named constant.
   - It becomes text (where is question 1) and goes to the host with the phone's moment, time zone and units.
   - The host's voice session takes it as 09 says. A Mac's is the session Hey Varnick reaches there, so a question asked aloud at the desk can be followed up from the phone.
4. **The reply** comes back as the answer's full text and its spoken form, from 09's cleanup. The phone shows the text and plays the spoken form (where its audio is made is question 1). While a reply plays, the mic's audio is not sent, so Varnick doesn't hear itself.
5. **Needs your OK.**
   - The page says "Claude needs your OK" and shows an Open button, which opens the voice session's terminal in the page with take, as any session can be opened there today.
   - The user answers the prompt there. The session is then theirs, as 09 has it, and the next request starts a new one.
   - Needs you also pushes to the phone through option 02's routing, as any session's does.

## Trade-offs

- **The phone is a second surface, not a second assistant.** One session per host, one 10-minute rule and one permission mode, whether the user speaks at the Mac or on the phone.
- **Foreground only, by the browser's rules.** The research (Chrome on Android, read in Chromium's source on 2026-10-16) found:
  - In the foreground, getUserMedia, WebRTC and SpeechRecognition all work.
  - Hidden or locked, a getUserMedia or WebRTC mic track goes silent after about 60 to 120 s while still reading live, so the page can't tell. Android blocks background capture without a microphone foreground service, and Chrome's flag for it is off on phones.
  - SpeechRecognition ends the moment the page is hidden.
  - Audio that is already playing keeps playing hidden, and keeps the page from being frozen. A page that is hidden and silent freezes after about a minute, which stops its WebSocket.
  - The wake lock is released when the page is hidden, and Doze can cut the network with the screen off.
  - iOS stops when the page is backgrounded (unverified).

  So Voice mode is for a phone that is on and showing the page. A glance at another app may survive about a minute. Locking the phone ends the mode.
- **What a headless host can do depends on question 1.** If the host has to turn speech into text or make the reply's audio, a headless host needs something for it that it doesn't have today. Its voice session also has no search over History and Bookmarks, which live on the Macs (09).
- **More leaves the phone.** If the phone's own recognition does the speech to text, Chrome on Android sends the audio to Google (inferred). If the host does it, the audio goes to the host over the tailnet and nowhere else. The user has said privacy isn't a concern, but the privacy doc says which.

## User Stories

1. As a Varnick user away from my desk, I want to open a machine's Phone page, tap Voice mode, and talk to that machine's Claude session by voice.
2. As a Varnick user, I want to follow up by voice on the phone what I asked aloud at the Mac, within the 10 minutes.
3. As a Varnick user, I want to see the exchange as text while I hear it.
4. As a Varnick user, I want to approve what Claude asks for from the phone, in the session's terminal.
5. As a Varnick user, I want the page to tell me when Voice mode has stopped because the page was hidden or the phone locked, not keep pretending to listen.

## Implementation Decisions

**The host's side (protocol 30, from a device or a listed Mac).**
- `voiceAsk` carries the request's text, the asker's moment, time zone and units, and the device. It answers at once: taken, busy (a request is in flight), or refused (the switch is off on a Mac, or Claude Code can't start). With taken comes an id.
- `voiceStatus` with that id answers the events so far: taken, looking up, needs the user (with the voice session's tab, to open), answered (the full text and the spoken form), or failed (a kind). The phone polls it every second, as `task_run_status` is polled, because a relay request is one short process.
- **On a Mac,** the relay hands both to the app, which answers from 09's voice session. A Mac whose Voice session switch is off refuses.
- **On a headless host,** the relay answers itself, with 09's shared decision. Its state lives in the state folder under the state lock, as automations' does:
  - it starts the session in the host's Home's Voice folder, as the host starts any session, under the host's own Skip permissions;
  - it sends with `zmx send`;
  - it reads the turn and the Stop input from the pane folder;
  - it ends an idle session at the next ask, or at the minute tick where the timer is installed.
- **The hidden tab:** a host lists its voice session's tab to the phone only through `voiceStatus`'s needs-the-user event, never in Home's tab list. Other Macs never list it.

**The page.**
- **The mic is one getUserMedia stream for the whole mode,** never opened per utterance, with a screen wake lock and Media Session controls, as the research advises.
- **The page watches visibility and freeze events.** When the page has been hidden longer than the measured grace (the spike, below), or is frozen, it ends the mode and says why when it is shown again. A track that still reads live is not trusted.
- **Speech to text and the reply's audio:** question 1.
- **The exchange is shown, never saved** on the phone. The page's service worker and cache never hold it.

**Logs.** The page server logs the request kinds and durations, never the text, the audio or the answer, as it logs nothing that was typed today.

## Testing Decisions

- **A spike first, on the user's Android phone (a Pixel),** with a throwaway page served the way the Phone page is. It is the coordinator's design, from the research.
  - Log the mic's level every second, and every freeze, resume and visibility change.
  - Do it at 30 s, 90 s, 5 min and 15 min, both with the page hidden and with the phone locked.
  - Do it with audio playing and without.

  The figures are in Results below.
- **The protocol's pure parts** (`voiceAsk` and `voiceStatus`, read and answered) get the shared package's checks and the page's Bun tests, as protocol 28's and 29's did.
- **By hand, after option 09 has shipped and the host runs this build:**
  - Voice mode on a Mac's page: ask, follow up, and follow up at the Mac by Hey Varnick.
  - The same on a headless host's page.
  - A request needing the user's OK: open it from the page and approve.
  - Hide the page for over the grace: the mode ends and says so.
  - Lock the phone: the mode ends.

## Out of Scope

- **A locked screen or a long background.** Keeping the mic there needs a native Android shell with a microphone foreground service; a Trusted Web Activity is likely no better (research). Deferred.
- iOS beyond what the page does in the foreground.
- A wake word on the phone. Voice mode is started by a tap.
- Listing the voice session among the phone's tabs.

## Further Notes

- **The user's request of 2026-10-16,** relayed by the coordinator: "on the Phone page you pick a machine, tap Voice mode, and it starts (or resumes, within the 10 minutes) the same kind of conversation in that machine's Home folder, and you talk back and forth through voice." This goes beyond this problem's two halves (install, push). It builds on both, and lives here at the coordinator's choice.
- **Depends on** listening-never-answers option 09's seam (the voice decision, the hint, `zmx send`, the Stop-input reader, all in the shared package). Build it after 09.
- **Siblings:**
  - polling a long job: `task_run` and `task_run_status`;
  - a headless host's state under the state lock: automations on the headless host (protocol 29);
  - opening a session on the phone with take: the page's terminal;
  - Needs you to the phone: option 02's routing.
- **ADR, on acceptance:** amends ADR 0011 (the page reaches a host's voice session through its relay, and holds the mic in the foreground) and ADR 0009 (a headless host keeps a voice session).
- **Open questions for the user (decided 2026-10-16: see Results):**
  1. **Where does speech become text, and where is the reply's audio made?** Left open, as the coordinator asked. The shapes:
     - **On the host.** The page sends the stream's audio over its WebSocket. A Mac turns it into text with Listening's transcriber as a third source and voices the reply with its Speaker (the user's Voice setting, ElevenLabs included). The page plays that audio, which also keeps a hidden page awake while it plays. A headless host has neither a transcriber nor a voice today.
     - **On the phone.** Chrome's SpeechRecognition makes the text and the phone's own speech synthesis speaks the reply, so the host sees only text and a headless host needs nothing new. But SpeechRecognition ends the moment the page is hidden. And whether it can take the mode's getUserMedia track, rather than opening its own capture, is unverified.
     - **Mixed.** For example, text made on the phone and audio made by a Mac.

     The spike's figures and the user's choice of voice decide it.
  2. **Voice mode on a headless host from the start, or on Macs first?** It depends on question 1. With the phone doing speech, both from the start. With the host doing it, Macs first.
- **Verified in the code at main `2c84e28`:**
  - the page server asks everything of its host's relay as a child process;
  - a Mac's relay hands requests to the app;
  - the page opens a session's terminal with take;
  - the protocol is at 29.

  The browser facts are the research's, as relayed: Chromium's source, not run on a phone.
- **Inferred:** that Chrome on Android sends SpeechRecognition audio to Google; every latency; and the polling interval.

## Results

- **Decided by the user, 2026-10-16.** Speech becomes text, and replies become voice, on the Mac host, with Listening's transcriber and the Speaker (ElevenLabs or the installed voice). No Voice mode on a headless host at first (the protocol's requests exist on it and refuse). Foreground only, by the browser's rules; the tone below is the one measured addition. Protocol 30. ADR 0043.
- **The spike (a Pixel, Chrome 155, in a tab and not the installed app, 2026-10-16, with a throwaway page that logged the mic's level, visibility and freeze events and a websocket ping to the host; the page is removed).**
  - *No tone, home screen:* the page was hidden at 13.3 s, Chrome froze it at 73.4 s (60 s later), the host's websocket closed with 1006 about 5 s after that, and on return the page resumed, reconnected within a second and the mic was live again.
  - *A 220 Hz tone at 0.02 (Web Audio), hidden for 132 s:* no freeze, a level every second, the mic heard the user throughout (loud frames in every 30 s bucket, rms up to 0.24), and the websocket stayed open (35 pings).
  - *Not known:* whether that run was the home screen or a locked screen (the locked run was left to the user), and anything past about 2 minutes. A locked phone is therefore not supported.
- **Hand test,** with the Mac running the build, Voice session on, Keep sessions running and Claude Code logged in with skip-permissions accepted, then on the Pixel:
  1. Voice mode, Start: "Listening". Say "what time is it": your words appear as text, the state line says "Working…", then the answer as text and in the Mac's voice.
  2. A follow-up ("and in Tokyo?") is answered in context and the Mac's log says the session was reused; a question asked at the Mac by Hey Varnick can be followed up from the phone within 10 minutes.
  3. A world question shows "Searching the web…" as the state line, and nothing in the exchange.
  4. A request that makes Claude ask a question shows "Claude needs your OK" and Open (which ends Voice mode) opens the session with control taken.
  5. Home screen for 2 minutes with the mode on, then speak: the conversation survives. A locked screen: say how it behaves.
  6. A pause in the middle of a request, a cough, a clap: tune `silenceMs`, `minSpeechMs` and `lowestThreshold` in `voicerules.js` if requests cut off or false-start. A television or fan stepping up does not start a 30 s request.
  7. Another app taking the microphone, or the system muting it, ends the mode within about 5 s and says why.
  8. Voice session off, or Keep sessions running off: Start then the first request says why at once, before anything is sent. A headless host's page has no button.
