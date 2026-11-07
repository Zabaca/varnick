---
problem: sessions-cant-reach-each-other-reliably
title: Option 01, with messages allowed only between a session and the sessions it opened
summary: As option 01, but `send` is refused unless the receiver is a session the sender opened (with `tab_open` or `pane_open`) or the session that opened the sender. A lead and its helpers talk both ways; two sessions the user started by hand can't message each other, and a session can't push into one it merely saw on the board. The relation is kept for the panes' lives, whether or not the user has used them. Narrower and safer, at the cost of every use that isn't a lead and its helpers.
status: rejected
reason: Two helpers opened by the same lead couldn't message each other directly. The user chose any Varnick pane, with option 01's skip-permissions rule (2026-11-07).
---

## Solution

Everything in option 01 holds; who may send to whom is narrower.

**The rule.** A session may send to:

- a session it opened with `tab_open` or `pane_open`, while that pane lives;
- the session that opened it (`opener`, or its id), while the pane that opened it lives and holds the conversation that did.

Any other target is refused: "Only a session you opened, or the one that opened you, can be sent a message." Option 01's skip rule still applies on top: a lead that doesn't skip permission checks can't open a helper that does (`pane_open`'s rule), so within a pair it rarely bites.

**The relation lasts.** It is kept with the opened pane, apart from the opened-by mark `tab_done` and `pane_close` read, which the user's first click or key clears; using a helper's tab doesn't cut it off from its lead.

## Trade-offs

- **Smaller reach.** A session misled by what it read can push only into its own helpers or its opener, never into an unrelated session that skips permissions.
- **Fewer uses.** Two sessions the user opened by hand can't coordinate; a session can't ask another project's session a question it found on the board; a helper can't message its sibling helpers. Each needs the lead to relay, or the user.
- **Same build, one more saved field:** the relation for `pane_open`'s panes, kept past the user's first use.

## User Stories

1. As the user, I want only a lead and its helpers to message each other, so that no session can push into an unrelated one.
2. As a helper, I want to reach my lead after the user has clicked into my tab, so that looking at my work doesn't cut me off.
3. As a session, I want a clear refusal when I try to message a session I didn't open, so that I ask my lead or the user instead.

## Implementation Decisions

- **One optional field** on the session record for `pane_open`'s panes, naming the opener, not cleared by the user's use (the opener note covers `tab_open`'s, with the pane id option 01 adds). Older files load; an older build ignores it.
- **The check** sits after the target is found and before the skip rule.

## Testing Decisions

- The rule's cases (opened, opener, sibling, stranger, after the user's click, after the opener's `/clear`) join option 01's table.
- By hand: a lead and a helper message both ways after the user clicks into the helper's tab; a send to a session the user opened is refused.

## Out of Scope

As option 01.

## Further Notes

- **Size, in agent time:** option 01's plus 15 to 30 minutes.
- **Combines with** options 01 to 04 as their sender rule; the user chose option 01's rule instead (2026-11-07).
