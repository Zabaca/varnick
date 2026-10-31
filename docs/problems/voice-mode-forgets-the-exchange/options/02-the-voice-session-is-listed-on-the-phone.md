---
problem: voice-mode-forgets-the-exchange
title: A Mac's Phone page lists its Voice session, marked, from its first turn until it ends
summary: The Mac's tab listing includes the Voice session's hidden tab for a listed device once its first request is taken, marked as the Voice session and not as a run. The phone shows it in Open tabs with "Voice session" and "Runs with permissions skipped". It opens like any tab. Watching leaves it the Voice session; Take over makes it the user's, as ADR 0042 has it, though it runs with permissions skipped until restarted. Other Macs and the page server's push watch still don't see it. No protocol bump.
status: shipped
---

## Solution

A Mac host's Phone page lists that Mac's Voice session in Open tabs from its first turn until it ends. Its row is marked **Voice session**, with the line "Runs with permissions skipped". It opens like any tab:

- **The live screen,** to read what it was asked and what it did, as any session's. Watching it takes nothing: Voice mode and Hey Varnick go on typing into it.
- **Take over,** to type into it from the phone. That makes it the user's, as opening it at the Mac does (ADR 0042):
  - Varnick no longer types into it or ends it, and the next spoken request starts a new Voice session.
  - The phone lists it as an ordinary tab from then on.
  - The running session still has its permissions skipped until it is restarted or resumed, when it follows the Mac's Skip permissions. The tab view says so before Take over.
- **Done,** to close it on the Mac, which ends it.

When the Voice session ends (10 minutes after its last turn, or the voice session switched off), the row goes. Other Macs still don't list it, and no push is sent for its turns, as today.

## Trade-offs

- **It runs with permissions skipped, and the phone can now type into it.** Anyone holding the phone could already speak to it through Voice mode, and type into it through Needs you's Open. The list adds a way in that needs no question pending. The mark says so on the row and in the tab view. The consent is the one the session already needs: Hey Varnick on, on that Mac.
- **Taking it over ends its time as the Voice session.** Voice mode then starts a new session, and option 01's earlier exchanges are in this session's terminal rather than in Voice mode. This is ADR 0042's rule, kept: Varnick typing into a session the user is typing into would collide.
- **No push for it.** The Mac suppresses Done for an answer a surface spoke. The page server's push watch can't tell that, and would push Done after every spoken answer, so it is kept out of the listing the watch reads, as today. Needs you reaches the phone through Voice mode's own event while the mode is open, and not otherwise, as today.
- **Other Macs don't list it.** Listing it there would need a protocol bump, because an older Mac would show it as an ordinary tab. The Mac it runs on already has Settings › Listening › Show.
- **Only from its first turn,** so a session that never took its request is never listed.

## User Stories

1. As the user, I want to see on the phone that a Mac's Voice session is still going after I end Voice mode, so that I know I can pick it up.
2. As the user, I want the Voice session told apart from my own sessions, and told that it runs with permissions skipped, so that I know what I am opening.
3. As the user, I want to watch what the Voice session did without taking it from Voice mode, so that I can read the conversation and still talk to it.
4. As the user, I want to take the Voice session over and type into it from the phone like any session, so that I can continue a conversation that needs more than speech.
5. As the user, I want to close it from the phone with Done, so that I can end a session that went wrong.
6. As the user, I want its row gone when it ends, so that the list never offers a session that isn't there.
7. As the user, I want my other Macs' lists unchanged, so that a hidden session at one Mac doesn't fill the others.

## Implementation Decisions

- **The Mac's listing includes the Voice session's hidden tab once its pane's turn file shows a turn,** which is from when its first request is taken.
  - The listing is `tabs`, which the relay answers from the saved tabs and the pane folders.
  - "Has had a turn" is taken from the moment the request is taken, not when it ends, so a session that stopped on a question is listed too.
  - The tab carries a new optional mark saying it is the Voice session.
  - It does not carry the run mark that it would get today for being unopened. That mark puts a tab under Runs and makes the other Macs drop it as a run.
- **Only a listed device is told.** The relay leaves the marked tab out of its reply to a paired Mac and to the host's own page server, which asks for the port proxy and for push routing. A device's listing has it: the home, the tab view, Take over and Done.
  - A headless host has no Voice session and lists none.
- **Watching keeps it the Voice session; Take over makes it the user's,** by today's rule. The Mac's tick sees a pane in another machine's control and marks it opened. That clears the voice mark and the skipped permissions from its record, so its next start or resume follows Skip permissions. Nothing changes on the Mac's side for this.
- **The page:**
  - Open tabs shows the row in the host's tab order, with the mark ("Voice session") and the line "Runs with permissions skipped".
  - The tab view of a marked tab adds a note: "Voice mode and Hey Varnick type into this session. Take over makes it yours: Varnick stops using it. It runs with permissions skipped until it is restarted."
  - Runs and its automation link are unchanged.
- **What the records say** (the builder writes them):
  - **ADR 0043, an amendment dated with the build.** Replace "The hidden tab is still never in a tab list: it is reached by that event alone." with: a Mac's Phone page lists it, marked, for a listed device only, from its first turn; other Macs and the push watch never see it; watching doesn't take it and Take over does. No protocol bump.
  - **ADR 0042, Consequences.** "The hidden tab stays out of the listing to other Macs and the phone" gets a pointer to that amendment, so the rule lives in one place.
  - **`CONTEXT.md`, Voice session.** "Its tab is out of sight until the user opens it, as a Run's is" becomes out of sight at the Mac and on other Macs, while a Mac's Phone page lists it, marked, from its first turn.
  - **`CONTEXT.md`, Phone page.** Its open tabs include the Mac's Voice session, marked.
  - **`docs/agents/where-it-breaks.md`.** Change "the hidden tab is still never in a tab list" in Voice mode on the phone. Under Peers, say that the voice tab goes to a device only and carries no run mark.
  - **`docs/privacy-and-security.md`, Anthropic through the Voice session.** "What the session does is shown in its tab" gains the Phone page's list.
  - **The protocol stays at 34.** The `tabs` reply gains an optional mark on one tab, and only a listed device's reply has it. A device's listing is asked only by the host's own page server, which ships in the same app as the relay. A paired Mac's listing is unchanged, so no two builds read it differently. This is ADR 0040's amendment of 2026-10-29, which avoided a bump at the user's word.
  - **Until the Mac's Varnick restarts on the build** (inferred), a page server still running from before passes the tab through without its mark, so the row shows unmarked.

## Testing Decisions

- **The relay's rule, by `make check-slots`:** which tabs a paired Mac, the host's own id and a device are told. The cases: the marked tab to a device only, and an ordinary tab and a run to all, as today.
- **The listing's choice, pure where it can be:**
  - a voice tab before its first turn is left out;
  - after it, the tab is marked and carries no run mark;
  - an opened one is an ordinary tab.
- **The page, by `bun test`:** the home's shaping keeps the mark and leaves the tab in Open tabs, not Runs, and the row and the tab view's note.
- **By hand, once the user has restarted the Mac on the build** (agents don't drive the screen, and the Voice session runs with permissions skipped):
  1. Ask something in Voice mode, End: the row is in Open tabs, marked.
  2. Open it and watch: the live screen shows the exchange. Back, Voice mode, ask again: the same session answers, and the Mac's log says reused.
  3. Take over and type: it answers. Voice mode then starts a new session, and the old row is an ordinary tab.
  4. Done on a fresh Voice session's row: it ends, and the row goes.
  5. Wait past 10 minutes: the row goes.
  6. Another Mac's tab list never shows it, and no push comes for its answers.

## Out of Scope

- Listing it on other Macs.
- Pushes for its turns.
- Keeping it the Voice session after the user types into it.
- Linking it from Voice mode's view: Needs you's Open is unchanged.
- A Voice session on a headless host.

## Further Notes

- **Siblings:**
  - the run mark on an unopened run's tab, which the phone lists under Runs and the Macs drop;
  - the relay telling a device less than a Mac (`hiding`), and the host's own page server more;
  - Take over making a hidden pane opened, the tick's rule that already covers Needs you's Open.
- **Verified in the code at 051243f:**
  - the listing leaves the voice tab out for every asker;
  - an unopened tab gets the run mark;
  - Take over uses the host's whole listing, so a device can take a tab its own listing has;
  - the tick treats a pane in another machine's control as opened and clears the voice mark and the skipped permissions;
  - the push watch reads the listing as the host itself.
- **Inferred:**
  - that the live screen attaches without relabelling, so watching doesn't open it;
  - that Done from the phone ends an unopened voice tab as it closes any tab.
- **Works with option 01,** which shows the exchanges in Voice mode. Neither needs the other.
