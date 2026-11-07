---
problem: sessions-cant-start-sessions-in-other-projects
title: "`tab_done`: a session marks Done a tab it opened with `tab_open`, until the user has used it"
summary: One more tool in the pane tools' set. A session marks Done a tab it opened with `tab_open`, as the user's Done would. Every pane in the tab closes and the tab goes to Completed, where ↩ reopens it whole. The session can do this only while the user hasn't taken the tab over. That follows `pane_close`'s rule (a click, a key, or focus moved to a pane of it), and a Take over on another Mac or the phone also counts. It is also refused while a Claude session in the tab is mid-turn. `tab_open` now saves the opened-by mark `pane_open` saves, which is how the tab is known to be the caller's. Done on any other tab stays the user's, and `keys` still refuses the Done key.
status: shipped
---

## Solution

**One tool, in the pane tools' set.** `tab_done` joins `pane_open`, `pane_close` and `tab_open` on the `varnick` server, so it reaches the same sessions as they do: every Claude session in a Varnick pane, but not the voice session, a run, a Task step or a headless host's session. There is no switch. A session gains the tool at its next start or restart.

**What it takes:** `id`, the pane id from `tab_open`'s reply. It also accepts the tab's card id or a pane id that `board_read` lists for that tab, since a restart of Varnick resets the ids.

**What it does: the user's Done, nothing less.** The tab is marked Done exactly as the board's Done or the pane's Done button marks it:

- Every pane in the tab closes. That includes terminals, pages, apps and files the new session opened beside itself.
- The tab goes to Completed and to Recent, and ↩ on its Completed card reopens it whole.
- Search finds its sessions under it.
- Paired Macs and the phone see it in Completed, as for any Done of this Mac's tab.
- Its standing notice goes with its panes.

No question is asked. The refusals below stand in for the one the user's Done asks while a session works.

**Only a tab this session opened with `tab_open`.**

- **How it is recorded.** `tab_open` now saves on the new pane the opened-by mark `pane_open` saves on its helpers: the calling pane. `pane_close` still refuses that pane, since it looks for a pane in the caller's own tab first and answers "in another tab". The mark names the opener's pane, not its conversation, so a Restart or a `/clear` of the opener keeps it, as for `pane_close`.
- **When the tab is the caller's to end.** All three of these must hold:
  - the tab is not the caller's own;
  - a pane of it carries the caller's mark;
  - every pane of it carries some session's mark.

  Only `tab_open` can put the caller's mark in another tab, since `pane_open` and `find_open` add panes only to the caller's own tab and panes never move between tabs. A pane the user added carries no mark, and neither does one the user has used. So a tab the user has worked in is theirs, whichever pane they worked in.
- **What counts as the user taking it over.** `pane_close`'s three signals, unchanged, on any pane of the tab:
  - a click in it;
  - a key typed in the panel while it has the keyboard;
  - focus moved to it from another pane of its tab.

  Two more are new for this mark:
  - another Mac or the phone takes the tab over (Take over);
  - the tab is reopened after it closed.

  These do not count: bringing the tab up to watch it, a session's `show`, reading it on the board, and the phone's live screen or a paired Mac's card without Take over.
- **Tabs opened before this build** carry no mark, so they are the user's.

**Refused, each with what would change it:**

- **Another Mac or the phone controls the tab.** The user has it there. This is read at the call, since right after a Take over the card on this Mac is not up yet.
- **A Claude session in it is mid-turn**, meaning it is in any of these states:
  - working;
  - its turn ended with background work still running;
  - it waits on the user, on a permission dialog, a question, a plan or an MCP request.

  For a session that is still working, the reply says to wait (with `SendMessage`'s `notify_when_idle` the caller gets one notice when the session has nothing left to do) and call again. For one waiting on the user, it says the Needs you notice has called the user there, so it is theirs to answer or end. A session waiting for its next prompt, one stopped on an API error, and one that has not begun a turn can all be ended.
- **The tab is already closing.** The user's × or Done is under way, or a question of theirs waits.
- **The tab is the caller's own.** The reply points to `pane_close` for panes beside the caller.
- **The tab was not opened by this session, or the user has used it since.** As `pane_close` says it: the tab is theirs to mark Done.

**From a tab another Mac or the phone controls,** the call is answered, as `tab_open` is. It changes nothing in the caller's tab, and the tab it ends is this Mac's own.

**What it answers.** For example, with made-up values: "Marked done the tab in kestrel (s7): its panes are closing and it goes to Completed, where the user can reopen it." When the tab was on screen in the visible panel, the reply adds that the user had it showing and the panel moved to the next tab, so the caller can say why it went.

**`tab_open`'s description** now says to mark the tab Done with `tab_done` once the caller has what it needs, while the user hasn't used it, in place of "pane_close does not close it".

## Trade-offs

- **Done, not a close that leaves an ended card.** A tab closed without Done becomes an ended card in the board's Stopped column, which waits there for the user to mark it done or open it. One such card per helper would leave the user the same chore this follow-up removes. The opener is the one who knows the work is finished, since it has the result. Nothing is lost with Done: Completed keeps the tab whole, ↩ reopens it, and search finds its sessions under it. It is also the model's own Done, so there is no new way of closing a tab.
- **A new tool, not `pane_close` widened.** `pane_close` closes one pane as ⌘W does, and the tab stays. Widened, one tool would close a pane or mark a whole tab Done depending on which tab the id is in, and `tab_open`'s description already tells sessions that `pane_close` doesn't reach other tabs.
- **Named `tab_done`, not `tab_close`.** "Close" is the tab's ×, which leaves an ended card; this is the Done mark.
- **The mark is the opened-by mark on the pane, not a new field on the tab.** Reusing it means no new saved field, and the user's click, key or focus already clears it on every path `pane_close` relies on. A field on the saved tab would need a second clearing path that has to stay in step with the first.
- **The mark is not `tab_open`'s opener note.** That note is absent when the opener's name couldn't be read, and it is cleared by the new session's own `/clear`. It also records nothing about the user's use.
- **A Take over elsewhere counts, beyond `pane_close`'s rule.** Typing on the phone or another Mac reaches no key handler here, so a tab the user worked on there and then handed back would look untouched. The extra clearing applies only to the mark `tab_open` sets. `pane_open`'s marks are left alone, so `pane_close` in a tab another machine controls keeps its rules (option 04 of `panes-open-only-by-hand-at-a-mac`).
- **Watching doesn't count, so a tab can go while the user reads it.** Bringing a tab up is not taking it, as for `pane_close`. Without this, the opener could never end a helper the user looked in on, and looking in on helpers is what option 01's tab is for. Refusing while the tab is on screen was considered and rejected. It would leave a tab that the user left showing impossible to end, with nothing to tell the opener when it could try again. The reply says when the tab was showing.
- **Mid-turn is refused, with no `force`.** The user's Done asks before ending working sessions, and a tool can't answer that question. Ending a turn in progress loses work the opener hasn't seen. The opener can already wait for the turn to end with `notify_when_idle`. A session waiting on the user's dialog has called the user there, so ending it under them is refused too.
- **It ends everything in the tab,** as Done does: a terminal or dev server the new session opened beside itself ends with it.
- **The user may not hear that the helper finished.** Its Done notice goes with its panes. The opener, which asked for the work, is the one that reports it.
- **Tabs the helper itself opened with `tab_open` stay open.** No running session holds their mark once their opener's tab is Done, so they are the user's.

## User Stories

1. As the user, I want a session that opened a helper tab to mark it Done when the helper's work is finished, so that finished helpers don't pile up in my strip waiting for me.
2. As the user, I want a helper tab marked this way to go to Completed, so that I can reopen it whole or find its sessions in search as for my own Done.
3. As the user, I want a tab I clicked in, typed into or added a pane to to stay mine, so that a session never closes work I have joined.
4. As the user, I want a tab I took over on the phone or another Mac to stay mine after I hand it back, so that typing there counts as typing here.
5. As the user, I want to be able to bring a helper tab up and watch it without it becoming mine, so that I can look in on a helper and still have its opener tidy it away.
6. As the user, I want a session never to mark Done a tab it didn't open, its own included, so that Done on every other tab stays mine.
7. As the user, I want a helper that is still working, still has background work, or is waiting on my answer never to be ended by its opener, so that no turn is cut off and no dialog I was called to vanishes under me.
8. As the user, I want `keys` to keep refusing the Done key, so that the only way a session marks a tab Done is this tool and its rules.
9. As the user, I want a tab I reopened from Completed to be mine, so that the session that ended it once can't end it again.
10. As the user, I want the phone and my other Macs to see the tab in Completed, so that the helper's end looks the same wherever I am.
11. As a session, I want to end a tab by the id `tab_open` gave me, or by its card or pane id from `board_read` after Varnick restarts, so that I can tidy up whenever I have the result.
12. As a session, I want a refusal to say why (the user used it, it is controlled elsewhere, it is still working, it waits on the user, it is closing, it isn't mine), so that I can wait and call again or tell the user.
13. As a session, I want the reply to say when the user had the tab on screen, so that I can tell them why it went.
14. As a session in a tab the phone controls, I want the tool to work as `tab_open` does there, so that a lead the user follows from the phone can tidy its helpers.

## Implementation Decisions

- **The siblings.** `pane_close` is the model for the ownership rule, the refusals and checking again after a wait. The board's Done is the model for what happens: the model's one Done for a tab of this Mac, which closes every pane and puts the tab in Completed. No other closing path is added.
- **The route.** The call is Panel access's request with the new tool name, answered by the pane tools' router after its own checks. Like `tab_open`, the caller's tab's layout lock is not applied, since nothing of the caller's tab changes. The tool joins the list answered in a tab another machine controls. The request's version stays, since only a tool name is new.
- **The order of the checks**, all on the main actor:
  1. the id, resolved to a tab, either the tab itself or the tab holding that pane;
  2. not the caller's own tab;
  3. the marks;
  4. not closing;
  5. the turns.

  Then, when any pane of the tab runs in zmx, the read of who controls it, off the main actor, as the router reads the caller's tab: anything but this Mac or nobody is refused. After that read, everything is checked again (the calling pane, the tab still open, the marks, closing, the turns). Then Done follows, with nothing awaited in between.
- **The decision is one pure function** in the shared package, beside `tab_open`'s pure parts. It takes plain values: each pane's id, mark and turn; the caller's id; whether the tab is the caller's; whether it is closing; and who controls it. It returns allowed or the refusal's kind. The app supplies the values and turns the kind into the reply's words.
- **`tab_open` sets the mark** on the pane it makes, to the calling pane, as `pane_open` does. Nothing else about `tab_open` changes but its description.
- **Take over clears it.** Where this Mac's own pane turns into a card because another machine now controls its session, the model clears that pane's mark if the mark names a pane outside the pane's tab, then saves. Only `tab_open`'s mark can name such a pane. A pane `tab_open` starts is never started for another machine, so its card can only mean a Take over.
- **Reopening clears it.** A closed tab reopened here comes back with every mark that names a pane outside it dropped. Here means ↩ on a Completed, ended or Recent card, or `find_open`. The same applies to a closed tab reopened at a paired Mac's request.
- **Saved state:** no new field, and the shape of the saved sessions file is unchanged. An older build reads the mark as `pane_open`'s: its `pane_close` refuses the pane as in another tab, and the user's click clears it as before.
- **The log** holds the tool, the outcome's kind (done, or the refusal's kind) and whether the tab was on screen. It never holds a project, a name or a prompt.
- **The description** says what Done does (every pane closes, the tab goes to Completed and the user can reopen it), what `id` takes, the refusals, and when to call it: once the caller has what it needed.
- **Docs:**
  - an amendment to ADR 0031: a session can now mark a tab Done, which until now was the user's or a listed Mac's or device's (ADR 0045);
  - where-it-breaks › Panel access: `tab_open` now sets the mark; a bullet for `tab_done` covering the rule, the two new clearings, the check again after the read and the Done path; and its hand check;
  - the guide's paragraph on `tab_open`;
  - `CONTEXT.md`'s Panel access and Tab entries (who may mark Done);
  - the privacy doc's line on what sessions may do.

## Testing Decisions

- **No test target yet.** The pure decision is the seam, checked with `tab_open`'s by `make check-open`, since that is where `tab_open`'s own pure rules are already pinned. The cases:
  - the caller's own tab;
  - no pane with the caller's mark;
  - another session's mark;
  - a pane with no mark beside the caller's;
  - each turn (working, background, each kind of waiting on the user, waiting, failed, none);
  - closing;
  - control here, nobody, another machine and mixed.
- `make check-mcp` gains `tab_done`, listed only in the pane tools' set, with no name clash.
- **Build:** `make build`.
- **By hand, after the user restarts Varnick,** in sessions restarted after the build:
  - From a session in Home, `tab_open` a helper with a prompt, wait for its notice, then `tab_done` it. The tab goes to Completed, ↩ reopens it whole, and search finds its session under it. No other terminal changes size (`VARNICK_LOG_RESIZE=1`).
  - Each of these makes `tab_done` refuse, and refuse again after the tab is handed back: a click in it, a key typed in it, a split added by hand, and a Take over on the phone.
  - Bringing the tab up and leaving it untouched does not make it refuse, and the reply says it was showing.
  - While it works, has background work, or waits on a permission dialog, it is refused with the reason.
  - A tab from another session, the caller's own tab and a tab opened before the build are refused.
  - After `tab_done` and ↩, it is refused.
  - After a restart of Varnick, `board_read`'s card id for the tab works.
  - From a tab the phone controls, it is answered.
  - `keys` still refuses the Done key.
  - `pane_close` in a tab the phone controls behaves as before (option 04's hand check).

## Out of Scope

- Ending, closing or restarting any tab but one the session opened with `tab_open`, the session's own tab included.
- `pane_close` seeing typing on another machine. Its marks are not cleared by a Take over (above). This is worth raising on its own, since the same gap holds for helpers beside a lead the user follows from the phone.
- Tabs `tab_open` opened before this build, and tabs a session reopened with `find_open`.
- Telling the helper session it is about to be ended, or waiting for it to finish on the caller's behalf.
- A cap on how many tabs a session keeps open.

## Further Notes

- **The user's decisions of 2026-11-06** (relayed by the coordinator):
  - the opener can end a tab it opened with `tab_open` as long as the user hasn't taken it over (focused it or typed into it), the rule `pane_close` uses;
  - Done on any other tab stays the user's, and `keys`' refusal of the Done key is unchanged;
  - this option is accepted.

  This is option 01's follow-up "A session can't close a tab it opened".
- **Verified in the code at main 4975061:**
  - `tab_open` sets no opened-by mark;
  - `pane_close` looks in the caller's tab before it reads the mark, and refuses a pane elsewhere as in another tab;
  - the mark is cleared by a click, by a key typed with the tab showing, and by focus moving to the pane from another, and not while a session's `show` changes the view;
  - bringing a tab up refocuses its focused pane without clearing the mark;
  - `pane_open` and `find_open` add panes only to the caller's own tab, and panes move only within their tab;
  - Done closes every pane and puts the tab in Completed and Recent, while a close without Done leaves an ended card; when the tab that closes is the one showing, the panel moves to its neighbour;
  - the user's Done asks only while a session works or has background work;
  - this Mac's pane turns into a card when its client exits and its session is labelled for another machine;
  - reopening a closed tab keeps its panes' records as saved;
  - the control read the router uses gives here, nobody, another machine or mixed;
  - board cards' ids are their tabs'.
- **Assumptions, each open to overturning:**
  - "Focused it" is read as `pane_close`'s code reads it, so bringing the tab up to watch it is not taking it. Read the other way, almost every helper the user looked in on would stay theirs.
  - Waiting on the user mid-turn counts as mid-turn and is refused.
  - A turn stopped on an API error can be ended.
  - The mark names the opener's pane, so a `/clear` or Restart of the opener keeps its right, as for `pane_close`.
  - A tab reopened by anyone, a session's `find_open` included, comes back the user's.
- **Unverified:** that a Take over always reaches this Mac as the pane's client exiting. After a restart of Varnick, a pane never shown since has no client until it is shown, so a Take over of it, handed back before this Mac looks, would not clear the mark. The read at the call still refuses while the other machine has it.
- **Combines with** options 01 and 04 (shipped), and with options 02, 03 and 05.

Follow-ups from the review (2026-11-06, verdict merge after one fix round; the fix clears the opener's mark when another machine's End releases a dormant pane):

- **should-fix:** the hand check after a restart (where-it-breaks, Panel access, `tab_done`, starting with the dormant Take over on the phone) is still owed.
- **nits:** a narrow race, unverified: `hostEndTab` releases panes one at a time and clears each mark only after its release, so a `tab_done` landing in that gap could pass; clearing the tab's labelled panes' marks before the loop would close it. The turn read can see "waiting" just before background work is recorded (the user's own Done shares this). The guide's "waits on you" list leaves out an MCP request. `TabDone.Pane.id` and the turn inside `waitingOnUser` are never read. Long comment lines in the open-check header and the `paneTakenOver` doc comment.
