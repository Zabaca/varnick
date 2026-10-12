---
problem: sessions-cant-read-or-drive-varnick
title: Sessions press keys in the panel through its own key path, to hand-test Varnick's views
summary: Accepted on 2026-10-11 (the user's decision, relayed by the coordinator), to follow option 01. This builds on option 01's server, switch and router. A `keys` tool sends text and key combos into Varnick's panel as key events handed to Varnick's own event dispatch (`NSApp.sendEvent`). They pass through the panel's key monitor, the view's own key handler and the first responder as the user's keys do, and nothing reaches another app. It works only while the panel is visible and key and the user hasn't typed in it for 2 seconds. The view on screen must take keys: search, the board or the Outline, never a terminal or page tab, Settings, the Restart Varnick card or the split picker. Each view refuses the keys that would end, restart or mark sessions, start one, or turn on the microphone. With `panel` and `outline_read`'s `as_shown`, a session checks what each key did. No grant is needed.
status: shipped
---

## Solution

`keys` joins Panel access's tools (option 01) under the same switch.

| Tool | Arguments | What it does |
|---|---|---|
| `keys` | `text`, `keys` | Types `text`, then presses `keys` in order, into the view the panel shows, as the user would. The combos follow the screen tool `type`'s syntax (`cmd+z`, `shift+Tab`, `Return`). It reports what it sent, never what happened: `panel` and the view's `_read` show that. |

The events are made in Varnick and handed to `NSApp.sendEvent`, addressed to the panel's window. So the panel's key monitor sees them first, and the view's `key` handler (`Outline.key`, `SessionBoard.key`) or the first responder acts on them, exactly as on a real key. Nothing is sent at the system level, so nothing can reach another app, and no permission is involved.

## Trade-offs

- **It tests the path the user's keys take.** That path is where the Outline's reviews found its bugs: ⇥ under a hidden sibling, a caret landing in a row not yet built, a tag click letting the window place the caret, keys arriving while the caret moved. Option 01's model-level actions would pass straight over all of them.
- **The events are synthetic, though in-process.** They skip the hardware and the window server. They still pass through AppKit's own dispatch, the monitor and the view's handler. How an input method treats them is unverified.
- **It takes the panel while it runs.** The user sees each key act, and the gate refuses while the user is typing. It doesn't refuse while the user only watches, or reads the session's own pane, which the view replaces as soon as `show` runs.
- **Only when the user has the panel up.** It never brings the panel up, since that would take the keyboard from the app the user is in. In practice the user is talking to the session in the panel, so it is up.
- **A stray key acts like the user's.** In the Outline it can delete bullets, which ⌘Z undoes. Keys that act on sessions, or start Listening, are refused: the always-refused ones before the first key, a view's own as each key comes, so the keys before it in the call are sent.

## User Stories

1. As a Varnick user, I want a session to hand-test a view it built, pressing the keys I would, while I watch the panel.
2. As a Varnick user, I want those keys never to end, restart or mark my sessions, start a new one, or turn on the microphone.
3. As a Varnick user, I want a session's keys to stop the moment I start typing in the panel.
4. As a Varnick user, I want a session's keys never to go to another app, or to a terminal pane.

## Implementation Decisions

**Delivery**
- **Building the events.** A key-down and key-up pair per character or combo, made for the panel's window. A character carries itself and no modifiers, as the screen tool `type`'s characters do. A combo is read against the current layout by `ScreenKeys.parse`, shared with `type`.
- **Sending them** in order through `NSApp.sendEvent`, one at a time, each after the last has been handled, at `type`'s pace.
- **The limits are `type`'s:** at most 500 characters with no control or line-separator character, and at most 10 combos, each refused whole, never cut.
- **One action at a time across all sessions,** on `ScreenAccess`'s queue, so a screen `type` and `keys` never interleave.

**The gate,** checked on the main actor before every event, with nothing awaited between the check and the post:
- the switch and the pane, as for every Panel access call;
- the panel is visible and key;
- the view on screen takes keys and doesn't refuse this one (below);
- no key of the user's has reached the panel within 2 s. The key monitor stamps the user's keys, and posted ones must not count. How to tell them apart is unverified.

The first failure stops the call, and the reply says how far it got ("Stopped after 4 of 9 keys: the user typed in the panel").

**Which views take keys**
- The protocol of option 01 gains one optional member: the reason a view refuses a key, nil when it takes it. A view without it takes no keys.
- **Search** takes keys, except:
  - ↩ or ⌘↩ on a prompt, which would start a session;
  - ↩ on the `!listen` row, which would turn on the microphone.
- **The board** takes keys, except D and R (Done and Restart a card). Its ↩ shows a card's pane, after which a tab shows and keys are refused.
- **The Outline** takes every key it handles, and those it passes to its text views.
- **Never:** a tab (a terminal, page or file pane), Settings, the Restart Varnick card, the split picker, the tab rename field.
- **Always refused, whatever the view:** the End session, Mark session done and Restart session keys as bound; Varnick's anywhere-shortcuts; the Quit key.
- Building added more refusals (paste, esc in the search, ↩ on a `?` result or a Recent row, a ⌃ letter, Settings, a new terminal tab) and allowed resuming a stopped pane here; the full list is in where-it-breaks, Panel access.

**The reply** says what was sent ("Sent 12 characters and 3 keys"), never that it worked. The session reads `panel` or the view's `_read` (with `as_shown` for the Outline) to see. How the view looks is a screen picture's job.

**The log** holds the tool, the kind, the counts of characters and keys sent and asked, and durations. Never the text or the keys.

**Docs:** option 01's ADR, `docs/privacy-and-security.md` and where-it-breaks get a `keys` line.

**State:** none beyond option 01.

**Where it breaks.** The items of `docs/agents/where-it-breaks.md` this touches:
- **Focus and keys:**
  - the key monitor's order;
  - a handler that returns handled for a key it didn't act on swallows it;
  - the board's and the Outline's taken keys.

  Posted events must go through the monitor, never straight to a view, or they test a path the user's keys don't take.
- **The Outline:** keys that arrive while the caret moves are queued and sent again (`queuedEvents`), so a posted event may be handled twice over. That is the same path as the user's, and worth watching in the first hand test.
- **Screen access:** the queue's turn, and `type`'s limits.

## Testing Decisions

- **No test target.** `make build`, then hand checks after the user restarts Varnick, with the user's go-ahead, since the keys act on the user's own panel.
- **With the Outline showing and the caret in a scratch bullet:**
  - `keys` with `text` types into the bullet;
  - `Return` adds the next bullet;
  - `Tab` nests it;
  - `cmd+z` undoes;
  - `outline_read` `as_shown` follows each step.
- **Refusals:**
  - typing in the panel while a long call runs stops it;
  - `keys` with a tab showing, with Settings showing or with the panel hidden is refused;
  - the End session key is refused before anything is sent; D on the board and ↩ on a prompt are refused when they come, after the keys before them.
- **Unverified, first:**
  - that local monitors see an event posted to the app's own queue;
  - how an input method treats one;
  - how posted events are told apart from the user's for the 2 s gate.

## Out of Scope

- Keys into a Claude, terminal or page pane: typing into a session belongs to `orchestration-lives-in-one-session`.
- Mouse events in the panel.
- Bringing the panel up or hiding it.
- Hand-testing Settings.

## Further Notes

- **It depends on option 01:** its server, switch, router, protocol and `panel` tool.
- **The Outline's part depends on the Outline's merge.** Search and the board can be hand-tested without it.
- **Accepted on 2026-10-11,** to be built after option 01.
- **Defaults the user didn't answer, which the user can change:**
  - `keys` never brings the panel up. It works only while the panel is visible and key and the user hasn't typed in it for 2 s. Bringing it up would take the keyboard from whatever app the user is in, and while the user talks to the session the panel is already up.
  - Search and the board can take keys before the Outline merges. The Outline's part comes after it.
- **Inferred, not checked:** that posting an event to Varnick's own queue needs no permission, and that it reaches the panel's local key monitor the way a real key does.
