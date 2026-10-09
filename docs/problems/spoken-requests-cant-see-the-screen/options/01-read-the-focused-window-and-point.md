---
problem: spoken-requests-cant-see-the-screen
title: Read the focused window's Accessibility tree, let Jev pick the element, and point at it with an arrow
summary: With a new switch, Point at the screen, a spoken request routed to `screen` is answered from the Accessibility tree of the window that has focus. Launchy describes each visible element by its label, its kind and the text beside it. One Jev call picks the element the request means and says whether it is there at all. A pick Jev finds present gets a big click-through arrow and a sign, drawn by Launchy itself, while Launchy says the sign's note. The eval measured 87 of 97 right, 1 of 28 absent things pointed at, in 0.12 s. No screenshot is taken. Pointing needs the relevance filter on TypeSafe with a key, because Gemma's picks were measured too unreliable to draw. The request and the window's element descriptions go to TypeSafe. Chrome's web pages are out of reach.
status: shipped
---

## Solution

**Point at the screen** is a new switch under Hey Launchy in Settings › Listening, off by default. It needs the relevance filter on TypeSafe with a key saved, the gate Hey Launchy's decide step already uses (ADR 0016). While it is on, a spoken request can go to a fourth place, the screen, beside History, Bookmarks and sessions. The steps are Hey Launchy's own, with a different read and answer:

1. **Decide.** Jev's `source` question gains `screen`, and its `action` question gains `point`. Off-topic is read first, as today. A request whose likeliest source is `screen` goes down this path; the others are answered as before. When Jev's decide fails, Gemma's decide prompt offers `screen` too.
2. **Look.** Launchy walks the Accessibility tree of the window that has keyboard focus. It keeps every element whose frame is centred inside the window and that has a label, leaving out containers and scroll machinery. Each element is described by its label, its kind and the text beside it on the same row, found in code.
3. **Choose.** One Jev call asks two things over that list: which element the request means (a Choice whose options are the elements), and whether the thing is in the window at all (a yes-or-no). It points when the second is 0.5 or more, and otherwise says "I can't see that on your screen."
4. **Point and say.** Launchy draws a big arrow at the element, with a ring round it and a sign holding the note ("Here's the Allow button."), and says the note. The arrow is click-through and never takes focus, and it goes by itself a few seconds after the speech.

Nothing is clicked, opened or focused. The panel, when it is open, stays as it was.

## Trade-offs

- **Exact, measured and fast.**
  - macOS gives each element's frame, so the arrow lands on the control, not near it.
  - On the eval's eight windows, with the whole visible list, Jev picked the right element for 87 of 97 requests, and an acceptable one (the control's own row text) for 95.
  - It pointed at something for 1 of 28 things that weren't there, and that one went to the tab where the setting lives.
  - It took 117 ms at the median, flat from 10 to 100 elements.
  - No image is made, and none can leave the Mac.
- **The eval's limits.** It covered one person's Mac and eight windows, five of them System Settings. The requests were written while looking at the element lists, so real speech may echo labels less. The `point` wording and the beside-text rule were written for that data. The hand checks below take it to other apps.
- **It sees only what the app exposes.**
  - Native apps, System Settings and system alerts that take focus are covered.
  - Electron apps (Slack, VS Code, Claude's desktop app) are covered once asked to build their web tree.
  - Chrome's page content is out of reach unless Chrome runs with `--force-renderer-accessibility`. In Chrome a request finds the toolbar and nothing inside the page, and Launchy says so.
  - Icon-only controls are found when the app gave them a description (most native ones), and missed otherwise.
- **Pointing needs TypeSafe.** Gemma was measured too unreliable to draw an arrow. It picked right 72 of 97 times, and pointed at something for 13 of 28 absent things, and its probabilities can't say "not there". So with the filter On this Mac or off, the switch can't be turned on. Users who keep everything on this Mac don't get this feature (open question 2).
- **A new kind of data reaches TypeSafe.** With the switch on, each screen request sends the request, the focused window's title, and each element's label, kind, enclosing groups and the text beside it.
  - That is the window's visible text near its controls: a mail's subjects and senders in a message list, a file's name in a tab, the account's name in System Settings' sidebar.
  - The eval dropped such rows from its windows; real use won't.
  - ADR 0016 refused to send rows, and ADR 0017 then sent page rows for the filter. This sends the screen, so it gets its own line in Settings, the README and SECURITY.md, and its own ADR.
  - With the switch off, nothing changes.
- **A permission, and its reach.**
  - Launchy needs Accessibility. While builds are signed ad hoc, a rebuild may silently stop the grant from applying, until the user removes and re-adds Launchy (unverified; hand check 1). `runs-only-from-a-checkout` option 01 would make the grant stick.
  - **Every session in Launchy's panes gets the grant** (measured 2026-10-09, by the privacy service's attribution). That includes zmx-hosted panes and sessions started with Skip permissions. Each can read and drive any app's UI without asking (`panes-share-launchys-permissions`, severity high).
  - **Two earlier readings were wrong:** "zmx sessions very likely don't get it", read from the eval's recheck, whose turn to true is unexplained; and "each process is its own", from a misleading lookup.
  - **The grant stays Launchy's.** zmx and helpers are never granted; their grants aren't consulted for pane processes anyway.
- **ADR 0015's promise changes.** A spoken request can now draw on the screen. It still never opens, clicks, types or moves focus, and a misheard request costs an arrow that goes by itself.
- **The decide questions change only with the switch on.** With `screen` and `point` added, the eval kept the old sources where they were (28 of 31 before and after) and flagged all 10 off-topic requests and none of the 40 screen requests at `offTopicFrom` 0.5. `alsoSessionsFrom` wasn't re-measured.
- **Latency.**
  - Measured: Jev's decide is about 0.11 s and its choice about 0.12 s.
  - Unmeasured: the tree read, estimated at 0.1 to 1 s.
  - The draw is instant.
  - Decide, read and choose all run during the hold (ADR 0017), so most of this overlaps the wait for the user to finish.

## User Stories

1. As a Launchy user, I want to say "Hey Launchy, where's the Allow button" and see a big arrow on it while Launchy says "Here's the Allow button", so that I find it at a glance.
2. As a Launchy user, I want "which one turns off the startup sound" answered with an arrow on the right switch, even though the switch itself has no name but its state.
3. As a Launchy user, I want "what is this" to name the control under my pointer, with its help text when it has one.
4. As a Launchy user, I want the arrow never to take my focus or block my clicks, and to go away by itself.
5. As a Launchy user, I want to hear "I can't see that on your screen" rather than see an arrow on the wrong thing.
6. As a Launchy user, I want to be told when the thing is inside a Chrome page Launchy can't read, rather than hear only that it can't see it.
7. As a Launchy user, I want this off until I turn it on, and Settings to say what it sends, what it needs and what its permission reaches.
8. As a Launchy user, I want my requests about pages, bookmarks and sessions answered exactly as before.
9. As a maintainer, I want `Launchy --ask` to run a screen request against a named app and print what it saw and picked, so that I can check the questions on new apps.

## Implementation Decisions

**Turning it on**
- **Point at the screen** goes in Settings › Listening, below Hey Launchy. It is off by default, stored in UserDefaults like the other switches, and needs Hey Launchy on.
- **The gate.** It needs the relevance filter on TypeSafe with a key saved. Without that, it shows the need with a link to Settings › Search and can't be turned on, as Hey Launchy does with Text generation. If the gate closes later, the switch acts as off until it opens again.
- **The permission.** Its row shows whether Launchy has Accessibility, checked each time Settings shows it. Without it, a button asks macOS for it (the system prompt adds Launchy to the list) and opens Privacy & Security › Accessibility.
- **The detail text** says:
  - that Launchy draws an arrow on the screen;
  - what goes to TypeSafe for each screen request: the window's title, and the labels, kinds and nearby text of its elements;
  - that a rebuild may need the grant again;
  - that the grant is Launchy's own, and that every session in its panes gets it too, zmx-hosted ones included (measured 2026-10-09).
- **With the switch off,** Jev's questions and Gemma's prompt are today's, byte for byte.
- **Asked without the permission,** Launchy says "I need Accessibility permission to see your screen. It's in Settings, under Listening." It draws nothing.

**Deciding**
- **With the switch on,** Jev's questions are the eval's arm J4p, kept in one place as the others are. This is the measured wording:

  ```
  context: … Launchy answers by searching one of four places: the web pages the person visited in their browser,
    the pages they bookmarked, their own Claude Code sessions (the coding work they did with Claude on their own
    software projects), or the window on their screen right now (its buttons, fields and other controls, so
    Launchy can point at one).
  source "screen": What is on the person's screen right now: the buttons, switches, fields, menus and icons in the
    window in front of them. Pick this when the person asks where something is, which one to press or what
    something is in the app they are looking at, rather than about a page, bookmark or session from before.
  action "point" (before "other"): Point at something in the window on their screen, or say where it is or what it is.
  action "other": Something unrelated to their pages, bookmarks, sessions or screen, such as the weather, a timer
    or the time.
  ```
- **Off-topic is read before the source,** as `prepare` already does. Off-topic requests ("set a timer", "send a message") take `screen` as their source.
- The model stays pinned, and `offTopicFrom` stays at 0.5.
- **Gemma's decide prompt** gains `screen` and the eval's one example ("where is the export option on this screen"). It runs when Jev's decide fails, as today. A screen request it routes still goes to Jev's choice (below).
- The off-topic line becomes "I only look up your pages, bookmarks, Claude sessions and what's on your screen."
- **`screen` is taken when it is the likeliest source.** Sessions are never added beside it, and no search runs.

**Looking**
- **In Launchy's own process,** under Launchy's own grant. The read never goes through a helper, a script or bigarrow run in a pane. Running there wouldn't need a grant of its own, since pane processes get Launchy's, but it would put the read outside Launchy's checks.
- **Off the main actor,** within named limits, tuned by hand: a time budget (1 s), a node limit (3,000), a depth limit (30), and a short timeout per Accessibility call, so a hung app costs only the budget.
- **Which window.** The focused window of the application that has keyboard focus, as the system-wide Accessibility element reports it. Its sheets and dialogs are inside it, and a system alert that takes focus is its own app. When Launchy itself has focus, the frontmost other app is read; Launchy's own windows are never read.
- **Electron apps** are asked to build their web content's tree (`AXManualAccessibility`), and the first such request waits a moment. The app keeps that tree until it quits, which costs it some memory. Chrome's refusal is harmless.
- **An element is listed,** as the eval kept them, when:
  - its frame is more than a point each way and its centre is inside the window (scrolled-out rows can't be pointed at);
  - it has a label, or it is one of the window's own buttons (close, minimise, zoom, full screen);
  - it isn't a splitter, scroll bar, value indicator, column, layout area or scroll arrow.

  Text and headings are listed too.
- **Its label** is its title, description, value, help and placeholder, de-duplicated, cut to 80 characters.
  - The value counts for controls whose value is their state or choice (a switch's "1", a pop-up's "Bottom").
  - It never counts for a text field or text area, which hold what the user typed.
  - Nothing of a secure text field is read.

  This last rule is tighter than the eval's, whose text areas were empty.
- **Its description** is the eval's F3:
  - the label;
  - its kind as macOS names it, and "dimmed" when disabled;
  - its three nearest named enclosing groups;
  - the text beside it.

  For example: `1 (switch) in Sound, beside "Play sound on startup"`.
- **The text beside it** is the nearest text in the same group on the same row to its left, within 450 points, else the nearest text just above, within 30 points, cut to 80 characters. Text and headings have none. This rule added 10 to 19 points for both models in the eval; the groups added nothing, and are kept only because F3 was measured with them.
- **The element under the pointer** is marked "under the pointer" in its description, so "what is this" can mean it. This marker is unmeasured: check it with `--ask`.
- **Order and limit.** Elements are kept in tree order. A window with more than 255 (a Choice's limit) keeps the first 255; the eval's windows had 29 to 72.
- **Chrome with an empty web area** is noted, so that a miss is answered "I can't see inside pages in Chrome."

**Choosing**
- **One Jev call,** on the same pinned model, with the decide step's 1.5 s timeout:
  - `target`, a Choice whose options are the element descriptions (keys `e1` to `eN`): which element does the person mean?
  - `present`, a yes-or-no over the same descriptions: is the thing the person asks about one of them?
  - the state: the request text and the window's title.

  The eval's arm C at all elements and F3 holds the measured wording.
- **Point at `target`'s top choice when `present` is 0.5 or more.** Otherwise: "I can't see that on your screen."
  - At 0.5 the eval had 87 right, 10 wrong and none declined of 97, and 1 of 28 absent things pointed at.
  - At 0.7 it declines 4 present targets to avoid 1 wrong pick, so 0.5 it is.
  - The threshold is a named constant beside `offTopicFrom`.
- **Jev fails, or no answer comes within the timeout:** "I can't point at things right now." No Gemma pick (open question 2).
- **Before drawing,** the chosen element's frame is read again, since the window may have moved during the hold. If the element is gone, nothing is drawn, and Launchy says it can't see it any more.

**Pointing**
- **One overlay window,** made when first needed and kept. It covers the display that holds the element, is borderless and nonactivating, can never become key or main, and ignores the mouse. It sits on every Space and over full-screen apps, at a level above Launchy's own floating panel.
- **Focus.** Showing it never activates Launchy or moves focus. An open panel keeps key and stays shown.
- **What it draws:**
  - a ring round the element's frame;
  - a thick arrow ending at the ring;
  - a rounded sign at the arrow's tail holding the note.

  The sign goes on the side with the most room and never covers the element. It is one colour with a white edge and a shadow, sized to read from a step back, and it fades in.
- **Coordinates.** Accessibility frames are global with a top-left origin, and AppKit's have a bottom-left one from the main display. They are converted in one place.
- **How long it shows.** From just before the speech starts (amended 2026-10-09: ahead of the sound, see Further Notes) until 8 s after it ends (a named constant). A new spoken request, or turning Point at the screen, Hey Launchy or Listening off, removes it at once. Nothing on it is clickable, and it doesn't follow a window that moves.
- **Whose code.** It is Launchy's own, after bigarrow's overlay recipe. Any code copied from bigarrow keeps its MIT notice.

**The note**
- **A fixed sentence, with no Text generation.**
  - "Here's the Allow button.": the role in words and the label as the app gives it.
  - When the label is only a state ("1"), the text beside it names the control: "Here's the switch for Play sound on startup."
  - For the element under the pointer: "That's the Share button.", plus its help text when it has one, cut to one sentence.
- The sign shows the sentence, and Launchy speaks it through `Speaker`, as every answer is spoken. It goes into the transcript as a `[launchy]` line, as other answers do.
- **Misses are spoken with nothing drawn:** "I can't see that on your screen.", the Chrome sentence, the permission sentence, "I can't point at things right now."

**Speculating** (ADR 0017)
- The tree read and the choice run in `prepare` while the request is held, as the search and the filter do.
- A partial request's descriptions may go to Jev and be discarded, as a partial request's pages may today.
- The arrow is drawn only after the hold ends.

**Privacy and logs**
- **To TypeSafe,** only with the switch on, which needs the filter on TypeSafe and a key saved:
  - the request text, for the decide step, as now;
  - for a screen request, the request, the window's title and the element descriptions.

  Never a typed value, a secure field, an app's name, a frame or an image.
- **Never logged:** the request, the descriptions or the pick.
- **The timing line** adds the read's duration, the element count, the `present` outcome and the miss's kind (not present, no permission, Chrome, gone, Jev failed), never a probability tied to a label.
- **Docs.** The README, SECURITY.md, the Settings text and where-it-breaks's list of what goes to TypeSafe all add the descriptions.

**Command line**
- `Launchy --ask <file> --app <name>` reads that app's focused window for a screen request, instead of the app with focus, which is the terminal. It prints:
  - the element count;
  - the pick's description;
  - `target`'s top probability and `present`;
  - each step's time.

  It draws nothing.
- With `--draw`, it also shows the arrow for 8 s, to check placement.
- Request files and output are personal: keep them out of the repo.

**State**
- One new UserDefaults key, for the switch. `sessions.json` is unchanged.
- macOS keeps the Accessibility grant.

## Testing Decisions

- There is no test target. These pure steps are the seams for a first test once there is one:
  - an element's attributes in, a listed element or nothing out;
  - a window's elements in, each one's beside-text out;
  - Jev's reply in, a pick or a miss out;
  - the coordinate conversion, for displays left of and above the main one;
  - the sign's placement: the element's frame, the display and the sign's size in, the sign's frame out.
- **Against the eval.** The eval's eight cleaned windows and 125 requests run through the Swift listing and description should give the eval's F3 descriptions, apart from the typed-value rule. Then `--ask` should reach about its 87 of 97 and 1 of 28. The windows are in agent-lab; the builder copies them into the problem's scratch folder rather than the repo.
- **`--ask --app`** on new made-up requests against Finder, an Electron app, Xcode and Chrome: the apps the eval didn't cover.
- **By hand, after the user restarts Launchy,** with Listening, Hey Launchy and Point at the screen on:
  - In System Settings › Sound, ask "which one turns off the startup sound". The arrow lands on the switch, the note is spoken, and focus stays in System Settings.
  - In an app with an icon toolbar, ask "which one is the share button". Then hover a control and ask "what is this".
  - With the panel open and text typed in it, ask again. The panel stays shown, its field keeps focus and the text is unchanged.
  - In Chrome, ask about a button inside the page. Launchy says it can't see inside pages in Chrome.
  - Ask about something that isn't on screen. Launchy says it can't see that, and draws nothing.
  - With a second display, and with an app in full screen, the arrow appears over the right app.
  - Ask about a page you visited. It is answered from History, as before. "Set a timer" gets the off-topic line.
  - Turn the filter On this Mac. The switch shows its need, and a screen request is answered as before the switch existed.
  - Launchy's log holds no request, description or pick.

**Hand checks for the builder.** These are unverified. Run them with the user, and keep anything personal in `.scratch/spoken-requests-cant-see-the-screen/`.

1. **The grant across a rebuild.** Grant Accessibility, then `make build` and restart. Does Settings still show it granted? If not, the detail text says how to re-grant it.
   - **Failed on ad-hoc builds:** a rebuild stopped the grant applying (2026-10-09).
   - **Passed once builds were signed with Developer ID** (ADR 0022). Granted on build b157600, Accessibility and Screen Recording still read true after `make build` of 8fe2721 and a restart, with no visit to System Settings.
2. **The grant's reach.** Measured 2026-10-09, in two steps:
   - the privacy service named Launchy as responsible for a zmx-hosted pane's process;
   - with Launchy granted on a signed build, both grants read true from a pane.

   A pane opened with Keep sessions running off is expected the same, and is unchecked. Settings and SECURITY.md say so, and the fix is `panes-share-launchys-permissions`.
3. **System prompts.** Trigger a real permission prompt (a new app asking for the microphone) and ask "where's the Allow button". Is the prompt the app with focus, and does it expose its buttons?
4. **Latency.** Time about ten requests from the end of speech to the arrow, warm. A median well over 4 s goes back to the user.
5. **Sessions beside History.** `alsoSessionsFrom` wasn't re-measured with the new questions. Run `--ask` on the made-up requests that read sessions behind pages, with the switch on and off, and compare.

## Out of Scope

- Clicking, pressing, typing or focusing anything for the user.
- Screenshots of any kind (options 02 to 04).
- Chrome's page content, beyond saying it can't be read.
- The menu bar and the app's other windows: the eval measured the focused window only.
- Apps other than the one with focus ("where's the mute button in Zoom" while another app is in front).
- Windows with more than 255 elements. The eval suggests a two-pass Choice (region, then element) if they turn up.
- Several arrows for one request, an arrow that follows a moving window, and a click to dismiss it.
- Follow-up requests ("no, the other one"). Each request stands alone, as ADR 0015 says.
- Running the read from a pane or a helper, and granting zmx anything (see Looking).
- Keeping panes started outside zmx from inheriting Launchy's grants. If hand check 2 finds they do, that is a problem of its own: it would change what the microphone grant reaches in those panes today, too.

## Further Notes

- **Decided by the user on 2026-10-09,** relayed by the coordinator:
  - This option, as written.
  - Open question 2: no. Gemma never points, and the switch can't be turned on without the TypeSafe gate.
  - Open question 1 wasn't put separately; its recommendation was taken with the acceptance. A plain line goes in the switch's detail and in SECURITY.md, and the disclaim change is its own problem, `panes-share-launchys-permissions`.
  - A screenshot may leave this Mac, so options 02 to 04 stay proposed.
- **The open questions, as they were put:**
  1. **If the grant reaches panes started outside zmx, is that acceptable?** (Since 2026-10-09 the grant is measured to reach every pane, zmx-hosted ones included; see Trade-offs.)
     - Keep sessions running is off by default, so on a new install every pane is Launchy's direct child. With it on, sessions run in zmx and very likely don't get the grant. (Wrong, measured 2026-10-09: they get it too.)
     - Recommended: accept it, with a plain line in the switch's detail and in SECURITY.md naming Keep sessions running.
     - Raise the disclaim change as its own problem rather than block on it.
  2. **Should Gemma point when Jev can't be asked?** That would make the feature work with the filter On this Mac, with nothing leaving, at the eval's measured cost: 72 of 97 right, 24 wrong, and an arrow for 13 of 28 absent things, with no probability to hold it back.
     - Recommended: no, as the eval recommends. A wrong arrow misleads where silence doesn't, and Gemma stays the routing fallback.
     - If the user wants the feature without TypeSafe, a better route is option 02's or 03's local reading, or a separate spoken-only mode ("I'd look for a button called …") rather than Gemma's arrow.
- **When the arrow goes up (2026-10-09).** The arrow goes up once the pick's frame is re-read, before the speech is rendered. So it comes ahead of the sound, by roughly the render time: about 0.7 s in the first test. This is unverified until the timing line's "up … after speech ended" is measured.
- **ADR:** [0019](../../../adr/0019-a-spoken-request-can-point-at-the-screen.md). It amends ADR 0015 ("nothing is shown") and ADR 0016 (what Jev receives).
- **Glossary:** **Arrow** added and **Spoken request** changed in `CONTEXT.md`.
- **`where-it-breaks.md` items this touches:**
  - Listening and spoken requests: the Jev body (anything added is a privacy change needing the ADR, README and SECURITY.md), the pinned model and its thresholds, speculation in `prepare`, and speech only through `Speaker.speak`.
  - Focus and keys: the overlay can never become key, so the panel's `resignKey` rule is untouched.
  - New entries:
    - the overlay's level and click-through;
    - the one coordinate conversion;
    - the tree read's limits off the main actor;
    - the listing and description rules, matched to the eval's;
    - what a label may never hold;
    - the read staying in Launchy's process, with zmx never granted.
- **Considered:**
  - **Code matching alone** (bigarrow's exact, prefix and substring match on the request's words). It is private and instant, but "where do I approve this" never matches "Allow", and a switch's label is only "1".
  - **Gemma choosing** (open question 2).
  - **The top choice's probability as the threshold, with a `none` option** (this option's first draft). The eval found `present` separates better (AUROC 0.96 for top probability times `present`, against 0.93 for top probability alone), and `present` at 0.5 needs no tuning.
  - **Reading the tree on every request and asking Jev both steps in one call.** It saves one round trip, but sends the screen for requests that aren't about it.
- **Measured in the eval** (agent-lab, the screen-pointing experiment at commit 20fb286, 2026-10-09):
  - routing with `screen` and `point`;
  - element choice and `present`;
  - the effect of beside-text and groups;
  - Jev's and Gemma's latency, Gemma's in Python MLX on the same weights.
- **Verified in the code or on this Mac:**
  - the decide questions, gate, thresholds and off-topic line;
  - that no Accessibility or screen capture API is used;
  - `LauncherPanel` and the accessory app;
  - the ad-hoc signature and its code-hash requirement;
  - no responsibility disclaim in Launchy or SwiftTerm;
  - that a pane runs as Launchy's direct child when zmx isn't used;
  - the Choice limit of 255, from TypeSafe's docs.
- **Observed in the eval:**
  - a zmx pane's processes run under zmx, whose parent is launchd;
  - `AXIsProcessTrusted()` there turned from false to true after the user granted zmx alone, with Launchy's switch off in the user's screenshot. No one checked the list afterwards. Unexplained since the measurement below.
- **Measured later on 2026-10-09 from a pane session:**
  - with zmx granted, a fresh binary there wasn't trusted;
  - the privacy service's log names Launchy as responsible for a zmx-hosted pane's process.
- **Inferred, not measured:**
  - the tree read's time;
  - that a pane opened with Keep sessions running off is trusted too (zmx panes are measured);
  - how system prompts expose their buttons;
  - accuracy beyond System Settings, Calculator, TextEdit and Finder;
  - bigarrow's claims about Chrome and Electron.
