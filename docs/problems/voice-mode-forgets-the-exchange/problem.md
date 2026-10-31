---
title: Ending Voice mode on the phone loses the exchange, and the Voice session looks gone though it lives on
description: On a Mac's Phone page, End (or Back, or any navigation away) closes Voice mode and clears everything it showed. Reopening it, reloading the page or opening it on another phone shows an empty view. Meanwhile the Mac's Voice session is still alive and takes the next request in the same conversation for 10 minutes after its last turn, but nothing on the phone lists it or shows what it was asked.
impact: The user can't see what they asked and what Varnick answered, so a follow-up is made from memory, and the session looks gone when it is waiting to be picked up. The only way to it from the phone is the Needs you event's Open, and only while Voice mode is on. What was asked at the desk by Hey Varnick, which the same session holds, is invisible from the phone altogether.
severity: low
evidence: The user's request of 2026-10-31, relayed by the coordinator. Code and docs read at 051243f (main). That the Voice session's requests are typed prompts in its transcript, the voice hint first, was checked read-only against Voice session transcripts on the user's machine; nothing of them is kept here.
status: open
---

## What the user wants

1. **Coming back to Voice mode shows the earlier exchanges**, read from the Voice session on the Mac, so they survive a reload and show on another phone, and go when the Voice session ends. Not merely kept in the page's memory.
2. **The Voice session is listed in the phone's sessions** (the home's Open tabs) once it has had a turn, marked as the Voice session, for as long as it lives, and can be opened and taken over from the phone like any session.

## Today

Verified in the code at 051243f unless marked.

- **The exchange lives in the view.** Voice mode is a view of the page. What it shows is the view's own state, the user's requests and Varnick's answers, built from the events the Mac sends. Closing the view (End, Back, any navigation) clears it. The page's code and ADR 0043 both say "nothing is kept". A reload or another phone starts empty too.
- **The Voice session goes on.** It is the Mac's one hidden Claude session in Home (ADR 0042). The next request within 10 minutes of its last turn is typed into it, from the phone or from Hey Varnick at the Mac, so Claude still has the conversation that the phone no longer shows. The Mac's tick ends it after that.
- **It is left out of every listing.** A Mac's `tabs` reply leaves out the Voice session's hidden tab for good, for other Macs and the phone alike, the same as a hidden Task Run's. The phone reaches it only through Voice mode's Needs you event, which names its zmx session. The Open button there attaches with take, and taking it makes it the user's (ADR 0042: the Mac's tick sees another machine in control and clears the voice mark and the skipped permissions from its record).
- **A run nobody opened is listed instead.** It goes out with a run mark: the other Macs drop it, and the phone shows it under Runs. That is the sibling for listing a hidden tab with a mark. The voice tab is unopened too, so including it as the code stands would give it the run mark.
- **The phone already reads a session's turns.** It does this through the tab view (the live screen, then the terminal after Take over) and the turn word each listed Claude pane carries. Nothing on the phone reads a transcript.
- **The transcript has the exchanges.** Each request is a typed prompt in the Voice session's conversation, the voice hint in front, followed by Claude's answer. The shared package already reads a transcript as exchanges, for the `read` tool.
- **No push for it.** The page server's push watch reads the host's `tabs` as the host itself, and the Voice session isn't in that listing, so nothing is pushed for its turns. On the Mac, the notifier suppresses Done for an answer a surface spoke.
- **At the Mac,** Settings › Listening's Show button opens it, and the tab is then the user's.
