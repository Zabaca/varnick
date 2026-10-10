---
problem: sessions-cant-see-or-act-on-the-screen
title: Sessions also type, drag and move or resize windows, through option 01's broker with click's checks
summary: Accepted on 2026-10-10 at the user's request. The `varnick` server gets three more tools, each built the way `click` is. The Arrow shows on the target for a second first, one action runs at a time across all sessions, and the switch, the pane, the request's age and the Arrow's generation are checked again before acting. Nothing goes into Varnick's own windows. `type` puts the focus on a control from `look`, or uses the focus the app has, then types text and key combos as posted key events. It never sets a field's value, refuses while a password field has focus, and never logs the text. `drag` posts a mouse-down, a drag and a mouse-up between two controls or points, with click's refusals at both ends. `window` moves or resizes an app's window through Accessibility, with no pointer and no activation. `look` also gives the window an id and says which control has focus. Permissioning stays deferred, as for option 01.
status: accepted
---

## Solution

Option 01's broker gets three more tools. The MCP server still only relays, one line per call on the socket. The running Varnick does the work in its own process, with click's code and click's checks.

| Tool | Arguments | What it does |
|---|---|---|
| `type` | `id`, or `app`, or neither; `text`; `keys`; `replace` | Shows the Arrow on the target for 1 s and brings its app forward. With an `id` it puts the focus there first. It types `text`, then presses `keys` in order, as key events posted to the app in front. `replace` selects everything in the focused field first, so the field ends up holding only the text. |
| `drag` | `from` and `to`, each an id from `look` or a point | Shows the Arrow on the start for 1 s and brings the start's app forward. It then posts a left mouse-down at the start, a drag along a straight line and a mouse-up at the end. |
| `window` | `id` (`w1` from `look`) or `app`; `position`, `size`, or both | Shows the Arrow on the window for 1 s. It then sets the window's position and size through Accessibility, reads the frame back and reports it. It doesn't move the pointer or bring the app forward. |

`look` gives the window it read an id, `w1`, and adds a line saying which control has focus.

Nothing asks before any of them, as for `click`.

## Trade-offs

- **Typing is the strongest tool a session gets.**
  - Whatever can steer a session (a page it read, a file, a message) can now type as the user. That means a command into a terminal, a message into a chat, or a form's fields.
  - Nothing asks, as for `click`.
  - Claude Code's per-tool rules can still ask before `mcp__varnick__type`, `drag` and `window` while allowing `look` and `point`. Inferred, as for click.
- **Posted key events, never a field's value set through Accessibility.**
  - Posted events go through the app's own input path, so the app sees typing: a page's scripts, its undo, autocomplete and change handlers.
  - A value set through Accessibility bypasses all of that. A web form keeps its own copy of the value and sends the old one, often with nothing on screen to show it.
  - Events type at the caret and press keys. A value set replaces the whole field and can't press anything, so keys would need events anyway, and there would be two ways to check instead of one.
  - The cost of events: the app has to stay in front, with the keyboard on the right field, for as long as typing takes. That is why every character is checked first and the text is capped by time (Implementation Decisions).
- **A session types blind.**
  - `look` never reads what a field holds (ADR 0019), and its text from a picture drops the lines inside fields (ADR 0021).
  - So a session can't check what it typed. `replace` is how it knows what a field holds afterwards.
- **Password fields are refused where Varnick can see them, and typed into where it can't.**
  - A password in a session's context goes to Anthropic and stays in the transcript. Varnick can't tell a password the user meant to give from one a session found in a file or a page.
  - So nothing is typed or pressed while a secure text field has focus, just as nothing of one is read (ADR 0019). The user types it.
  - Varnick can't tell a password field the app doesn't report. A Chrome page whose tree is hidden, a canvas app, a remote desktop or a virtual machine all qualify, and a session can type into a password field there. It is the gap ADR 0021 accepted for reading.
- **Key combos follow the keyboard layout. Text doesn't need to.**
  - Text goes as Unicode characters, which type the same on any layout.
  - A combo is a physical key, so its character is looked up on the current layout. A US key code would send ⌘Q for ⌘A on a French layout.
  - An input method that composes text (Japanese, Chinese, Korean) may treat posted characters its own way. Unverified.
- **A long `type` holds the queue.** For up to about 4 s after its lead, another session's click waits, and may be dropped as late. The caps keep this short.
- **The app comes forward for `type` and `drag`,** as for `click`. Varnick's panel hides when it loses key, unless it is pinned. A drag moves the pointer and leaves it at the end.
- **`window` takes no focus.** It moves no pointer and brings no app forward, so the panel the user talks to the session in stays where it is. The app may refuse or limit a size (a minimum size, a fixed-size window), and macOS keeps a title bar on a display. So the reply gives the frame read back.
- **A session sees one more thing:** which control has focus, by its id or, for a control that isn't listed, by its kind. Never its label or value. It is a privacy change, and a small one.
- **Running sessions keep three tools until they restart.** The request's version stays the same, so they keep working, and they get `type`, `drag` and `window` at their next start or Restart.

## User Stories

1. As a Varnick user, I want a session to type into a field for me, a search or a form, with the Arrow on the field first.
2. As a Varnick user, I want a session to press keys in the app it works in (⌘L, Return, Tab, Escape), so it can move through a page or a dialog.
3. As a Varnick user, I want a session to drag a slider, a selection or a file from one control or point to another.
4. As a Varnick user, I want a session to resize or move a window, such as Chrome when it is too small for a page, without me doing it.
5. As a Varnick user, I want a session never to type into a password field Varnick can see, into Varnick's own panel, or through Varnick's own shortcuts.
6. As a Varnick user, I want typing to stop at once when I bring up Varnick's panel, turn the switch off, or another app comes forward.
7. As a Varnick user, I want Varnick's log never to hold what a session typed.

## Implementation Decisions

**What the three share with `click`**
- **One action at a time across all sessions.** Click's queue (`acquire`, `release`) becomes the queue for every action that changes the screen: `click`, `type`, `drag` and `window`. `look` and `point` don't wait in it.
- **The order is click's:**
  1. the turn, then `stillAllowed` (the switch, the pane, the request's age);
  2. the Arrow on the target, with the session's name and what is about to happen;
  3. `clickLead` (1 s);
  4. `stillAllowed` and the Arrow's generation again;
  5. the app brought forward (`bringForward`; not for `window`);
  6. both checks again, the last before the reads and the action;
  7. the action;
  8. the Arrow for 2 s more (`clickLinger`).
- **Each tool has its own age limit at that last check.** Click's 9 s (`staleAfter`) keeps its worst case after the check, about 4.75 s, inside the relay's 15 s: 13.75 s. Each new tool ends by the same 13.75 s, so its limit is 13.75 s less its own worst case after the check.
  - `type`: 9 s, less the time its own text and keys take (below). Its focus step fits inside click's 4.75 s. A call with only Return must reach its last check by about 8.85 s, and one with 500 characters and ten keys by 5 s.
  - `drag`: 7 s. It may read two ends, each a page search and a frame (up to 2.75 s each), and then moves for about 0.6 s.
  - `window`: 9 s. It makes three settings with a 1 s timeout each, then one read.
  - Another wait or read added after a tool's last check shrinks its limit, as for click.
- **Refusals keep click's sentences** and its rule of saying what was done before them. A refusal before any action says "Nothing was typed", "Nothing was dragged" or "Nothing was moved". A refusal partway through says how far it got: "Stopped after 17 of 42 characters; no keys were pressed", or "Let go where it began".
- **Never Varnick.**
  - An id in Varnick's process is refused (`ScreenReader.isVarnick`).
  - `app` never finds Varnick: `application(named:)` and `focusedApplication` skip its pid.
  - A point, or a centre read again, under one of Varnick's windows is refused (`varnickCovers`).
  - Nothing is typed while a window of Varnick's is key (below).
- **Window ids.** A `w` id is taken only by `point` and `window`. `click`, `type` and `drag` refuse it: "That is a window: use window, or an id of a control".

**`look`**
- **The window's id.** The first line starts with `w1`, the window's id, as the controls' lines start with theirs. It goes into the pane's id table with them: replaced by the next `look`, and in memory only.
- **The focus line.** One line after the controls and the text lines:
  - "Focus: e7" when the app's focused element is a listed control, or sits inside one within four levels. "Under the pointer" finds its control the same way.
  - Otherwise the element's kind alone: "Focus: a text field that isn't listed", or "Focus: a password field". A secure field is never listed.
  - "Focus: none" when the app reports no focused element.
  - Never a label or a value.
- **Where the focus comes from.** The read already asks for the app's focused element, to keep a field's frame. It is kept and matched within the read's own budget. Hey Varnick's read gets it too and ignores it.
- **Not a marker in `ScreenElement.description`.** That text is the eval's contract with Jev for Hey Varnick, and adding a marker means measuring again.
- **A privacy change.** The focused element's kind is new in what a session is shown, so ADR 0023, privacy-and-security.md and the switch's detail say so.

**`type`**
- **Which app.**
  - With `id`, the id's app.
  - With `app`, that app, found as `look` finds it.
  - With neither, the app in front other than Varnick (`focusedApplication`), the one `look` without `app` reads.
  - The app is brought forward as for a click, and an id's window is raised.
- **Where the Arrow goes:** on the id's frame, read again. Without an id it goes on the focused element's frame, or on the window's frame when the focused element has none. An app with no window is refused, as `look` refuses it.
- **Putting the focus on an id,** after the app is in front:
  - **A control outside a page** (`ScreenReader.content` says native) gets its Accessibility focus set (`AXFocused`).
    - Then the app's focused element is read. It must be the control, or inside it within a few levels.
    - If not, the call is refused with "Couldn't put the focus in e5: click it, then type without an id". Nothing is typed.
  - **A control in a page, or recognised text,** gets a posted click at its centre, read again. The click makes every check click's posted path makes: inside the visible page, not overlapped, not under Varnick's windows.
    - Setting focus in a page can report success and do nothing, as a press can.
    - It isn't verified, since a page often reports no focused element.
  - **Where the caret lands is up to the app.** A native field may select its text when it takes focus, so typing replaces it, while a click in a page puts the caret where it clicked. That is what `replace` is for.
- **How it types.** Key events are posted at the HID level after `CGPreflightPostEventAccess`, as click's mouse events are.
  - **Text:** one key-down and key-up per character, each carrying the character as its Unicode string, so it types the same on any layout. These events carry no modifiers, whatever the user holds down.
  - **Keys:** each combo is one key-down and key-up with its modifiers as the events' flags. Modifiers are never pressed as keys of their own, so none is left held down.
  - **Accessibility's value is never set** (Trade-offs).
- **What `text` may hold.**
  - Up to 500 characters, and no control characters.
  - Line breaks and tabs are keys: `Return`, `shift+Return` in a chat box, `Tab`. Return in a one-line field or a chat box sends.
  - A longer text, or one with a control character, is refused whole before anything is done, never cut. The session sends the rest in its next call, without an id, and that call types at the caret where this one stopped.
- **`keys`.**
  - Up to 10 combos, pressed after the text, in order. A combo needed before the text (⌘L before a URL, ⌘F before a search) is a call of its own.
  - A combo is modifiers and one key, joined by `+`: `cmd+l`, `⇧⌘T`, `shift+Tab`. The modifiers are `cmd`, `ctrl`, `opt` (or `alt`) and `shift`, as words or as ⌘ ⌃ ⌥ ⇧.
  - The key is a name or one character. The names are `Return` (`Enter` is taken as Return), `Tab`, `Escape`, `Delete`, `ForwardDelete`, `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown` and `F1` to `F12`.
  - **A character is found on the current keyboard layout,** never assumed to be on a US one.
    - A letter is its key, whatever its case.
    - Another character is the key that types it, with ⇧ added when only the shifted key does.
    - A character that no key types is refused.
    - The lookup reads the layout as `KeyCombo.keyName` does, the other way round, on the main actor.
  - Combos are `KeyCombo`s, and the sign and the reply name them by its label.
  - Any combo that can't be read refuses the whole call before anything is done.
- **Refused combos,** before anything is done:
  - **Varnick's own shortcuts that work anywhere,** as bound when the call arrives (`Settings.combo` for show or hide, pin, and Listening). They would act on Varnick, and showing the panel would send the rest of the call into it.
  - **Log out** (⇧⌘Q, ⌥⇧⌘Q), **lock the screen** (⌃⌘Q) and **Force Quit** (⌥⌘Esc), at macOS's default bindings. They end Varnick and every session, or take the Mac from the user.
  - **Every other combo** goes to the app in front as if the user pressed it, ⌘Q and ⌘W included. The sign names it first.
- **Password fields.** Nothing is typed or pressed while the app's focused element is a secure text field (`AXSecureTextField`). The reply is "A password field has focus. Varnick doesn't type into one: ask the user". This is checked after the focus is set and before the first character.
- **`replace`** posts ⌘A before the text, through the same combo path. It is refused when the focus reads as something that takes no typing, such as a list, a table or a window, since ⌘A would select all of it. A text field, text area, combo box, search field or web area passes, and so does focus the app doesn't report.
- **Checks before every character and every key.**
  - On the main actor, right before the events are posted, with nothing awaited in between:
    - the switch and the pane;
    - the app still frontmost;
    - no window of Varnick's key. Its panel is a nonactivating panel, so it can take the keyboard while another app stays in front;
    - the Arrow up still this call's.
  - Before each key combo, also, off the main actor: the app with the keyboard system-wide is still this one (Accessibility's focused application, with a 0.1 s timeout). A combo that hands the keyboard to another process, such as Spotlight or a system panel, stops the call there.
  - The first failure stops typing at once, and the reply says how far it got.
- **Caps and time.**
  - Characters are paced by `characterPace`. It starts at 5 ms per character and is tuned by hand to the fastest pace that TextEdit, a field in a Chrome page and Terminal all keep up with.
  - Combos take 50 ms each, plus their check.
  - So 500 characters take 2.5 s and ten combos at most 1.5 s. A call's typing takes at most 4 s, and its age limit is 9 s less what its own text and keys take.
  - If the hand check needs a slower pace, the character cap shrinks so the text still takes at most 2.5 s.
- **The sign, the reply and the log.**
  - **The sign:** the session's name, then where ("Typing into e5:" with its description, or "into the focused text field"), the number of characters, and the keys by label ("42 characters, then ↩"). Never the text: it shows in the field as it is typed.
  - **The reply:** what was done, with the keys named and the text counted, never repeated. For example: "Typed 42 characters into e5 and pressed ↩." It adds that a field's contents are never read, so `look` won't show them.
  - **The log:** the tool, the outcome's kind, characters typed of those asked, keys pressed of those asked, and durations. Never the text, the keys, the app, the window or the session's name. Keys aren't logged because one-character combos can spell text.

**`drag`**
- **The ends.** `from` and `to` are each an id from the last `look` (`e` or `t`) or a point `{x, y}` in Accessibility points. Two ends closer than 2 points are refused: "That is a click".
- **Early refusals,** before the queue, as for click's `at`: a point on no display, a point under Varnick's windows, and an id that is unknown, in Varnick's process, or a window.
- **The apps.**
  - The start's app is the id's owner. For a point, it is the app of the ordinary window in front there (`appUnder`), read after the lead as click reads it.
  - The end's app is found the same way, at the same moment, before the start's app comes forward.
  - Only the start's app is brought forward: a mouse-down on a window of an app that isn't in front often only brings it forward.
  - The end's app may be another one, such as a file dragged from Finder onto a page.
- **The reads, after the app is in front.** Each id's frame is read again, and its centre is used. In a page the centre must be inside the visible page, as for a click, and a page that can't be placed is refused.
- **Checked right before the mouse-down,** on the main actor:
  - at the start, click's `checkedToPost`;
  - at the end, that the front window there is still the end's app's (none, if none was), that it is on a display, and that Varnick's windows aren't over it.
- **The Arrow.** It is on the start for the lead, signed "Dragging e3 to e9" or "to 812, 340". As the drag begins it is drawn again at the end, after a check that it is still this call's, and it stays 2 s after the release.
- **The motion.**
  1. Move to the start, left mouse-down, and hold `dragHold` (0.1 s).
  2. Post dragged events along the straight line about every 16 ms for `dragTime` (0.3 s).
  3. Hold 0.15 s at the end, then mouse-up.

  The timings are tuned by hand. It uses the left button only, with no modifiers, and the pointer stays at the end.
- **Before the release,** the end's checks run again: the switch, the Arrow, Varnick's windows and the front window at the end. If one fails, the pointer goes back to the start and the button is released there. The button is released on every path after the mouse-down, a thrown error included, so a session never leaves it held.
- **The reply:** "Dragged e3 to e9 (812, 340). Look again to see what happened."

**`window`**
- **Which window.**
  - `id` takes `w1` from the last `look`.
  - `app` takes that app's focused window, else its main window, as `look` reads it.
  - The window's pid is checked against Varnick's on top of what the finders already skip.
- **What changes.**
  - `position` `{x, y}` is where the window's top left goes, in Accessibility points.
  - `size` is `{width, height}`.
  - At least one is given, with finite values and a positive size.
- **Refusals:**
  - a window in full screen (`AXFullScreen`) or minimized (`AXMinimized`);
  - a position or size that can't be set (`AXUIElementIsAttributeSettable`): "That window can't be moved", or "resized";
  - a new frame whose top 30 points, where the title bar is, would be on no display, since the user must be able to reach it;
  - a window that has gone.
- **The order:** size, then position, then size again when both are given. macOS keeps a window on its display, so otherwise a size that doesn't fit at the old place, or a place that doesn't fit the old size, would be cut. Each setting has the press's 1 s timeout.
- **No activation and no pointer.** The window keeps its place among the others.
- **The Arrow.** It is on the window's frame for the lead, signed "Moving w1 to 0, 25", "Resizing w1 to 1200 × 800", or both. Afterwards it is drawn again for 2 s on the frame read back, if it is still this call's.
- **The reply** gives the frame read back, which can differ from the one asked: "w1 is now 0,25 1200x800. Its controls have moved: look again." Element ids still work, since their frames are read again, but `t` ids from a window that changed size are gone.

**The request**
- `ScreenTool` gets `type`, `drag` and `window`.
- `ScreenArguments` gets `keys`, `replace`, `from`, `to`, `position` and `size`.
- `text` holds either `look`'s flag or `type`'s characters, read as loosely as now. `look` takes `true` or `"true"`. `type` takes a string and refuses a flag.
- **`ScreenRequest.version` stays 1.** Every request an older server sends still reads the same. A session started before the build keeps its three tools until it restarts. Its `look` shows `w1` and the focus line, and its `click` refuses a `w` id.
- **`ScreenMCP.tools` lists all six.** Each new description says that the Arrow shows first, that nothing asks, and that one action runs at a time. `type`'s also says:
  - that a field's contents are never read back, and `replace` is how to know them;
  - that password fields are refused;
  - the combo format, and that a combo needed before the text is its own call;
  - the caps.

**Docs the builder updates with the code**
- **ADR 0023:** a dated amendment covering type, drag, window and the focus line. Its "There is no `type`, no named keys or shortcuts, no drag and no scroll" now holds for scroll only.
- **privacy-and-security.md:**
  - "Screen access clicks without asking" also covers typing, dragging and moving windows without asking, the refusal in password fields and its gap, and that the log never holds the text.
  - The Anthropic section names the focused element's kind.
- **The guide's Screen access section, the README's line, the switch's detail in Settings, and CONTEXT.md's Screen access:** six tools, and "there is no `type`" removed.
- **where-it-breaks.md › Screen access:**
  - the queue for every action;
  - each tool's age limit, and that any wait after the last check shrinks it;
  - the checks before every character and key, including Varnick's key window;
  - the layout lookup and the refused combos;
  - drag's release on every path;
  - window's order of settings;
  - the focus line kept out of `ScreenElement.description`;
  - what the log holds.

**State**
- No new UserDefaults key: `screenAccess` covers all six tools.
- No change to `sessions.json`.
- The id tables gain `w1`, in memory only.

## Testing Decisions

- **No test target yet.** Verification is `make build`, then hand checks after the user restarts Varnick. The user runs every check that types, drags or moves a window. A builder sends none without the user's go-ahead, since agents don't drive the user's screen.
- **For the hand checks, start Varnick through its LaunchAgent** (`launchctl kickstart gui/<uid>/com.zabaca.varnick`), not with `make run` from a terminal. Started from a terminal, Varnick is checked under the terminal's permissions, and Accessibility can read as off (measured 2026-10-10, Further Notes).
- **`Varnick --mcp` on its own, with stdin from a file:**
  - `tools/list` lists the six tools with their schemas.
  - A `tools/call` of each new tool with a made-up pane id gets the switch's or the pane's refusal, and nothing is typed, dragged or moved. Never use a real pane id.
- **By hand, in a session restarted with the switch on:**
  - `/mcp` lists six tools.
  - `look` at TextEdit, with the caret in a scratch document, shows `w1` and "Focus: e…".
  - `type` with the id of System Settings' search field and `replace`: the field holds only the text.
  - Chrome: `type` with keys `cmd+l`, then a second `type` with an address and `Return`: the page loads.
  - On a second keyboard layout (French or German), `type` with keys `cmd+a` in the scratch TextEdit document selects everything and quits nothing.
  - `type` while a login page's password field has focus is refused, and nothing is typed.
  - `type` with Varnick's show or hide shortcut in `keys` is refused.
  - A 400-character `type` into TextEdit, with the user bringing up Varnick's panel partway, stops. The reply says after how many characters, and nothing reaches the panel. Turning the switch off partway stops it too.
  - `drag` a TextEdit selection, or a slider in System Settings, by ids and by points.
    - A drag whose end is under Varnick's pinned panel is refused.
    - A drag whose end another window covers once the start's app comes forward is refused.
  - `window` resizes Chrome, the case that needed the user's hand on 2026-10-10, and moves TextEdit. It refuses a window in full screen, a frame off every display, and `app` "Varnick".
  - Varnick's log holds kinds, counts and durations only: no text and no key names.
- **Seams for a test target later:** the combo parser (with the layout as an input), the text rules, the age limits, the refusal rules and the replies' text.

## Out of Scope

- Scroll, right-click, double-click, and clicks or drags with modifiers held.
- Setting a field's value through Accessibility, and reading back what a field holds. Reading it back would be a privacy change (ADR 0019, 0021).
- More than 500 characters, or a line break, in one `type`. Holding a key down.
- Windows other than an app's focused or main one. Raising, minimizing, full screen, closing, and moving a window to another Space.
- System shortcuts beyond the four refused, read from the user's own settings.
- Input methods that compose text (unverified).
- Permissioning, deferred as for option 01: approval before typing, a per-pane switch, a deny list of apps, and a record of what was typed.
- A command-line front end (option 04).

## Further Notes

- **Accepted on 2026-10-10** at the user's request, relayed by the coordinator: "i think typing dragging and window sizing should be tools that are available". It followed that day's hand test of option 01: `click` worked after 0fdb9d0, and the user had to resize Chrome by hand because no tool could. The decisions below were made while planning, and the user can change any of them.
- **Decided while planning:**
  - **Posted events, never a field's value** (Trade-offs).
  - **Password fields are refused when Varnick sees one.** Keys are refused there too, so ⌘V can't paste into one.
  - **Line breaks and tabs only as keys,** since what Return does depends on the field.
  - **A text over the cap is refused whole, never cut.** A session can't read the field, so a cut it didn't know about would go unnoticed.
  - **Text before keys.** A combo needed first is its own call. That covers a form (id, `replace`, text, then Tab or Return) in one call, and an address (⌘L, then the address and Return) in two.
  - **`replace` as a flag,** rather than ⌘A in a call of its own, since a session types blind.
  - **The focus as its own line in `look`,** not a marker in the eval's description.
  - **`window` without activation,** so the panel the user talks to the session in stays.
  - **Only the drag's start app comes forward.**
  - **No version bump.**
  - **Four of macOS's combos refused,** besides Varnick's own.
- **Permissioning stays deferred,** as for option 01. Every pane process still gets Varnick's grants (`panes-share-launchys-permissions`), so a session could type with `osascript` or its own code. These tools add the Arrow first, the switch, the checks and one implementation.
- **Measured on 2026-10-10, relayed by the coordinator.** A Varnick started from a terminal (cmux) with `make run` or the restart script is attributed to that terminal by macOS. So it gets the terminal's permissions: Screen Recording was on, through cmux, and Accessibility was off. Every pane's process inherits the same. Starting it through its LaunchAgent fixed it. The finding is recorded in `panes-share-launchys-permissions` option 01's Further Notes, since it is that problem's mechanism one level up.
- **ADR, on acceptance, not yet written** (the planner writes only problems): ADR 0023's dated amendment (Docs, above).
- **Verified in the code at 0fdb9d0:**
  - The window read already asks for the app's focused element, but keeps only its frame, and only when it is a field.
  - The walk skips a secure text field whole, so one never gets an id. A field is listed only when it has a title, description, help or placeholder, so an unlabelled one is reached by clicking it and typing without an id.
  - Varnick's panel is a nonactivating panel that can become key.
  - Show or hide, pin and Listening are the only shortcuts registered system-wide (`ShortcutAction.isGlobal`, Carbon hot keys), and `Settings.combo` gives each one as bound.
  - `KeyCombo` holds a key code and modifiers, and names a key from the current layout (`keyName`).
  - `ScreenArguments.text` is `look`'s flag, already read from a boolean or a string.
  - The click's queue, `stillAllowed`, `staleAfter`, `ArrowOverlay.generation`, `checkedToPost`, `bringForward`, `frontWindow`, `appUnder`, `varnickCovers`, `onDisplay` and the posting at the HID level are as option 01 and where-it-breaks.md describe them.
  - `application(named:)` and `focusedApplication` skip Varnick's pid.
- **Inferred:**
  - Posted key events go to whichever window has the keyboard, and that can be Varnick's nonactivating panel while another app is frontmost.
  - A posted combo equal to a Carbon hot key fires it.
  - Setting `AXFocused` on a native field focuses it, and a field in a page reliably takes focus only from a click.
  - Accessibility's focused application names the process whose nonactivating panel has the keyboard (Spotlight's, Varnick's).
- **Unverified, for the builder to check first:**
  - That Chrome, Electron apps and Terminal take a character from a key event's Unicode string. Remote desktops, virtual machines and games may read the key code instead.
  - The pace that apps keep up with.
  - That a combo's modifiers as event flags are enough for Chrome's ⌘L, with no separate modifier presses.
  - Whether posted key events still arrive while another app has Secure Keyboard Entry on.
  - What Chrome reports as focused while its page tree is hidden, and whether it reports a password field as a secure text field then.
  - That position and size can be set on Chrome's windows, and what System Settings' fixed-size window answers.
  - That these holds and this pace start a drag in Finder and move a slider.
  - Whether a drag that passes over Varnick's panel on the way does anything there. The ends are checked, the path isn't.
