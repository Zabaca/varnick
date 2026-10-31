---
problem: voice-mode-forgets-the-exchange
title: Voice mode shows the Voice session's earlier exchanges, read from it on the Mac
summary: When Voice mode opens on a Mac's Phone page, the page asks the Mac for the exchanges its Voice session holds and shows them above the live ones. The Mac reads them from the session's own transcript, each request without the voice hint and the answer Claude gave, so they come back after End, a reload or on another phone, and include what was asked at the Mac by Hey Varnick. They go when the Voice session ends. One new device-only request, no protocol bump, and the page still keeps nothing.
status: shipped
---

## Solution

When the Voice mode view opens on a Mac's Phone page, before Start is tapped, the page asks the Mac for its Voice session's exchanges. It shows them above, under a quiet line ("Earlier in this Voice session"), drawn as the live lines are: the user's request, then Varnick's answer. The live exchange follows below as today.

The Mac reads them from the Voice session's own transcript, which is the conversation the next request continues. Each request is shown as it was asked, without the voice hint in front of it. Each answer is the last text Claude wrote for it. So the exchanges are there again:

- after End and reopening;
- after a reload or a frozen page;
- on another phone;
- after a restart of Varnick, which the session survives while Keep sessions running is on.

They include what was asked at the Mac by Hey Varnick, since that is the same session.

When there is no Voice session, the view opens empty. That happens when the next request would start a new session: 10 minutes after the last turn, when the voice session is switched off, once the user has opened or taken over the session (it is theirs then, ADR 0042), or when it sits on a question, a plan or an error. The page keeps nothing itself: the exchanges live in the view and go with it, as today.

## Trade-offs

- **The transcript is the record, so nothing new is saved.** No second copy of spoken requests is written on the Mac or the phone.
- **Only exchanges come back.** The view's notes (couldn't make out the audio, busy, a failure line), a request collected but never ended with "over", and refusals are not in the transcript, and are not shown again.
- **An answer reads as Claude wrote it,** as the live answer's text does.
- **Only the session the next request continues is shown** (amended at the review of 2026-10-31). A session that sits on a question, a plan or an error, is past the deadline or has been idle for 10 minutes is one the next request replaces, so the view opens empty rather than show a conversation that won't be continued. A session left on a question is reached through the tab list or Needs you.
- **What was asked at the desk now shows on the phone.** Any listed device that opens Voice mode on the Mac's page reads it. A device could already open the session's terminal through Needs you, and can open it from the list with option 02, so this is no new kind of reach. The privacy doc says so anyway.
- **A request still in flight when the view opens shows with no answer.** That is a request asked at the Mac, or one sent before a reload, while its turn goes on: what Claude has written so far is interim, so it is left off. The view doesn't follow it, because it can't poll an ask it didn't send. It shows the answer at the next open.
- **A long session is cut.** Only the newest exchanges up to a cap are shown, with a line saying how many earlier ones were left out.
- **Considered, not chosen: the Mac keeps its own log of what the phone was shown,** in memory or as a file in the pane folder. It would be exact to the view, but a log in memory is lost at a restart of Varnick while the session lives on, and a file is a second copy of every spoken request. Neither holds the requests asked before it was built.

## User Stories

1. As the user, I want to see what I asked and what Varnick answered when I come back to Voice mode on a Mac's page, so that I can follow up knowing where we were.
2. As the user, I want the earlier exchanges after a reload or a frozen page, so that a lost page doesn't lose the conversation.
3. As the user, I want to see them from another phone, so that the conversation belongs to the Mac and not to one browser.
4. As the user, I want to see what I asked the Mac by Hey Varnick when I continue from the phone, so that a desk question can be followed up away from it.
5. As the user, I want the earlier exchanges gone once the Voice session has ended, so that the view never shows a conversation Claude no longer has.
6. As the user, I want the phone to keep none of it, so that a lost phone holds no spoken requests.

## Implementation Decisions

- **One new relay request, `voiceExchanges`, for a listed device only,** as `outlineRead` and `phoneAutomations` are.
  - A paired Mac and the host's own id are refused.
  - A headless host refuses it: it has no Voice session.
  - It joins the device-only set that the relay and the Mac's app both check and that `make check-slots` lists.
- **The Mac's running Varnick answers it on the main actor,** beside the three Voice mode requests, and not the relay alone. That way the session read is the one the next request would go to: the newest unopened voice pane, as the voice session's host judges it. With no Voice session the answer is an empty list, not an error.
- **The transcript is read off the main actor,** as the `read` tool reads one, with the shared package's exchange reader.
- **A pure function in the shared package makes the reply from the exchanges.**
  - It keeps each exchange whose prompt begins with the voice hint, and leaves out a prompt without it.
  - The request is what follows the hint.
  - The answer is the exchange's last text Claude wrote, cut to the `answered` event's 8,000 characters, or none.
  - It keeps the newest exchanges within a total (a named constant well under a reply line's 1,000,000 bytes), drops the oldest first, and says how many it dropped.
  - Checked read-only on the user's machine: the Voice session's requests, the first included, are typed prompts in its transcript, with the hint first and closed by "] ".
- **The page asks once, when the view opens,** and draws the reply with the lines the live exchange uses.
  - A failure leaves nothing above and one line in the view's notice, never a line of the exchange. Voice mode works either way.
  - The exchanges are held in the view only. The page's worker and cache hold none (every reply is `no-store`).
- **Logged:** the access line, and on the Mac a line of counts and kinds. Never a word of a request or an answer.
- **What the records say** (the builder writes them):
  - **ADR 0043, an amendment dated with the build.** Replace "Nothing of the exchange is kept" with: the page keeps none; when the view opens, it reads the Voice session's exchanges from the Mac (`voiceExchanges`, device only), and the Mac reads them from the session's transcript. They go when the session ends or is opened. No protocol bump.
  - **`CONTEXT.md`, Voice mode, the Phone page bullet.** After "each exchange is shown as text too", add that the Voice session's earlier exchanges are shown when the view opens, read from the Mac, until the session ends.
  - **`CONTEXT.md`, Voice session.** Say that the Phone page's Voice mode shows its exchanges.
  - **`docs/agents/where-it-breaks.md`, Voice mode on the phone.** Add the request, its cap and who may ask it.
  - **`docs/privacy-and-security.md`, Anthropic through the Voice session.** Say that a listed device's Voice mode shows the session's requests and answers, Hey Varnick's at the Mac included.
  - **The protocol stays at 34.** The request is new and no request or reply changes shape. It is sent only by a host's own page server, which ships in the same app as the relay, so the two never differ. This is ADR 0040's amendment of 2026-10-29, which avoided a bump at the user's word. A running Varnick older than its relay (a build not yet restarted) answers "Unknown request", and the view says it couldn't read the earlier exchanges.

## Testing Decisions

- **The pure function, by `make check-voice` cases:**
  - a hint taken off, from the Mac and from the phone;
  - a prompt with no hint left out;
  - an exchange with no answer;
  - an answer cut at its limit;
  - the total reached and the oldest dropped, with the count.
- **The page, by `bun test`,** as `voice.test.ts` does today: shaping the reply on the server and drawing the lines.
- **The device-only rule,** by `make check-slots`.
- **By hand, once the user has restarted the Mac on the build** (agents don't drive the screen, and the Voice session runs with permissions skipped):
  1. Ask two things in Voice mode, End, then reopen it: both are above.
  2. Reload: the same.
  3. Open it on another listed phone: the same.
  4. Ask at the Mac by Hey Varnick, then open Voice mode on the phone: that exchange is there.
  5. Wait past 10 minutes: the view opens empty.
  6. Open the session (Needs you's Open, or Take over with option 02), then Voice mode: empty, and the next request starts a new session.

## Out of Scope

- Keeping exchanges past the Voice session's end. Session search finds its transcript as any session's.
- Marking which requests were asked at the Mac.
- Following a request the page didn't send.
- A headless host, which has no Voice mode.
- Voice mode on a Mac (ADR 0044), which has no view of the exchange.

## Further Notes

- **Siblings:**
  - `outlineRead`, a device-only read that the Mac's app answers and the page asks when a view opens;
  - the `read` tool's transcript reading, from the exchanges of `sessions-cant-search-sessions` option 01;
  - the Voice mode requests' answering on the Mac (option 05 of `phone-page-is-only-a-browser-tab`).
- **Verified in the code at 051243f:**
  - closing the view clears the log;
  - the live answer's text is the raw answer cut to 8,000 characters;
  - the shared package reads a transcript as exchanges by typed prompt;
  - the device-only set is checked by the relay and the app.
- **Inferred:** that the last text block of an exchange is the Stop input's `last_assistant_message`, which the live answer is.
- **Works with option 02,** which lists the session for the phone to open. Neither needs the other.
